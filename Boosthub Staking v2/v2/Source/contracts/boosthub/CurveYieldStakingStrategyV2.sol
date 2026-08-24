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

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICurveYieldVaultStrategy} from "../interfaces/ICurveYieldVaultStrategy.sol";
import {ICurveYieldVault} from "../interfaces/ICurveYieldVault.sol";
import {ICurveChildGauge} from "../interfaces/ICurveChildGauge.sol";

interface ICurveYieldStaking {
    function deposit_with_withdraw_fee(uint256 amount) external;
    function withdraw_with_tax(uint256 amount) external;
    function request_withdrawal(uint256 amount) external returns (uint256 requestId, uint256 unlockTime);
    function complete_queued_withdrawal(uint256 requestId) external returns (uint256 received);
    function withdraw_queued_immediate(uint256 requestId) external returns (uint256 received);
    function harvest() external;
    function claim_rewards() external;
    function checkpoint(address account) external;
    function balanceOf(address account) external view returns (uint256);
    function active_balance(address account) external view returns (uint256);
    function claimable_reward(address account, address token) external view returns (uint256);
}


interface ICurveYieldRewardConverter {
    function previewConvert(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256 amountOut);
    function convert(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        external
        returns (uint256 amountOut);
}

contract CurveYieldStakingStrategyV2 is ICurveYieldVaultStrategy, Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant FEE_DENOMINATOR = 10_000;
    uint256 public constant CALLER_FEE_BPS = 10;
    uint256 public constant TREASURY_FEE_BPS = 290;
    uint256 public constant MAX_SLIPPAGE_BPS = 400;
    uint256 public constant TOKEN_RESCUE_DELAY = 60 days;

    address public immutable override want;
    address public immutable override vault;
    ICurveYieldStaking public immutable staking;
    uint16 public maxSlippageBps;
    uint256 public lastHarvest;
    uint256 public override estimatedTokenAprBps;
    uint256 public aprLastUpdate;
    uint256 public reservedWithdrawalAssets;
    uint256 public nextStrategyWithdrawalId = 1;
    address public cyGov;
    address public cyGovChildGauge;

    struct PendingStrategyWithdrawal {
        uint256 grossAmount;
        uint256 reservedIdle;
        uint256 stakingRequestId;
        uint64 unlockTime;
    }

    mapping(uint256 => PendingStrategyWithdrawal) public pendingStrategyWithdrawals;

    struct RewardRoute {
        address token;
        address converter;
        uint256 minAmount;
        bool enabled;
    }

    RewardRoute[] internal rewardRoutes;
    mapping(address => uint256) internal rewardRouteIndexPlusOne;
    mapping(address => uint256) public tokenRescueReadyAt;

    event Deposit(uint256 tvl);
    event Withdraw(uint256 tvl);
    event StratHarvest(address indexed harvester, uint256 wantHarvested, uint256 tvl);
    event ChargedFees(address indexed token, uint256 callerFee, uint256 treasuryFee);
    event RewardRouteSet(address indexed token, uint256 minAmount);
    event RewardRouteRemoved(address indexed token);
    event SlippageSet(uint16 maxSlippageBps);
    event TokenRescueQueued(address indexed token, uint256 readyAt);
    event TokenRescued(address indexed token, uint256 amount);
    event StrategyWithdrawalRequested(uint256 indexed requestId, uint256 grossAmount, uint256 reservedIdle, uint256 stakingRequestId, uint256 unlockTime);
    event StrategyWithdrawalCompleted(uint256 indexed requestId, uint256 received);
    event StrategyWithdrawalExitedInstantly(uint256 indexed requestId, uint256 received);
    event CyGovSet(address indexed cyGov);
    event CyGovChildGaugeSet(address indexed gauge);
    event CyGovDepositedToChildGauge(address indexed gauge, uint256 amount);

    error ZeroAddress();
    error InvalidRoute();
    error RouteNotFound();
    error SlippageTooHigh();
    error TimelockNotReady();
    error NoPendingChange();
    error NotVault();
    error InvalidWithdrawalRequest();
    error WithdrawalNotReady(uint256 unlockTime);
    error CyGovAlreadySet();
    error CyGovNotSet();
    error CyGovChildGaugeAlreadySet();
    error CyGovChildGaugeNotSet();
    error InvalidCyGovChildGauge();
    error CyGovRewardRouteForbidden();

    constructor(
        address want_,
        address vault_,
        address staking_,
        address owner_,
        address[] memory initialRouteTokens,
        address[] memory initialRouteConverters,
        uint256[] memory initialRouteMinAmounts
    ) Ownable(owner_) {
        if (
            want_ == address(0) || vault_ == address(0) || staking_ == address(0)
                || owner_ == address(0)
        ) revert ZeroAddress();
        if (
            initialRouteTokens.length != initialRouteConverters.length
                || initialRouteTokens.length != initialRouteMinAmounts.length
        ) revert InvalidRoute();

        want = want_;
        vault = vault_;
        staking = ICurveYieldStaking(staking_);
        maxSlippageBps = 100;

        uint256 length = initialRouteTokens.length;
        for (uint256 i; i < length; ++i) {
            _setRewardRouteImmediate(initialRouteTokens[i], initialRouteConverters[i], initialRouteMinAmounts[i]);
        }

        _giveAllowances();
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    /// @notice One-time identification of the cyGOV reward token for this strategy.
    /// @dev cyGOV is claimed from BoostHubStaking like any other reward, but is never compounded.
    function setCyGov(address cyGov_) external onlyOwner {
        if (cyGov_ == address(0) || cyGov_.code.length == 0) revert ZeroAddress();
        if (cyGov != address(0)) revert CyGovAlreadySet();
        if (rewardRouteIndexPlusOne[cyGov_] != 0) revert CyGovRewardRouteForbidden();
        cyGov = cyGov_;
        emit CyGovSet(cyGov_);
    }

    /// @notice One-time binding to the Curve ChildGauge that distributes this vault's cyGOV.
    /// @dev The gauge must stake this vault receipt token and authorize this strategy as cyGOV distributor.
    function setCyGovChildGauge(address gauge) external onlyOwner {
        if (cyGov == address(0)) revert CyGovNotSet();
        if (gauge == address(0) || gauge.code.length == 0) revert InvalidCyGovChildGauge();
        if (cyGovChildGauge != address(0)) revert CyGovChildGaugeAlreadySet();
        if (ICurveChildGauge(gauge).lp_token() != vault) revert InvalidCyGovChildGauge();
        (address rewardDistributor, , , , ) = ICurveChildGauge(gauge).reward_data(cyGov);
        if (rewardDistributor != address(this)) revert InvalidCyGovChildGauge();
        cyGovChildGauge = gauge;
        emit CyGovChildGaugeSet(gauge);
    }

    /// @notice Normal vault entry only checkpoints already-smoothed rewards. It never harvests BoostHub.
    function beforeDeposit() external override onlyVault {
        staking.checkpoint(address(this));
    }

    function beforeDepositStrict() external override onlyVault nonReentrant {
        if (paused()) revert EnforcedPause();
        _harvest(address(0));
    }

    /// @notice Normal vault exit only checkpoints already-smoothed rewards. It never harvests BoostHub.
    function beforeWithdraw() external override onlyVault {
        staking.checkpoint(address(this));
    }

    function beforeWithdrawStrict() external override onlyVault nonReentrant {
        if (paused()) revert EnforcedPause();
        _harvest(address(0));
    }

    function deposit() external override onlyVault whenNotPaused {
        _depositIdle();
    }

    function withdrawInstant(uint256 amount) external override onlyVault nonReentrant returns (uint256 received) {
        if (amount == 0) return 0;
        uint256 idle = _unreservedIdle();
        uint256 fromIdle = idle < amount ? idle : amount;
        received = fromIdle;

        uint256 remaining = amount - fromIdle;
        if (remaining != 0) {
            uint256 beforeBal = IERC20(want).balanceOf(address(this));
            staking.withdraw_with_tax(remaining);
            uint256 afterBal = IERC20(want).balanceOf(address(this));
            received += afterBal - beforeBal;
        }

        if (received != 0) IERC20(want).safeTransfer(vault, received);
        emit Withdraw(balanceOf());
    }

    function requestWithdrawal(uint256 amount)
        external
        override
        onlyVault
        nonReentrant
        returns (uint256 requestId, uint256 unlockTime)
    {
        if (amount == 0) revert InvalidWithdrawalRequest();
        uint256 idle = _unreservedIdle();
        uint256 reservedIdle = idle < amount ? idle : amount;
        uint256 remaining = amount - reservedIdle;
        uint256 stakingRequestId;

        if (remaining != 0) {
            (stakingRequestId, unlockTime) = staking.request_withdrawal(remaining);
        } else {
            unlockTime = block.timestamp;
        }

        reservedWithdrawalAssets += reservedIdle;
        requestId = nextStrategyWithdrawalId++;
        pendingStrategyWithdrawals[requestId] = PendingStrategyWithdrawal({
            grossAmount: amount,
            reservedIdle: reservedIdle,
            stakingRequestId: stakingRequestId,
            unlockTime: uint64(unlockTime)
        });
        emit StrategyWithdrawalRequested(requestId, amount, reservedIdle, stakingRequestId, unlockTime);
    }

    function completeWithdrawal(uint256 requestId)
        external
        override
        onlyVault
        nonReentrant
        returns (uint256 received)
    {
        PendingStrategyWithdrawal memory request = pendingStrategyWithdrawals[requestId];
        if (request.grossAmount == 0) revert InvalidWithdrawalRequest();
        if (block.timestamp < request.unlockTime) revert WithdrawalNotReady(request.unlockTime);
        delete pendingStrategyWithdrawals[requestId];
        reservedWithdrawalAssets -= request.reservedIdle;
        received = request.reservedIdle;
        if (request.stakingRequestId != 0) received += staking.complete_queued_withdrawal(request.stakingRequestId);
        if (received != 0) IERC20(want).safeTransfer(vault, received);
        emit StrategyWithdrawalCompleted(requestId, received);
    }

    function withdrawPendingInstant(uint256 requestId)
        external
        override
        onlyVault
        nonReentrant
        returns (uint256 received)
    {
        PendingStrategyWithdrawal memory request = pendingStrategyWithdrawals[requestId];
        if (request.grossAmount == 0) revert InvalidWithdrawalRequest();
        delete pendingStrategyWithdrawals[requestId];
        reservedWithdrawalAssets -= request.reservedIdle;
        received = request.reservedIdle;
        if (request.stakingRequestId != 0) received += staking.withdraw_queued_immediate(request.stakingRequestId);
        if (received != 0) IERC20(want).safeTransfer(vault, received);
        emit StrategyWithdrawalExitedInstantly(requestId, received);
    }

    function harvest() external nonReentrant whenNotPaused {
        _harvest(msg.sender);
    }

    function harvest(address callFeeRecipient) external nonReentrant whenNotPaused {
        if (callFeeRecipient == address(0)) revert ZeroAddress();
        _harvest(callFeeRecipient);
    }

    function _harvest(address callFeeRecipient) internal {
        uint256 tvlBefore = balanceOf();
        uint256 elapsed = aprLastUpdate == 0 ? 0 : block.timestamp - aprLastUpdate;
        uint256 beforeWant = IERC20(want).balanceOf(address(this));
        staking.harvest();
        staking.claim_rewards();
        _depositCyGovToChildGauge();

        uint256 afterClaimWant = IERC20(want).balanceOf(address(this));
        if (afterClaimWant > beforeWant) {
            _chargeFees(want, afterClaimWant - beforeWant, callFeeRecipient);
        }

        _compoundRewards(callFeeRecipient);
        uint256 afterWant = IERC20(want).balanceOf(address(this));
        uint256 wantHarvested = afterWant > beforeWant ? afterWant - beforeWant : 0;

        if (wantHarvested > 0) {
            if (tvlBefore > 0 && elapsed > 0) {
                estimatedTokenAprBps = Math.mulDiv(wantHarvested, 365 days * FEE_DENOMINATOR, tvlBefore * elapsed);
            } else {
                estimatedTokenAprBps = 0;
            }
            _depositIdle();
            lastHarvest = block.timestamp;
            aprLastUpdate = block.timestamp;
            emit StratHarvest(msg.sender, wantHarvested, balanceOf());
        }
    }

    function _compoundRewards(address callFeeRecipient) internal {
        uint256 length = rewardRoutes.length;
        for (uint256 i; i < length; i++) {
            RewardRoute storage currentRoute = rewardRoutes[i];
            if (!currentRoute.enabled) continue;
            if (currentRoute.token == cyGov) continue;

            uint256 bal = IERC20(currentRoute.token).balanceOf(address(this));
            if (bal < currentRoute.minAmount) continue;
            if (currentRoute.token == want) continue;

            uint256 amountToCompound = _chargeFees(currentRoute.token, bal, callFeeRecipient);
            if (amountToCompound == 0) continue;

            IERC20(currentRoute.token).forceApprove(currentRoute.converter, amountToCompound);
            uint256 quoted =
                ICurveYieldRewardConverter(currentRoute.converter).previewConvert(currentRoute.token, want, amountToCompound);
            uint256 minOut = quoted * (FEE_DENOMINATOR - maxSlippageBps) / FEE_DENOMINATOR;
            ICurveYieldRewardConverter(currentRoute.converter).convert(currentRoute.token, want, amountToCompound, minOut);
            IERC20(currentRoute.token).forceApprove(currentRoute.converter, 0);
        }
    }

    function _depositCyGovToChildGauge() internal {
        address token = cyGov;
        if (token == address(0)) return;
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) return;
        address gauge = cyGovChildGauge;
        if (gauge == address(0)) revert CyGovChildGaugeNotSet();
        IERC20(token).forceApprove(gauge, amount);
        ICurveChildGauge(gauge).deposit_reward_token(cyGov, amount, 1296000);
        IERC20(token).forceApprove(gauge, 0);
        emit CyGovDepositedToChildGauge(gauge, amount);
    }

    function _chargeFees(address token, uint256 amount, address callFeeRecipient) internal returns (uint256 net) {
        uint256 callerFee = callFeeRecipient == address(0) ? 0 : amount * CALLER_FEE_BPS / FEE_DENOMINATOR;
        uint256 treasuryFee = amount * TREASURY_FEE_BPS / FEE_DENOMINATOR;

        if (callerFee > 0) IERC20(token).safeTransfer(callFeeRecipient, callerFee);
        if (treasuryFee > 0) IERC20(token).safeTransfer(ICurveYieldVault(vault).feeReceiver(), treasuryFee);

        emit ChargedFees(token, callerFee, treasuryFee);
        return amount - callerFee - treasuryFee;
    }

    function addRewardRoute(
        address token,
        address converter,
        uint256 minAmount
    ) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (token == cyGov && cyGov != address(0)) revert CyGovRewardRouteForbidden();
        if (token != want && converter == address(0)) revert ZeroAddress();

        // Any successful enable/re-enable/reconfiguration invalidates a previously queued rescue.
        delete tokenRescueReadyAt[token];

        uint256 indexPlusOne = rewardRouteIndexPlusOne[token];
        if (indexPlusOne == 0) {
            rewardRoutes.push(RewardRoute(token, converter, minAmount, true));
            rewardRouteIndexPlusOne[token] = rewardRoutes.length;
        } else {
            RewardRoute storage configuredRoute = rewardRoutes[indexPlusOne - 1];
            configuredRoute.converter = converter;
            configuredRoute.minAmount = minAmount;
            configuredRoute.enabled = true;
        }
        emit RewardRouteSet(token, minAmount);
    }

    function removeRewardRoute(address token) external onlyOwner {
        uint256 indexPlusOne = rewardRouteIndexPlusOne[token];
        if (indexPlusOne == 0) revert RouteNotFound();
        rewardRoutes[indexPlusOne - 1].enabled = false;
        emit RewardRouteRemoved(token);
    }

    function _setRewardRouteImmediate(address token, address converter, uint256 minAmount) internal {
        if (token == address(0)) revert ZeroAddress();
        if (token == cyGov && cyGov != address(0)) revert CyGovRewardRouteForbidden();
        if (token != want && converter == address(0)) revert ZeroAddress();
        if (rewardRouteIndexPlusOne[token] != 0) revert InvalidRoute();
        rewardRoutes.push(RewardRoute(token, converter, minAmount, true));
        rewardRouteIndexPlusOne[token] = rewardRoutes.length;
        emit RewardRouteSet(token, minAmount);
    }

    function setMaxSlippageBps(uint16 maxSlippageBps_) external onlyOwner {
        if (maxSlippageBps_ > MAX_SLIPPAGE_BPS) revert SlippageTooHigh();
        maxSlippageBps = maxSlippageBps_;
        emit SlippageSet(maxSlippageBps_);
    }

    function rewardRoutesLength() external view returns (uint256) {
        return rewardRoutes.length;
    }

    function rewardRoute(address token) external view returns (RewardRoute memory route) {
        uint256 indexPlusOne = rewardRouteIndexPlusOne[token];
        if (indexPlusOne == 0) revert RouteNotFound();
        return rewardRoutes[indexPlusOne - 1];
    }

    function estimatedUnharvestedWant() external view override returns (uint256 estimatedWant) {
        estimatedWant = staking.claimable_reward(address(this), want);
        uint256 length = rewardRoutes.length;
        for (uint256 i; i < length; ++i) {
            RewardRoute storage currentRoute = rewardRoutes[i];
            if (!currentRoute.enabled || currentRoute.token == cyGov) continue;
            uint256 amount = IERC20(currentRoute.token).balanceOf(address(this))
                + staking.claimable_reward(address(this), currentRoute.token);
            if (amount == 0) continue;
            if (currentRoute.token == want) {
                estimatedWant += amount;
                continue;
            }
            uint256 quote = ICurveYieldRewardConverter(currentRoute.converter).previewConvert(
                currentRoute.token, want, amount
            );
            if (quote == 0) revert InvalidRoute();
            estimatedWant += quote;
        }
    }

    function _depositIdle() internal {
        uint256 wantBal = _unreservedIdle();
        if (wantBal == 0) return;
        staking.deposit_with_withdraw_fee(wantBal);
        uint256 tvl = balanceOf();
        if (aprLastUpdate == 0 && tvl > 0) aprLastUpdate = block.timestamp;
        emit Deposit(tvl);
    }

    function _unreservedIdle() internal view returns (uint256 idle) {
        uint256 bal = IERC20(want).balanceOf(address(this));
        uint256 reserved = reservedWithdrawalAssets;
        idle = bal > reserved ? bal - reserved : 0;
    }

    function balanceOf() public view override returns (uint256) {
        return _unreservedIdle() + staking.active_balance(address(this));
    }

    function balanceOfWant() public view returns (uint256) {
        return _unreservedIdle();
    }

    function balanceOfPool() public view returns (uint256) {
        return staking.active_balance(address(this));
    }

    function pause() public onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
        _giveAllowances();
        _depositIdle();
    }

    function inCaseTokensGetStuck(address token) external onlyOwner {
        if (token == want || token == cyGov) revert InvalidRoute();
        uint256 indexPlusOne = rewardRouteIndexPlusOne[token];
        if (indexPlusOne != 0 && rewardRoutes[indexPlusOne - 1].enabled) revert InvalidRoute();
        tokenRescueReadyAt[token] = block.timestamp + TOKEN_RESCUE_DELAY;
        emit TokenRescueQueued(token, tokenRescueReadyAt[token]);
    }

    function executeTokenRescue(address token) external onlyOwner {
        uint256 readyAt = tokenRescueReadyAt[token];
        if (readyAt == 0) revert NoPendingChange();
        if (block.timestamp < readyAt) revert TimelockNotReady();

        uint256 indexPlusOne = rewardRouteIndexPlusOne[token];
        if (token == want || token == cyGov || (indexPlusOne != 0 && rewardRoutes[indexPlusOne - 1].enabled)) revert InvalidRoute();

        delete tokenRescueReadyAt[token];
        uint256 balance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(msg.sender, balance);
        emit TokenRescued(token, balance);
    }

    function _giveAllowances() internal {
        IERC20(want).forceApprove(address(staking), type(uint256).max);
    }
}
