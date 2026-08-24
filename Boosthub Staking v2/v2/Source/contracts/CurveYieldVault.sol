// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICurveYieldVaultStrategy} from "./interfaces/ICurveYieldVaultStrategy.sol";

/// @notice Hardened CurveYield vault with one-time permanent strategy binding.
contract CurveYieldVault is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct PendingWithdrawal {
        uint256 shares;
        uint256 grossAssets;
        uint256 strategyRequestId;
        uint64 unlockTime;
    }

    ICurveYieldVaultStrategy public strategy;
    address public configurator;
    address public feeReceiver;
    address public pendingFeeReceiver;
    uint8 private immutable vaultDecimals;
    mapping(address => PendingWithdrawal) public pendingWithdrawal;

    error ZeroAddress();
    error ZeroAmount();
    error NoShares();
    error StrategyNotSet();
    error StrategyAlreadySet();
    error InvalidStrategy();
    error NotConfigurator();
    error NotFeeReceiver();
    error NotPendingFeeReceiver();
    error CannotSweepWant();
    error InsufficientShares(uint256 minimum, uint256 actual);
    error ActivePendingWithdrawal();
    error PendingWithdrawalMismatch();
    error WithdrawalNotReady(uint256 unlockTime);

    event StrategyBound(address indexed strategy);
    event FeeReceiverProposed(address indexed currentReceiver, address indexed pendingReceiver);
    event FeeReceiverTransferred(address indexed previousReceiver, address indexed newReceiver);
    event Deposit(address indexed user, uint256 assets, uint256 shares, bool strictHarvest);
    event Withdraw(address indexed user, uint256 shares, uint256 assets);
    event TimelockedWithdrawalRequested(
        address indexed user,
        uint256 shares,
        uint256 grossAssets,
        uint256 indexed strategyRequestId,
        uint256 unlockTime
    );
    event TimelockedWithdrawalCompleted(address indexed user, uint256 shares, uint256 assets);
    event TimelockedWithdrawalExitedInstantly(address indexed user, uint256 shares, uint256 assets);
    event TokenRecovered(address indexed token, uint256 amount, address indexed feeReceiver);

    constructor(
        string memory name_,
        string memory symbol_,
        address configurator_,
        address feeReceiver_,
        uint8 decimals_
    ) ERC20(name_, symbol_) {
        if (configurator_ == address(0) || feeReceiver_ == address(0)) revert ZeroAddress();
        configurator = configurator_;
        feeReceiver = feeReceiver_;
        vaultDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return vaultDecimals;
    }

    /// @notice Permanently binds the vault to one strategy and burns configurator authority.
    function setStrategy(address strategy_) external {
        if (msg.sender != configurator) revert NotConfigurator();
        if (address(strategy) != address(0)) revert StrategyAlreadySet();
        if (strategy_ == address(0) || strategy_.code.length == 0) revert InvalidStrategy();
        ICurveYieldVaultStrategy candidate = ICurveYieldVaultStrategy(strategy_);
        if (candidate.vault() != address(this) || candidate.want() == address(0)) revert InvalidStrategy();
        strategy = candidate;
        configurator = address(0);
        emit StrategyBound(strategy_);
    }

    function proposeFeeReceiver(address newReceiver) external {
        if (msg.sender != feeReceiver) revert NotFeeReceiver();
        if (newReceiver == address(0)) revert ZeroAddress();
        pendingFeeReceiver = newReceiver;
        emit FeeReceiverProposed(msg.sender, newReceiver);
    }

    function acceptFeeReceiver() external {
        if (msg.sender != pendingFeeReceiver) revert NotPendingFeeReceiver();
        address previous = feeReceiver;
        feeReceiver = msg.sender;
        pendingFeeReceiver = address(0);
        emit FeeReceiverTransferred(previous, msg.sender);
    }

    function want() public view returns (IERC20) {
        ICurveYieldVaultStrategy activeStrategy = strategy;
        if (address(activeStrategy) == address(0)) revert StrategyNotSet();
        return IERC20(activeStrategy.want());
    }

    function _assetDecimals() internal view returns (uint8) {
        try IERC20Metadata(address(want())).decimals() returns (uint8 assetDecimals) {
            return assetDecimals;
        } catch {
            return vaultDecimals;
        }
    }

    function _assetsToShares(uint256 assets) internal view returns (uint256) {
        uint8 assetDecimals = _assetDecimals();
        if (vaultDecimals == assetDecimals) return assets;
        if (vaultDecimals > assetDecimals) return assets * 10 ** uint256(vaultDecimals - assetDecimals);
        return assets / 10 ** uint256(assetDecimals - vaultDecimals);
    }

    function balance() public view returns (uint256) {
        return want().balanceOf(address(this)) + strategy.balanceOf();
    }

    function economicBalance() public view returns (uint256) {
        uint256 realized = balance();
        uint256 estimated = strategy.estimatedUnharvestedWant();
        return estimated > type(uint256).max - realized ? type(uint256).max : realized + estimated;
    }

    function available() public view returns (uint256) {
        return want().balanceOf(address(this));
    }

    function getPricePerFullShare() public view returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? 1e18 : Math.mulDiv(_assetsToShares(economicBalance()), 1e18, supply);
    }

    function getRealizedPricePerFullShare() external view returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? 1e18 : Math.mulDiv(_assetsToShares(balance()), 1e18, supply);
    }

    function estimatedTokenAprBps() external view returns (uint256) {
        ICurveYieldVaultStrategy activeStrategy = strategy;
        if (address(activeStrategy) == address(0)) return 0;
        return activeStrategy.estimatedTokenAprBps();
    }

    function depositAll() external {
        deposit(want().balanceOf(msg.sender));
    }

    /// @notice Standard deposit. Harvest is best effort and can never block the deposit.
    function deposit(uint256 amount) public nonReentrant returns (uint256 shares) {
        if (amount == 0) revert ZeroAmount();
        strategy.beforeDeposit();
        uint256 pool = economicBalance();
        shares = _receiveEarnAndPrice(amount, pool, false);
        emit Deposit(msg.sender, amount, shares, false);
    }

    /// @notice Strict deposit. Reverts if the pre-deposit harvest fails.
    function depositWithStrictHarvest(uint256 amount, uint256 minimumShares)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (amount == 0) revert ZeroAmount();
        strategy.beforeDepositStrict();
        uint256 pool = balance();
        shares = _receiveEarnAndPrice(amount, pool, true);
        if (shares < minimumShares) revert InsufficientShares(minimumShares, shares);
        emit Deposit(msg.sender, amount, shares, true);
    }

    function earn() public {
        uint256 bal = available();
        if (bal == 0) return;
        want().safeTransfer(address(strategy), bal);
        strategy.deposit();
    }

    function withdrawAll() external returns (uint256 assets) {
        assets = withdraw(balanceOf(msg.sender));
    }

    /// @notice Standard instant withdrawal. Harvest is best effort and cannot block principal exit.
    /// @dev Any instant-exit tax configured in the staking backend/strategy is applied by the strategy.
    function withdraw(uint256 shares) public nonReentrant returns (uint256 assets) {
        if (shares == 0) revert ZeroAmount();
        strategy.beforeWithdraw();
        assets = _withdrawInstant(shares);
    }

    /// @notice Advanced withdrawal entry point.
    /// @param shares Shares being withdrawn. Reuse the same share amount when acting on a pending timelock.
    /// @param strictHarvest False = best-effort harvest; true = harvest must succeed.
    /// @param timelocked False = instant path; true = create/complete the timelocked path.
    function withdrawWithOptions(uint256 shares, bool strictHarvest, bool timelocked)
        external
        nonReentrant
        returns (uint256 assets)
    {
        if (shares == 0) revert ZeroAmount();
        _beforeWithdraw(strictHarvest);

        PendingWithdrawal memory pending = pendingWithdrawal[msg.sender];
        if (timelocked) {
            if (pending.shares == 0) return _requestTimelockedWithdrawal(shares);
            if (pending.shares != shares) revert PendingWithdrawalMismatch();
            if (block.timestamp < pending.unlockTime) revert WithdrawalNotReady(pending.unlockTime);
            return _completeTimelockedWithdrawal(pending);
        }

        if (pending.shares != 0 && pending.shares == shares) {
            return _exitPendingInstantly(pending);
        }
        return _withdrawInstant(shares);
    }

    /// @notice Permissionless recovery of non-want tokens to the current fee receiver.
    function inCaseTokensGetStuck(address token) external nonReentrant {
        if (token == address(0)) revert ZeroAddress();
        if (token == address(want())) revert CannotSweepWant();
        uint256 amount = IERC20(token).balanceOf(address(this));
        address receiver = feeReceiver;
        if (amount != 0) IERC20(token).safeTransfer(receiver, amount);
        emit TokenRecovered(token, amount, receiver);
    }

    function _beforeWithdraw(bool strictHarvest) internal {
        if (strictHarvest) strategy.beforeWithdrawStrict();
        else strategy.beforeWithdraw();
    }

    function _withdrawInstant(uint256 shares) internal returns (uint256 assets) {
        if (shares > balanceOf(msg.sender)) revert NoShares();
        uint256 requestedAssets = Math.mulDiv(balance(), shares, totalSupply());
        _burn(msg.sender, shares);

        IERC20 wantToken = want();
        uint256 vaultBalance = wantToken.balanceOf(address(this));
        if (vaultBalance < requestedAssets) {
            uint256 shortfall = requestedAssets - vaultBalance;
            strategy.withdrawInstant(shortfall);
            vaultBalance = wantToken.balanceOf(address(this));
        }
        assets = vaultBalance < requestedAssets ? vaultBalance : requestedAssets;
        if (assets != 0) wantToken.safeTransfer(msg.sender, assets);
        emit Withdraw(msg.sender, shares, assets);
    }

    function _requestTimelockedWithdrawal(uint256 shares) internal returns (uint256 grossAssets) {
        if (pendingWithdrawal[msg.sender].shares != 0) revert ActivePendingWithdrawal();
        if (shares > balanceOf(msg.sender)) revert NoShares();

        grossAssets = Math.mulDiv(balance(), shares, totalSupply());
        _burn(msg.sender, shares);

        IERC20 wantToken = want();
        uint256 vaultIdle = wantToken.balanceOf(address(this));
        uint256 seedAmount = vaultIdle < grossAssets ? vaultIdle : grossAssets;
        if (seedAmount != 0) wantToken.safeTransfer(address(strategy), seedAmount);

        (uint256 strategyRequestId, uint256 unlockTime) = strategy.requestWithdrawal(grossAssets);
        pendingWithdrawal[msg.sender] = PendingWithdrawal({
            shares: shares,
            grossAssets: grossAssets,
            strategyRequestId: strategyRequestId,
            unlockTime: uint64(unlockTime)
        });
        emit TimelockedWithdrawalRequested(msg.sender, shares, grossAssets, strategyRequestId, unlockTime);
    }

    function _completeTimelockedWithdrawal(PendingWithdrawal memory pending) internal returns (uint256 assets) {
        delete pendingWithdrawal[msg.sender];
        assets = strategy.completeWithdrawal(pending.strategyRequestId);
        if (assets != 0) want().safeTransfer(msg.sender, assets);
        emit TimelockedWithdrawalCompleted(msg.sender, pending.shares, assets);
        emit Withdraw(msg.sender, pending.shares, assets);
    }

    function _exitPendingInstantly(PendingWithdrawal memory pending) internal returns (uint256 assets) {
        delete pendingWithdrawal[msg.sender];
        assets = strategy.withdrawPendingInstant(pending.strategyRequestId);
        if (assets != 0) want().safeTransfer(msg.sender, assets);
        emit TimelockedWithdrawalExitedInstantly(msg.sender, pending.shares, assets);
        emit Withdraw(msg.sender, pending.shares, assets);
    }

    function _receiveEarnAndPrice(uint256 requestedAmount, uint256 pool, bool strictHarvest)
        internal
        returns (uint256 shares)
    {
        IERC20 wantToken = want();
        uint256 beforeBalance = wantToken.balanceOf(address(this));
        wantToken.safeTransferFrom(msg.sender, address(this), requestedAmount);
        if (wantToken.balanceOf(address(this)) == beforeBalance) revert ZeroAmount();
        earn();

        uint256 afterBalance = strictHarvest ? balance() : economicBalance();
        if (afterBalance <= pool) revert ZeroAmount();
        uint256 contributedAssets = afterBalance - pool;
        uint256 supply = totalSupply();
        shares = supply == 0 ? _assetsToShares(contributedAssets) : Math.mulDiv(contributedAssets, supply, pool);
        if (shares == 0) revert NoShares();
        _mint(msg.sender, shares);
    }
}
