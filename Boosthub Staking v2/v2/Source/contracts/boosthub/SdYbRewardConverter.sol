// SPDX-License-Identifier: UNLICENSED
/**
 * @title CurveYield System Component
 * @notice CurveYield is a decentralized NGO building optimized DeFi systems for the good of all.
 *
 * @dev CurveYield integrates specialized AMM infrastructure, tokenized yield strategies, credit
 * markets, and protocol-owned liquidity into a unified, capital-efficient liquidity stack governed
 * by an open, international DAO community.
 *
 * Protocol operations are enhanced by cross-chain bridging and messaging, MEV capture systems,
 * off-chain to on-chain automation, and peer-to-peer data networks.
 *
 * This contract is one component of the CurveYield system.
 *
 * CurveYield uses proven DeFi primitives where possible and adds targeted coordination and
 * capital-efficiency-enhancing contracts where needed. Users and integrators must review
 * CurveYield documentation before use.
 *
 * Learn more:
 * Documentation: https://docs.curveyield.com
 * dApp: https://curveyield.online
 * GitHub: https://github.com/curveyield
 *
 * Decentralized links may have limited or delayed availability during periods of high network activity:
 * https://curveyield.eth.limo
 * https://curveyield.dao
 *
 * Note: curveyield.dao may require a Brave Browser or an Unstoppable Domains browser plugin to use.
 */
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface ISdYbCryptoPool {
    function price_oracle() external view returns (uint256);
    function fee() external view returns (uint256);
    function get_dy(uint256 i, uint256 j, uint256 dx) external view returns (uint256);
    function exchange(uint256 i, uint256 j, uint256 dx, uint256 min_dy) external returns (uint256);
}

interface ISdYbStablePool {
    function price_oracle(uint256 i) external view returns (uint256);
    function fee() external view returns (uint256);
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
}

contract SdYbRewardConverter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant CURVE_FEE_DENOMINATOR = 1e10;

    address public immutable crvUsd;
    address public immutable yb;
    address public immutable sdYb;
    ISdYbCryptoPool public immutable crvUsdYbPool;
    ISdYbStablePool public immutable ybSdYbPool;

    error InvalidToken();
    error InvalidRoute();
    error ZeroAmount();
    error ZeroQuote();
    error Slippage();

    constructor(address crvUsd_, address yb_, address sdYb_, address crvUsdYbPool_, address ybSdYbPool_) {
        if (
            crvUsd_ == address(0) || yb_ == address(0) || sdYb_ == address(0) || crvUsdYbPool_ == address(0)
                || ybSdYbPool_ == address(0)
        ) revert InvalidToken();

        crvUsd = crvUsd_;
        yb = yb_;
        sdYb = sdYb_;
        crvUsdYbPool = ISdYbCryptoPool(crvUsdYbPool_);
        ybSdYbPool = ISdYbStablePool(ybSdYbPool_);
    }

    function previewConvert(address tokenIn, address tokenOut, uint256 amountIn)
        external
        view
        returns (uint256 amountOut)
    {
        if (tokenIn != crvUsd || tokenOut != sdYb) revert InvalidToken();
        if (amountIn == 0) return 0;

        (, amountOut) = _oracleQuote(amountIn);
    }

    function convert(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        if (tokenIn != crvUsd || tokenOut != sdYb) revert InvalidToken();
        amountOut = _convert(amountIn, minAmountOut);
    }

    function _convert(uint256 amountIn, uint256 minAmountOut) internal returns (uint256 amountOut) {
        if (amountIn == 0) revert ZeroAmount();
        if (minAmountOut == 0) revert Slippage();

        (uint256 oracleYbOut, uint256 oracleFinalOut) = _oracleQuote(amountIn);
        if (oracleYbOut == 0 || oracleFinalOut == 0) revert ZeroQuote();
        uint256 firstHopMin = Math.mulDiv(oracleYbOut, minAmountOut, oracleFinalOut);
        if (firstHopMin == 0) revert Slippage();

        IERC20(crvUsd).safeTransferFrom(msg.sender, address(this), amountIn);

        uint256 ybBefore = IERC20(yb).balanceOf(address(this));
        IERC20(crvUsd).forceApprove(address(crvUsdYbPool), amountIn);
        crvUsdYbPool.exchange(0, 1, amountIn, firstHopMin);
        IERC20(crvUsd).forceApprove(address(crvUsdYbPool), 0);
        uint256 ybOut = IERC20(yb).balanceOf(address(this)) - ybBefore;
        if (ybOut == 0) revert ZeroQuote();

        uint256 sdYbBefore = IERC20(sdYb).balanceOf(address(this));
        IERC20(yb).forceApprove(address(ybSdYbPool), ybOut);
        ybSdYbPool.exchange(0, 1, ybOut, minAmountOut);
        IERC20(yb).forceApprove(address(ybSdYbPool), 0);

        amountOut = IERC20(sdYb).balanceOf(address(this)) - sdYbBefore;
        if (amountOut == 0) revert ZeroQuote();
        if (amountOut < minAmountOut) revert Slippage();

        IERC20(sdYb).safeTransfer(msg.sender, amountOut);
    }

    function get_exchange_multiple_amount(address[9] calldata route, uint256[3][4] calldata, uint256 amount)
        external
        view
        returns (uint256)
    {
        _validateRoute(route);
        if (amount == 0) return 0;

        (, uint256 oracleOut) = _oracleQuote(amount);
        return oracleOut;
    }

    function exchange_multiple(
        address[9] calldata route,
        uint256[3][4] calldata,
        uint256 amount,
        uint256 expected
    ) external returns (uint256 amountOut) {
        _validateRoute(route);
        return _convert(amount, expected);
    }


    function _oracleQuote(uint256 amountIn) internal view returns (uint256 ybOut, uint256 sdYbOut) {
        uint256 ybPriceInCrvUsd = crvUsdYbPool.price_oracle();
        uint256 sdYbPriceInYb = ybSdYbPool.price_oracle(0);
        if (ybPriceInCrvUsd == 0 || sdYbPriceInYb == 0) return (0, 0);

        // Both pools quote coin1 in coin0 units. The route is coin0 -> coin1 on each hop.
        // Discount each oracle-implied output by that pool's live Curve fee before Strategy slippage.
        ybOut = Math.mulDiv(amountIn, 1e18, ybPriceInCrvUsd);
        ybOut = _applyPoolFee(ybOut, crvUsdYbPool.fee());
        sdYbOut = Math.mulDiv(ybOut, 1e18, sdYbPriceInYb);
        sdYbOut = _applyPoolFee(sdYbOut, ybSdYbPool.fee());
    }

    function _applyPoolFee(uint256 amountOut, uint256 fee) internal pure returns (uint256) {
        if (fee >= CURVE_FEE_DENOMINATOR) return 0;
        return Math.mulDiv(amountOut, CURVE_FEE_DENOMINATOR - fee, CURVE_FEE_DENOMINATOR);
    }

    function _validateRoute(address[9] calldata route) internal view {
        if (
            route[0] != crvUsd || route[1] != address(crvUsdYbPool) || route[2] != yb
                || route[3] != address(ybSdYbPool) || route[4] != sdYb
        ) revert InvalidRoute();
    }
}
