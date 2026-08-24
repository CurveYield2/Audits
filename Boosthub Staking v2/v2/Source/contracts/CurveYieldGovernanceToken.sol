// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

/**
 * @title CurveYield System Component
 * @notice CurveYield is a decentralized NGO building optimized DeFi systems for the good of all.
 * @dev Governance token with a hard cap, time-based unlock schedule, per-minter allocations,
 *      and centralized reservations that prevent approved mint obligations from overbooking supply.
 */

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Capped} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

contract CurveYieldGovernanceToken is ERC20, ERC20Capped, Ownable2Step {
    uint256 public constant BPS = 10_000;
    uint256 public constant MIN_ALLOCATION_BPS = 3_000;
    uint256 public constant CAP = 1_000_000_000_000 ether;
    uint256 public constant INITIAL_UNLOCK = 200_000_000_000 ether;
    uint256 public constant MINT_MONTH = 30 days;

    uint256 public constant FIRST_MONTHLY_UNLOCK = 20_000_000_000 ether;
    uint256 public constant FIRST_MONTHLY_DECREMENT = 500_000_000 ether;
    uint256 public constant FIRST_DECLINE_MONTHS = 21;

    uint256 public constant SECOND_MONTHLY_UNLOCK = 9_800_000_000 ether;
    uint256 public constant SECOND_MONTHLY_DECREMENT = 200_000_000 ether;
    uint256 public constant SECOND_DECLINE_MONTHS = 30;

    uint256 public constant MONTHLY_UNLOCK_FLOOR = 4_000_000_000 ether;

    uint256 public constant TIMELOCK_ACTIVATION_DELAY = 7 days;
    uint256 public constant OWNER_MINT_DELAY = 7 days;

    struct OwnerMintRequest {
        address receiver;
        uint128 amount;
        uint64 readyAt;
        uint256 reservationId;
        bool completed;
        bool cancelled;
    }

    struct MinterAllocation {
        uint128 initialCap;
        uint16 additionalBps;
    }

    struct MintReservation {
        address minter;
        uint128 amount;
        uint64 executableAt;
        bool quotaControlled;
        bool open;
    }

    uint64 public immutable deploymentTimestamp;
    uint64 public immutable timelocksActiveAt;

    mapping(address => bool) public isMinter;
    mapping(address => MinterAllocation) public minterAllocation;
    mapping(address => MinterAllocation) public originalMinterAllocation;
    mapping(address => bool) public originalMinterAllocationConfigured;
    uint256 public totalInitialMinterCaps;
    uint256 public totalAdditionalMinterBps;

    mapping(address => uint256) public mintedByMinter;
    mapping(address => uint256) public reservedByMinter;
    uint256 public totalReservedMint;

    uint256 public nextMintReservationId = 1;
    mapping(uint256 => MintReservation) public mintReservations;
    mapping(uint256 => bool) public protectedMintReservation;

    /// @notice Approved endpoints for ordinary cyGOV transfers.
    /// @dev Every non-mint/non-burn transfer must include at least one approved endpoint.
    mapping(address => bool) public transferWhitelist;

    uint256 public nextOwnerMintRequestId = 1;
    mapping(uint256 => OwnerMintRequest) public ownerMintRequests;

    error ZeroAddress();
    error ZeroAmount();
    error UnauthorizedMinter();
    error TimelockNotReady();
    error OwnerMintRequiresTimelock();
    error InvalidOwnerMintRequest();
    error InvalidMintReservation();
    error MintReservationNotReady();
    error MintReservationInsufficient();
    error MintExceedsUnlockedSupply(uint256 requested, uint256 available);
    error MintExceedsMinterAllocation(uint256 requested, uint256 available);
    error InvalidMinterAllocation();
    error OriginalMinterAllocationNotConfigured();
    error MinterAllocationOutsidePermittedRange(
        uint256 initialCap,
        uint256 minimumInitialCap,
        uint256 maximumInitialCap,
        uint256 additionalBps,
        uint256 minimumAdditionalBps,
        uint256 maximumAdditionalBps
    );
    error MinterAllocationBelowUsage(uint256 used, uint256 proposedAllowance);
    error MinterAllocationTotalsExceeded();
    error ValueTooLarge();
    error TransferNotAllowed(address from, address to);

    event MinterSet(address indexed minter, bool allowed);
    event OriginalMinterAllocationSet(
        address indexed minter, uint256 initialCap, uint256 additionalBps
    );
    event MinterAllocationSet(address indexed minter, uint256 initialCap, uint256 additionalBps);
    event MintReserved(
        uint256 indexed id, address indexed minter, uint256 amount, uint256 executableAt
    );
    event MintReservationIncreased(uint256 indexed id, uint256 amountAdded, uint256 newAmount);
    event MintReservationConsumed(
        uint256 indexed id, address indexed minter, address indexed receiver, uint256 amount
    );
    event MintReservationCancelled(uint256 indexed id, address indexed minter, uint256 amountReleased);
    event MintReservationUnavailable(address indexed minter, uint256 requested, uint256 executableAt);
    event OwnerMintQueued(
        uint256 indexed id, address indexed receiver, uint256 amount, uint256 readyAt, uint256 reservationId
    );
    event OwnerMintExecuted(uint256 indexed id, address indexed receiver, uint256 amount);
    event OwnerMintCancelled(uint256 indexed id, address indexed receiver, uint256 amount);
    event TransferWhitelistSet(address indexed account, bool allowed);

    constructor(address initialOwner_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        ERC20Capped(CAP)
        Ownable(initialOwner_)
    {
        if (initialOwner_ == address(0)) revert ZeroAddress();
        deploymentTimestamp = uint64(block.timestamp);
        timelocksActiveAt = uint64(block.timestamp + TIMELOCK_ACTIVATION_DELAY);
    }

    /// @notice Adds or removes an approved endpoint for ordinary cyGOV transfers.
    /// @dev Minting and burning are not restricted by this list. Liquidity pools should remain
    /// unapproved when a dedicated cyGOV router/converter is intended to be the sole swap path.
    function setTransferWhitelist(address account, bool allowed) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        transferWhitelist[account] = allowed;
        emit TransferWhitelistSet(account, allowed);
    }

    function monthlyMintAllotment(uint256 monthIndex) public pure returns (uint256) {
        if (monthIndex == 0) return 0;
        if (monthIndex <= FIRST_DECLINE_MONTHS) {
            return FIRST_MONTHLY_UNLOCK - (monthIndex - 1) * FIRST_MONTHLY_DECREMENT;
        }
        uint256 secondIndex = monthIndex - FIRST_DECLINE_MONTHS;
        if (secondIndex <= SECOND_DECLINE_MONTHS) {
            return SECOND_MONTHLY_UNLOCK - (secondIndex - 1) * SECOND_MONTHLY_DECREMENT;
        }
        return MONTHLY_UNLOCK_FLOOR;
    }

    function completedMintMonthsAt(uint256 timestamp) public view returns (uint256) {
        if (timestamp <= deploymentTimestamp) return 0;
        return (timestamp - deploymentTimestamp) / MINT_MONTH;
    }

    function unlockedSupplyAt(uint256 timestamp) public view returns (uint256 unlocked) {
        uint256 monthsElapsed = completedMintMonthsAt(timestamp);
        unlocked = INITIAL_UNLOCK;

        uint256 firstMonths = monthsElapsed > FIRST_DECLINE_MONTHS
            ? FIRST_DECLINE_MONTHS
            : monthsElapsed;
        if (firstMonths != 0) {
            unlocked += firstMonths
                * (2 * FIRST_MONTHLY_UNLOCK - (firstMonths - 1) * FIRST_MONTHLY_DECREMENT) / 2;
        }

        if (monthsElapsed > FIRST_DECLINE_MONTHS) {
            uint256 remainingMonths = monthsElapsed - FIRST_DECLINE_MONTHS;
            uint256 secondMonths = remainingMonths > SECOND_DECLINE_MONTHS
                ? SECOND_DECLINE_MONTHS
                : remainingMonths;
            if (secondMonths != 0) {
                unlocked += secondMonths
                    * (2 * SECOND_MONTHLY_UNLOCK - (secondMonths - 1) * SECOND_MONTHLY_DECREMENT) / 2;
            }
            if (remainingMonths > SECOND_DECLINE_MONTHS) {
                unlocked += (remainingMonths - SECOND_DECLINE_MONTHS) * MONTHLY_UNLOCK_FLOOR;
            }
        }

        if (unlocked > CAP) return CAP;
    }

    function unlockedSupply() public view returns (uint256) {
        return unlockedSupplyAt(block.timestamp);
    }

    function currentMonthlyMintAllotment() external view returns (uint256) {
        return monthlyMintAllotment(completedMintMonthsAt(block.timestamp) + 1);
    }

    function additionalUnlockedSupplyAt(uint256 timestamp) public view returns (uint256) {
        uint256 unlocked = unlockedSupplyAt(timestamp);
        return unlocked > INITIAL_UNLOCK ? unlocked - INITIAL_UNLOCK : 0;
    }

    function minterMintAllowanceAt(address minter, uint256 timestamp) public view returns (uint256) {
        MinterAllocation memory allocation = minterAllocation[minter];
        return uint256(allocation.initialCap)
            + additionalUnlockedSupplyAt(timestamp) * allocation.additionalBps / BPS;
    }

    function minterMintAllowance(address minter) external view returns (uint256) {
        return minterMintAllowanceAt(minter, block.timestamp);
    }

    function totalMintCommitments() external view returns (uint256) {
        return totalSupply() + totalReservedMint;
    }

    function unreservedMintableSupply() public view returns (uint256) {
        return _globalAvailableAt(block.timestamp);
    }

    function availableMintableFor(address minter) public view returns (uint256) {
        return _availableForAt(minter, block.timestamp, true);
    }

    function remainingMintableSupply() external view returns (uint256) {
        return CAP - totalSupply();
    }

    /// @notice Adds or removes a minter immediately. Governance delay is provided by the DAO.
    function setMinter(address minter, bool allowed) external onlyOwner {
        _configureMinter(minter, allowed);
    }

    function setMinters(address[] calldata minters, bool allowed) external onlyOwner {
        uint256 length = minters.length;
        for (uint256 i; i < length;) {
            _configureMinter(minters[i], allowed);
            unchecked { ++i; }
        }
    }

    function _configureMinter(address minter, bool allowed) internal {
        if (minter == address(0)) revert ZeroAddress();
        _setMinterNow(minter, allowed);
    }

    function _setMinterNow(address minter, bool allowed) internal {
        bool wasAllowed = isMinter[minter];
        if (wasAllowed && !allowed) {
            // Retirement removes all future mint authority immediately. Historical protected
            // reservations remain in totalReservedMint and may only be discharged as recorded.
            MinterAllocation memory active = minterAllocation[minter];
            if (active.initialCap != 0 || active.additionalBps != 0) {
                totalInitialMinterCaps -= active.initialCap;
                totalAdditionalMinterBps -= active.additionalBps;
                delete minterAllocation[minter];
                emit MinterAllocationSet(minter, 0, 0);
            }
        }
        isMinter[minter] = allowed;
        emit MinterSet(minter, allowed);
    }

    /// @notice Configures a minter allocation immediately. Governance delay is provided by the DAO.
    function setMinterAllocation(address minter, uint256 initialCap, uint256 additionalBps)
        external
        onlyOwner
    {
        if (!isMinter[minter]) revert UnauthorizedMinter();
        bool establishOriginal = !originalMinterAllocationConfigured[minter];
        _applyMinterAllocation(minter, initialCap, additionalBps, establishOriginal);
    }

    function minimumMinterAllocation(address minter)
        public
        view
        returns (uint256 minimumInitialCap, uint256 minimumAdditionalBps)
    {
        if (!originalMinterAllocationConfigured[minter]) return (0, 0);
        MinterAllocation memory original = originalMinterAllocation[minter];
        minimumInitialCap = _minimumAllocationComponent(original.initialCap);
        minimumAdditionalBps = _minimumAllocationComponent(original.additionalBps);
    }

    function _minimumAllocationComponent(uint256 originalAmount) internal pure returns (uint256) {
        if (originalAmount == 0) return 0;
        return (originalAmount * MIN_ALLOCATION_BPS + BPS - 1) / BPS;
    }

    function _validateMinterAllocation(address minter, uint256 initialCap, uint256 additionalBps)
        internal
        pure
    {
        if (minter == address(0)) revert ZeroAddress();
        if (initialCap > INITIAL_UNLOCK || additionalBps > BPS) revert InvalidMinterAllocation();
    }

    function _validatePostSetupMinterAllocation(
        address minter,
        uint256 initialCap,
        uint256 additionalBps
    ) internal view {
        if (!originalMinterAllocationConfigured[minter]) {
            revert OriginalMinterAllocationNotConfigured();
        }
        MinterAllocation memory original = originalMinterAllocation[minter];
        (uint256 minimumInitialCap, uint256 minimumAdditionalBps) = minimumMinterAllocation(minter);
        if (
            initialCap < minimumInitialCap || initialCap > original.initialCap
                || additionalBps < minimumAdditionalBps
                || additionalBps > original.additionalBps
        ) {
            revert MinterAllocationOutsidePermittedRange(
                initialCap,
                minimumInitialCap,
                original.initialCap,
                additionalBps,
                minimumAdditionalBps,
                original.additionalBps
            );
        }
    }

    function _validateMinterAllocationUsage(
        address minter,
        uint256 initialCap,
        uint256 additionalBps
    ) internal view {
        uint256 used = mintedByMinter[minter] + reservedByMinter[minter];
        uint256 proposedAllowance = initialCap
            + additionalUnlockedSupplyAt(block.timestamp) * additionalBps / BPS;
        if (used > proposedAllowance) {
            revert MinterAllocationBelowUsage(used, proposedAllowance);
        }
    }

    function _applyMinterAllocation(
        address minter,
        uint256 initialCap,
        uint256 additionalBps,
        bool updateOriginal
    ) internal {
        _validateMinterAllocation(minter, initialCap, additionalBps);
        if (!updateOriginal) {
            _validatePostSetupMinterAllocation(minter, initialCap, additionalBps);
        }
        _validateMinterAllocationUsage(minter, initialCap, additionalBps);

        MinterAllocation memory old = minterAllocation[minter];
        uint256 newTotalInitial = totalInitialMinterCaps - old.initialCap + initialCap;
        uint256 newTotalBps = totalAdditionalMinterBps - old.additionalBps + additionalBps;
        if (newTotalInitial > INITIAL_UNLOCK || newTotalBps > BPS) {
            revert MinterAllocationTotalsExceeded();
        }

        if (initialCap > type(uint128).max || additionalBps > type(uint16).max) revert ValueTooLarge();
        totalInitialMinterCaps = newTotalInitial;
        totalAdditionalMinterBps = newTotalBps;
        MinterAllocation memory allocation = MinterAllocation(uint128(initialCap), uint16(additionalBps));
        minterAllocation[minter] = allocation;
        if (updateOriginal) {
            originalMinterAllocation[minter] = allocation;
            originalMinterAllocationConfigured[minter] = true;
            emit OriginalMinterAllocationSet(minter, initialCap, additionalBps);
        }
        emit MinterAllocationSet(minter, initialCap, additionalBps);
    }

    /// @notice Authorized staking contracts mint from currently unlocked, unreserved, per-minter capacity.
    /// Owner minting is immediate only during deployment setup.
    function mint(address receiver, uint256 amount) external {
        if (receiver == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        if (msg.sender == owner()) {
            if (block.timestamp >= timelocksActiveAt) revert OwnerMintRequiresTimelock();
            _mintUnreserved(msg.sender, receiver, amount, false);
        } else {
            if (!isMinter[msg.sender]) revert UnauthorizedMinter();
            _mintUnreserved(msg.sender, receiver, amount, true);
        }
    }

    function reserveMint(uint256 amount, uint256 executableAt) external returns (uint256 id) {
        if (!isMinter[msg.sender]) revert UnauthorizedMinter();
        id = _reserveExact(msg.sender, amount, executableAt, true);
    }

    /// @notice Adds as much of `requested` as presently reservable to one reusable reservation.
    /// Used by continuous emissions so obligations are never recorded beyond live capacity.
    function increaseMintReservationUpTo(uint256 id, uint256 requested, uint256 executableAt)
        external
        returns (uint256 resultingId, uint256 amountAdded)
    {
        if (!isMinter[msg.sender]) return (id, 0);
        if (requested == 0) return (id, 0);

        uint256 effectiveAt = executableAt > block.timestamp ? executableAt : block.timestamp;
        if (id != 0) {
            MintReservation storage existing = mintReservations[id];
            if (!existing.open || existing.minter != msg.sender) revert InvalidMintReservation();
            // Continuous-emission reservations represent rewards already settled to users.
            // Protect those historical liabilities while future emission policy remains controlled
            // independently by the staking contract's governanceEmissionRate.
            protectedMintReservation[id] = true;
        }
        // Reservations may only consume capacity that is already unlocked when approved.
        // `effectiveAt` controls execution timing, not future-capacity borrowing.
        uint256 available = _availableForAt(msg.sender, block.timestamp, true);
        amountAdded = requested > available ? available : requested;
        if (amountAdded == 0) return (id, 0);

        if (id == 0) {
            resultingId = _createReservation(msg.sender, amountAdded, effectiveAt, true);
            protectedMintReservation[resultingId] = true;
        } else {
            MintReservation storage reservation = mintReservations[id];
            uint256 newAmount = uint256(reservation.amount) + amountAdded;
            if (newAmount > type(uint128).max) revert ValueTooLarge();
            reservation.amount = uint128(newAmount);
            if (effectiveAt > reservation.executableAt) reservation.executableAt = uint64(effectiveAt);
            totalReservedMint += amountAdded;
            reservedByMinter[msg.sender] += amountAdded;
            resultingId = id;
            emit MintReservationIncreased(id, amountAdded, newAmount);
        }
    }

    /// @notice Atomically replaces one caller-owned reservation with an exact new amount.
    /// @dev If the replacement cannot be reserved, the complete transaction reverts and the old
    /// reservation remains intact. Passing zero releases the reservation without creating a new one.
    function replaceMintReservation(uint256 id, uint256 newAmount, uint256 executableAt)
        external
        returns (uint256 newId)
    {
        if (!isMinter[msg.sender]) revert UnauthorizedMinter();
        if (id != 0) {
            MintReservation storage reservation = mintReservations[id];
            if (!reservation.open || reservation.minter != msg.sender || !reservation.quotaControlled) {
                revert InvalidMintReservation();
            }
            _cancelReservationInternal(id);
        }
        if (newAmount != 0) {
            uint256 effectiveAt = executableAt > block.timestamp ? executableAt : block.timestamp;
            newId = _reserveExact(msg.sender, newAmount, effectiveAt, true);
            protectedMintReservation[newId] = true;
        }
    }

    function mintReserved(uint256 id, address receiver, uint256 amount) external {
        MintReservation storage reservation = mintReservations[id];
        if (!reservation.quotaControlled) revert InvalidMintReservation();
        _consumeReservation(id, msg.sender, receiver, amount);
    }

    /// @notice Consumes the complete due installment and then attempts to reserve the next one.
    /// Returns zero rather than reverting when the next installment cannot yet fit.
    function mintReservedAndReserveNext(
        uint256 id,
        address receiver,
        uint256 nextAmount,
        uint256 nextExecutableAt
    ) external returns (uint256 nextId) {
        MintReservation storage reservation = mintReservations[id];
        if (!reservation.quotaControlled || !reservation.open || reservation.minter != msg.sender) {
            revert InvalidMintReservation();
        }
        uint256 amount = reservation.amount;
        _consumeReservation(id, msg.sender, receiver, amount);
        if (nextAmount == 0) return 0;
        nextId = _tryReserveExact(msg.sender, nextAmount, nextExecutableAt, true);
        if (nextId == 0) emit MintReservationUnavailable(msg.sender, nextAmount, nextExecutableAt);
    }

    function cancelMintReservation(uint256 id) external {
        MintReservation storage reservation = mintReservations[id];
        if (protectedMintReservation[id] && msg.sender != reservation.minter) {
            revert InvalidMintReservation();
        }
        if (!reservation.open || (msg.sender != reservation.minter && msg.sender != owner())) {
            revert InvalidMintReservation();
        }
        _cancelReservationInternal(id);
    }

    /// @notice Deprecated compatibility surface. Protected earned obligations are not confiscatable
    /// merely because their minter contract was retired during an upgrade.
    function cancelRemovedMinterReservation(uint256) external onlyOwner {
        revert InvalidMintReservation();
    }

    /// @notice Queues an owner mint after setup; during setup it executes immediately and returns id zero.
    function proposeOwnerMint(address receiver, uint256 amount) external onlyOwner returns (uint256 id) {
        if (receiver == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (amount > type(uint128).max) revert ValueTooLarge();

        if (block.timestamp < timelocksActiveAt) {
            _mintUnreserved(msg.sender, receiver, amount, false);
            emit OwnerMintExecuted(0, receiver, amount);
            return 0;
        }

        id = nextOwnerMintRequestId++;
        uint256 readyAt = block.timestamp + OWNER_MINT_DELAY;
        uint256 reservationId = _reserveExact(msg.sender, amount, readyAt, false);
        ownerMintRequests[id] = OwnerMintRequest(
            receiver, uint128(amount), uint64(readyAt), reservationId, false, false
        );
        emit OwnerMintQueued(id, receiver, amount, readyAt, reservationId);
    }

    function executeOwnerMint(uint256 id) external {
        OwnerMintRequest storage request = ownerMintRequests[id];
        if (request.receiver == address(0) || request.completed || request.cancelled) {
            revert InvalidOwnerMintRequest();
        }
        if (block.timestamp < request.readyAt) revert TimelockNotReady();
        request.completed = true;
        _consumeReservation(
            request.reservationId,
            mintReservations[request.reservationId].minter,
            request.receiver,
            request.amount
        );
        emit OwnerMintExecuted(id, request.receiver, request.amount);
    }

    function cancelOwnerMint(uint256 id) external onlyOwner {
        OwnerMintRequest storage request = ownerMintRequests[id];
        if (request.receiver == address(0) || request.completed || request.cancelled) {
            revert InvalidOwnerMintRequest();
        }
        request.cancelled = true;
        _cancelReservationInternal(request.reservationId);
        emit OwnerMintCancelled(id, request.receiver, request.amount);
    }

    function _mintUnreserved(address minter, address receiver, uint256 amount, bool enforceAllocation)
        internal
    {
        uint256 globalAvailable = _globalAvailableAt(block.timestamp);
        if (amount > globalAvailable) revert MintExceedsUnlockedSupply(amount, globalAvailable);
        if (enforceAllocation) {
            uint256 minterAvailable = _minterAvailableAt(minter, block.timestamp);
            if (amount > minterAvailable) {
                revert MintExceedsMinterAllocation(amount, minterAvailable);
            }
            mintedByMinter[minter] += amount;
        }
        _mint(receiver, amount);
    }

    function _reserveExact(address minter, uint256 amount, uint256 executableAt, bool enforceAllocation)
        internal
        returns (uint256 id)
    {
        if (amount == 0) revert ZeroAmount();
        uint256 effectiveAt = executableAt > block.timestamp ? executableAt : block.timestamp;
        // Approval reserves only live, currently unlocked capacity. A future execution date
        // cannot borrow from a later monthly unlock.
        uint256 globalAvailable = _globalAvailableAt(block.timestamp);
        if (amount > globalAvailable) revert MintExceedsUnlockedSupply(amount, globalAvailable);
        if (enforceAllocation) {
            uint256 minterAvailable = _minterAvailableAt(minter, block.timestamp);
            if (amount > minterAvailable) {
                revert MintExceedsMinterAllocation(amount, minterAvailable);
            }
        }
        id = _createReservation(minter, amount, effectiveAt, enforceAllocation);
    }

    function _tryReserveExact(
        address minter,
        uint256 amount,
        uint256 executableAt,
        bool enforceAllocation
    ) internal returns (uint256 id) {
        if (amount == 0 || amount > type(uint128).max) return 0;
        uint256 effectiveAt = executableAt > block.timestamp ? executableAt : block.timestamp;
        if (amount > _globalAvailableAt(block.timestamp)) return 0;
        if (enforceAllocation && amount > _minterAvailableAt(minter, block.timestamp)) return 0;
        id = _createReservation(minter, amount, effectiveAt, enforceAllocation);
    }

    function _createReservation(
        address minter,
        uint256 amount,
        uint256 executableAt,
        bool quotaControlled
    ) internal returns (uint256 id) {
        if (amount > type(uint128).max || executableAt > type(uint64).max) revert ValueTooLarge();
        id = nextMintReservationId++;
        mintReservations[id] = MintReservation(minter, uint128(amount), uint64(executableAt), quotaControlled, true);
        totalReservedMint += amount;
        reservedByMinter[minter] += amount;
        emit MintReserved(id, minter, amount, executableAt);
    }

    function _consumeReservation(uint256 id, address expectedMinter, address receiver, uint256 amount)
        internal
    {
        if (receiver == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        MintReservation storage reservation = mintReservations[id];
        if (!reservation.open || reservation.minter != expectedMinter) revert InvalidMintReservation();
        bool retiredProtected = reservation.quotaControlled
            && !isMinter[reservation.minter]
            && protectedMintReservation[id];
        if (reservation.quotaControlled && !isMinter[reservation.minter] && !retiredProtected) {
            revert UnauthorizedMinter();
        }
        if (block.timestamp < reservation.executableAt) revert MintReservationNotReady();
        if (amount > reservation.amount) revert MintReservationInsufficient();

        // Reconfirm the complete cross-contract reservation ledger at execution. Unlocks are
        // monotonic, but this makes the global and per-minter invariants explicit on every mint.
        uint256 unlocked = unlockedSupplyAt(block.timestamp);
        uint256 commitments = totalSupply() + totalReservedMint;
        if (commitments > unlocked) {
            revert MintExceedsUnlockedSupply(amount, unlocked > totalSupply() ? unlocked - totalSupply() : 0);
        }
        if (reservation.quotaControlled && !retiredProtected) {
            uint256 allowance = minterMintAllowanceAt(reservation.minter, block.timestamp);
            uint256 minterCommitments = mintedByMinter[reservation.minter]
                + reservedByMinter[reservation.minter];
            if (minterCommitments > allowance) {
                revert MintExceedsMinterAllocation(
                    amount,
                    allowance > mintedByMinter[reservation.minter]
                        ? allowance - mintedByMinter[reservation.minter]
                        : 0
                );
            }
        }

        reservation.amount = uint128(uint256(reservation.amount) - amount);
        totalReservedMint -= amount;
        reservedByMinter[reservation.minter] -= amount;
        if (reservation.quotaControlled) mintedByMinter[reservation.minter] += amount;
        _mint(receiver, amount);
        emit MintReservationConsumed(id, reservation.minter, receiver, amount);
    }

    function _cancelReservationInternal(uint256 id) internal {
        MintReservation storage reservation = mintReservations[id];
        if (!reservation.open) revert InvalidMintReservation();
        uint256 amount = reservation.amount;
        reservation.amount = 0;
        reservation.open = false;
        delete protectedMintReservation[id];
        totalReservedMint -= amount;
        reservedByMinter[reservation.minter] -= amount;
        emit MintReservationCancelled(id, reservation.minter, amount);
    }

    function _globalAvailableAt(uint256 timestamp) internal view returns (uint256) {
        uint256 commitments = totalSupply() + totalReservedMint;
        uint256 unlocked = unlockedSupplyAt(timestamp);
        return unlocked > commitments ? unlocked - commitments : 0;
    }

    function _minterAvailableAt(address minter, uint256 timestamp) internal view returns (uint256) {
        uint256 used = mintedByMinter[minter] + reservedByMinter[minter];
        uint256 allowance = minterMintAllowanceAt(minter, timestamp);
        return allowance > used ? allowance - used : 0;
    }

    function _availableForAt(address minter, uint256 timestamp, bool enforceAllocation)
        internal
        view
        returns (uint256)
    {
        uint256 globalAvailable = _globalAvailableAt(timestamp);
        if (!enforceAllocation) return globalAvailable;
        uint256 minterAvailable = _minterAvailableAt(minter, timestamp);
        return globalAvailable < minterAvailable ? globalAvailable : minterAvailable;
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Capped) {
        if (from != address(0) && to != address(0)) {
            if (!transferWhitelist[from] && !transferWhitelist[to]) {
                revert TransferNotAllowed(from, to);
            }
        }
        super._update(from, to, value);
    }
}
