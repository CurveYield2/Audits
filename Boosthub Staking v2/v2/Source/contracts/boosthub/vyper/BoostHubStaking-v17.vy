# pragma version 0.4.3
"""
@title BoostHub Staking v16
@author Curve Finance, modified for CurveYield
@license UNLICENSED
@notice Simplified Curve ChildGauge-derived staking contract for CurveYield BoostHub pools.
@dev Keeps the Curve reward-integral model, strips the receipt-token and all Curve veCRV boost logic,
     forwards deposited want to BoostHub, supports two mutually-exclusive deposit modes,
     uses the proven 8-hour fractional Method-1 activation index, and keeps only the
     configuration surfaces still used by this reduced design.
"""

from ethereum.ercs import IERC20

interface BoostHub:
    def isRewardToken(pid: uint256, rewardToken: address) -> bool: view

struct WithdrawalRequest:
    owner: address
    amount: uint256
    fee_liability: uint256
    unlock_time: uint256
    active: bool

# ----------------------------- Events -----------------------------

event Deposit:
    provider: indexed(address)
    value: uint256
    mode: uint256

event Withdraw:
    provider: indexed(address)
    value: uint256
    fee: uint256

event WithdrawalRequested:
    provider: indexed(address)
    request_id: uint256
    value: uint256
    unlock_time: uint256

event WithdrawalCompleted:
    provider: indexed(address)
    request_id: uint256
    value: uint256
    fee: uint256

event AddReward:
    reward_token: indexed(address)

event DisableReward:
    reward_token: indexed(address)

event ExternalRewardFunded:
    reward_token: indexed(address)
    funder: indexed(address)
    gross_amount: uint256
    distributable_amount: uint256

event Harvest:
    reward_token: indexed(address)
    gross_amount: uint256
    distributable_amount: uint256

event DepositModeChanged:
    account: indexed(address)
    mode: uint256

event SetPerformanceFee:
    fee_bps: uint256

event SetPerformanceFeeReceiver:
    receiver: address

event SetPerformanceFeeStaked:
    enabled: bool

event SetYieldBoostFee:
    fee_bps: uint256

event SetRewardConverter:
    reward_token: indexed(address)
    converter: address

event SetWithdrawFee:
    fee_bps: uint256

event SetRewardSmoothing:
    smoothing_units: uint256

event SetActivationDuration:
    activation_units: uint256

event CommitOwnership:
    pending_admin: address

event ApplyOwnership:
    admin: address

event CommitKeeperTransfer:
    pending_keeper: address

event AcceptKeeperTransfer:
    keeper: address

event BoostHubDonation:
    amount: uint256
    keeper_attribution: uint256

# ----------------------------- Constants -----------------------------

MAX_REWARDS: constant(uint256) = 8
FEE_DENOMINATOR: constant(uint256) = 10000
MAX_WITHDRAW_FEE_BPS: constant(uint256) = 250
MAX_PERFORMANCE_FEE_BPS: constant(uint256) = 1000
MAX_YIELD_BOOST_FEE_BPS: constant(uint256) = 500
MAX_FEE_CONVERSION_SLIPPAGE_BPS: constant(uint256) = 400
INACTIVE_DONATION_BPS: constant(uint256) = 4000
KEEPER_ATTRIBUTION_BPS: constant(uint256) = 2500


REWARD_TIME_UNIT: constant(uint256) = 8640  # 10 units = 1 day
MAX_REWARD_SMOOTHING_UNITS: constant(uint256) = 300  # 30 days
MAX_ACTIVATION_DURATION_UNITS: constant(uint256) = 600  # 60 days
ACTIVATION_STEP_SECONDS: constant(uint256) = 8 * 3600
ACTIVATION_INDEX_SCALE: constant(uint256) = 10**18
ACTIVATION_INDEX_REBASE_THRESHOLD: constant(uint256) = 10**24
ACTIVATION_INDEX_REBASE_FACTOR: constant(uint256) = 10**6
MAX_INACTIVE_GENERATION_STEPS: constant(uint256) = 14
MAX_REWARD_BOUNDARY_STEPS: constant(uint256) = 96
MAX_EXTRA_ACTIVATION_STEPS: constant(uint256) = 184
ACTIVATION_CURVE_CONSTANT: constant(uint256) = 5

DEPOSIT_MODE_NONE: constant(uint256) = 0
DEPOSIT_MODE_METHOD1: constant(uint256) = 1
DEPOSIT_MODE_METHOD2: constant(uint256) = 2

# ----------------------------- Core storage -----------------------------

lp_token: public(address)
governance_token: public(address)
boost_hub: public(address)
pid: public(uint256)
staked_balance: public(HashMap[address, uint256])
total_staked: public(uint256)
approved_to_deposit: public(HashMap[address, HashMap[address, bool]])

admin: public(address)
future_admin: public(address)

keeper: public(address)
pending_keeper: public(address)
keeper_attributed_balance: uint256

withdrawal_delay: public(uint256)

# ----------------------------- Deposit modes -----------------------------

deposit_mode: public(HashMap[address, uint256])

# Method 1: repeated deposits represented by one aggregate inactive-share position.
inactive_shares: public(HashMap[address, uint256])
inactive_generation_for: public(HashMap[address, uint256])
total_inactive_balance: public(uint256)
activation_index: public(uint256)
activation_generation: public(uint256)
last_activation_boundary: public(uint256)
activation_reward_q: uint256
activation_reward_q_final: HashMap[uint256, uint256]
activation_reward_q_for: HashMap[address, uint256]

# Method 2: fee liability is grandfathered when deposits enter Method 2.
withdraw_fee_liability: public(HashMap[address, uint256])
queued_balance: public(HashMap[address, uint256])
total_queued_balance: public(uint256)
withdrawal_requests: public(HashMap[uint256, WithdrawalRequest])
next_withdrawal_request_id: public(uint256)

# ----------------------------- Reward accounting -----------------------------

reward_tokens: public(address[MAX_REWARDS])
reward_count: public(uint256)
reward_disabled: public(HashMap[address, bool])
# True when this reward is harvested/claimed from BoostHub; false when funded directly.
reward_from_boosthub: public(HashMap[address, bool])

reward_integral: public(HashMap[address, uint256])
reward_integral_for: public(HashMap[address, HashMap[address, uint256]])
reward_rate: public(HashMap[address, uint256])
reward_period_finish: public(HashMap[address, uint256])
reward_last_update: public(HashMap[address, uint256])
reward_remaining: public(HashMap[address, uint256])
claim_data: HashMap[address, HashMap[address, uint256]]

# 60% of foregone want waits here if there is temporarily no active want weight.
active_want_redistribution_buffer: public(uint256)
# 40% inactive want + withdrawal tax + yield-token fee wait here for explicit harvest donation.
pending_boosthub_donation_want: public(uint256)

# ----------------------------- Configurable economics -----------------------------

withdraw_fee_bps: public(uint256)

performance_fee_bps: public(uint256)
performance_fee_receiver: public(address)
performance_fee_staked: public(bool)

yield_boost_fee_bps: public(uint256)
fee_conversion_slippage_bps: uint256

# Converter is used for yield-token-fee conversion and optional staked performance-fee conversion.
reward_converter: public(HashMap[address, address])

reward_smoothing_units: public(uint256)

activation_duration_units: public(uint256)
activation_remaining_factor: public(uint256)

# ----------------------------- Constructor -----------------------------

@deploy
def __init__(
    _lp_token: address,
    _governance_token: address,
    _boost_hub: address,
    _pid: uint256,
    _admin: address,
    _reward_tokens: address[MAX_REWARDS],
    _reward_converters: address[MAX_REWARDS],
    _withdraw_fee_bps: uint256,
    _performance_fee_bps: uint256,
    _performance_fee_receiver: address,
    _yield_boost_fee_bps: uint256,
    _reward_smoothing_units: uint256,
    _activation_duration_units: uint256,
    _keeper: address,
):
    assert _lp_token != empty(address)
    assert _governance_token != empty(address)
    assert _boost_hub != empty(address)
    assert _admin != empty(address)
    assert _performance_fee_receiver != empty(address)
    assert _keeper != empty(address)
    assert _withdraw_fee_bps <= MAX_WITHDRAW_FEE_BPS
    assert _performance_fee_bps <= MAX_PERFORMANCE_FEE_BPS
    assert _yield_boost_fee_bps <= MAX_YIELD_BOOST_FEE_BPS
    assert _reward_smoothing_units <= MAX_REWARD_SMOOTHING_UNITS
    assert _activation_duration_units <= MAX_ACTIVATION_DURATION_UNITS

    self.lp_token = _lp_token
    self.governance_token = _governance_token
    self.boost_hub = _boost_hub
    self.pid = _pid
    self.admin = _admin
    self.keeper = _keeper
    self.withdrawal_delay = 30 * 86400

    self.withdraw_fee_bps = _withdraw_fee_bps
    self.performance_fee_bps = _performance_fee_bps
    self.performance_fee_receiver = _performance_fee_receiver
    self.yield_boost_fee_bps = _yield_boost_fee_bps
    self.fee_conversion_slippage_bps = 100
    self.reward_smoothing_units = _reward_smoothing_units
    self.activation_duration_units = _activation_duration_units
    self.activation_remaining_factor = self._remaining_factor_for_units(_activation_duration_units)
    self.activation_index = ACTIVATION_INDEX_SCALE
    self.last_activation_boundary = block.timestamp // ACTIVATION_STEP_SECONDS * ACTIVATION_STEP_SECONDS
    self.next_withdrawal_request_id = 1

    # Want is always internal reward-accounting token 0, but it does not need to be a BoostHub reward.
    self.reward_tokens[0] = _lp_token
    self.reward_from_boosthub[_lp_token] = staticcall BoostHub(_boost_hub).isRewardToken(_pid, _lp_token)
    log AddReward(_lp_token)

    encountered_empty: bool = False
    count: uint256 = 1
    for i: uint256 in range(MAX_REWARDS):
        token: address = _reward_tokens[i]
        if token == empty(address):
            encountered_empty = True
            assert _reward_converters[i] == empty(address), "converter for empty slot"
        else:
            assert not encountered_empty, "reward slots must be packed"
            assert token != self and token != _lp_token
            assert count < MAX_REWARDS, "too many rewards"
            assert staticcall BoostHub(_boost_hub).isRewardToken(_pid, token)
            for j: uint256 in range(MAX_REWARDS):
                if j < i:
                    assert token != _reward_tokens[j], "duplicate reward"
            self.reward_tokens[count] = token
            self.reward_from_boosthub[token] = True
            converter: address = _reward_converters[i]
            assert converter != empty(address), "converter required"
            self.reward_converter[token] = converter
            log SetRewardConverter(token, converter)
            count += 1
            log AddReward(token)
    self.reward_count = count

    # BoostHub.deposit() and donateYieldBoostingTokens() both pull want from this contract.
    extcall IERC20(_lp_token).approve(_boost_hub, max_value(uint256))

    log SetWithdrawFee(_withdraw_fee_bps)
    log SetPerformanceFee(_performance_fee_bps)
    log SetPerformanceFeeReceiver(_performance_fee_receiver)
    log SetYieldBoostFee(_yield_boost_fee_bps)
    log SetRewardSmoothing(_reward_smoothing_units)
    log SetActivationDuration(_activation_duration_units)

# ----------------------------- Basic views/helpers -----------------------------

@view
@external
def balanceOf(_addr: address) -> uint256:
    """Internal staked principal getter; this contract does not issue an ERC20 receipt token."""
    return self.staked_balance[_addr]

@internal
@view
def _is_reward_token(_token: address) -> bool:
    for i: uint256 in range(MAX_REWARDS):
        if i >= self.reward_count:
            break
        if self.reward_tokens[i] == _token:
            return True
    return False

@internal
@view
def _mul_ratio_down(_a: uint256, _numerator: uint256, _denominator: uint256) -> uint256:
    if _a == 0 or _numerator == 0:
        return 0
    return _a * _numerator // _denominator

@internal
@view
def _mul_scale_down(_a: uint256, _b: uint256) -> uint256:
    whole_b: uint256 = _b // ACTIVATION_INDEX_SCALE
    rem_b: uint256 = _b % ACTIVATION_INDEX_SCALE
    result: uint256 = 0
    if whole_b != 0:
        assert _a <= max_value(uint256) // whole_b
        result = _a * whole_b
    whole_a: uint256 = _a // ACTIVATION_INDEX_SCALE
    rem_a: uint256 = _a % ACTIVATION_INDEX_SCALE
    fractional: uint256 = whole_a * rem_b + rem_a * rem_b // ACTIVATION_INDEX_SCALE
    assert result <= max_value(uint256) - fractional
    return result + fractional

@internal
@view
def _activation_periods_for_units(_units: uint256) -> uint256:
    if _units == 0:
        return 0
    return (_units * 3 + 9) // 10

@internal
@view
def _remaining_factor_for_units(_units: uint256) -> uint256:
    periods: uint256 = self._activation_periods_for_units(_units)
    if periods == 0:
        return 0
    return periods * ACTIVATION_INDEX_SCALE // (periods + ACTIVATION_CURVE_CONSTANT)

@internal
@view
def _inactive_from_shares_at_index(_shares: uint256, _index: uint256) -> uint256:
    if _shares == 0:
        return 0
    return self._mul_ratio_down(_shares, ACTIVATION_INDEX_SCALE, _index)

@internal
@view
def _shares_for_inactive_at_index(_amount: uint256, _index: uint256) -> uint256:
    if _amount == 0:
        return 0
    shares: uint256 = self._mul_scale_down(_amount, _index)
    if self._inactive_from_shares_at_index(shares, _index) < _amount:
        shares += 1
    return shares

@internal
@view
def _current_user_shares(_addr: address) -> uint256:
    shares: uint256 = self.inactive_shares[_addr]
    generation: uint256 = self.inactive_generation_for[_addr]
    current_generation: uint256 = self.activation_generation
    for j: uint256 in range(MAX_INACTIVE_GENERATION_STEPS):
        if shares == 0 or generation >= current_generation:
            break
        shares //= ACTIVATION_INDEX_REBASE_FACTOR
        generation += 1
    assert shares == 0 or generation == current_generation, "inactive generation overflow"
    return shares

@internal
@view
def _current_user_inactive(_addr: address) -> uint256:
    if self.deposit_mode[_addr] != DEPOSIT_MODE_METHOD1:
        return 0
    amount: uint256 = self._inactive_from_shares_at_index(self._current_user_shares(_addr), self.activation_index)
    if amount > self.staked_balance[_addr]:
        return self.staked_balance[_addr]
    return amount

@view
@external
def inactive_balance(_addr: address) -> uint256:
    return self._current_user_inactive(_addr)

@view
@external
def active_balance(_addr: address) -> uint256:
    bal: uint256 = self.staked_balance[_addr]
    mode: uint256 = self.deposit_mode[_addr]
    if mode == DEPOSIT_MODE_METHOD1:
        inactive: uint256 = self._current_user_inactive(_addr)
        return bal - inactive
    if mode == DEPOSIT_MODE_METHOD2:
        queued: uint256 = self.queued_balance[_addr]
        return bal - min(bal, queued)
    return 0

@internal
@view
def _total_reward_weight() -> uint256:
    return self.total_staked + self.keeper_attributed_balance

@internal
@view
def _total_want_inactive() -> uint256:
    inactive: uint256 = self.total_inactive_balance + self.total_queued_balance
    if inactive > self.total_staked:
        return self.total_staked
    return inactive

# ----------------------------- Activation index -----------------------------

@internal
def _finalize_activation_generation():
    generation: uint256 = self.activation_generation
    self.activation_reward_q_final[generation] = self.activation_reward_q
    self.activation_reward_q = 0
    self.activation_index //= ACTIVATION_INDEX_REBASE_FACTOR
    self.activation_generation = generation + 1

@internal
def _force_global_activation():
    if self.total_inactive_balance == 0:
        return
    generation: uint256 = self.activation_generation
    self.activation_reward_q_final[generation] = self.activation_reward_q
    self.activation_reward_q = 0
    self.activation_generation = generation + MAX_INACTIVE_GENERATION_STEPS
    self.activation_index = ACTIVATION_INDEX_SCALE
    self.total_inactive_balance = 0

@internal
def _apply_activation_step():
    inactive: uint256 = self.total_inactive_balance
    if inactive == 0:
        return
    factor: uint256 = self.activation_remaining_factor
    if factor == 0:
        self._force_global_activation()
        return
    self.total_inactive_balance = self._mul_ratio_down(inactive, factor, ACTIVATION_INDEX_SCALE)
    self.activation_index = self.activation_index * ACTIVATION_INDEX_SCALE // factor
    if self.activation_index >= ACTIVATION_INDEX_REBASE_THRESHOLD:
        self._finalize_activation_generation()

@internal
@view
def _inactive_reward_penalty(_addr: address) -> uint256:
    shares: uint256 = self.inactive_shares[_addr]
    if shares == 0:
        return 0
    generation: uint256 = self.inactive_generation_for[_addr]
    current_generation: uint256 = self.activation_generation
    q_start: uint256 = self.activation_reward_q_for[_addr]
    penalty: uint256 = 0
    for j: uint256 in range(MAX_INACTIVE_GENERATION_STEPS):
        if shares == 0:
            break
        q_end: uint256 = 0
        if generation == current_generation:
            q_end = self.activation_reward_q
        else:
            assert generation < current_generation, "future inactive generation"
            q_end = self.activation_reward_q_final[generation]
        if q_end > q_start:
            add: uint256 = self._mul_scale_down(shares, q_end - q_start)
            if add != max_value(uint256):
                add += 1
            penalty += add
        if generation == current_generation:
            break
        shares //= ACTIVATION_INDEX_REBASE_FACTOR
        generation += 1
        q_start = 0
    assert shares == 0 or generation == current_generation, "inactive penalty overflow"
    return penalty

# ----------------------------- Reward integral accounting -----------------------------

@internal
def _flush_active_want_buffer():
    buffered: uint256 = self.active_want_redistribution_buffer
    if buffered == 0:
        return
    supply: uint256 = self._total_reward_weight()
    if supply == 0:
        return
    inactive: uint256 = self._total_want_inactive()
    active_supply: uint256 = supply - inactive
    if active_supply == 0:
        return
    self.active_want_redistribution_buffer = 0
    integral_add: uint256 = buffered * 10**18 // active_supply
    self.reward_integral[self.lp_token] += integral_add
    if self.total_inactive_balance != 0 and integral_add != 0:
        self.activation_reward_q += self._mul_ratio_down(integral_add, ACTIVATION_INDEX_SCALE, self.activation_index)

@internal
def _update_reward_integral_to(_token: address, _timestamp: uint256):
    finish: uint256 = self.reward_period_finish[_token]
    applicable: uint256 = min(_timestamp, finish)
    last: uint256 = self.reward_last_update[_token]
    if applicable <= last:
        return

    elapsed: uint256 = applicable - last
    supply: uint256 = self._total_reward_weight()
    if supply != 0:
        emission: uint256 = elapsed * self.reward_rate[_token]
        if applicable == finish:
            emission = self.reward_remaining[_token]
        elif emission > self.reward_remaining[_token]:
            emission = self.reward_remaining[_token]

        if emission != 0:
            self.reward_remaining[_token] -= emission
            if _token == self.lp_token:
                inactive: uint256 = self._total_want_inactive()
                active_supply: uint256 = supply - inactive
                inactive_nominal: uint256 = 0
                if inactive != 0:
                    inactive_nominal = self._mul_ratio_down(emission, inactive, supply)
                donation: uint256 = inactive_nominal * INACTIVE_DONATION_BPS // FEE_DENOMINATOR
                if donation != 0:
                    self.pending_boosthub_donation_want += donation
                active_amount: uint256 = emission - donation
                if active_supply != 0:
                    integral_add: uint256 = active_amount * 10**18 // active_supply
                    self.reward_integral[_token] += integral_add
                    if self.total_inactive_balance != 0 and integral_add != 0:
                        self.activation_reward_q += self._mul_ratio_down(
                            integral_add, ACTIVATION_INDEX_SCALE, self.activation_index
                        )
                elif active_amount != 0:
                    self.active_want_redistribution_buffer += active_amount
            else:
                self.reward_integral[_token] += emission * 10**18 // supply

    self.reward_last_update[_token] = applicable

@internal
def _update_nonwant_rewards_to(_timestamp: uint256):
    for i: uint256 in range(MAX_REWARDS):
        if i >= self.reward_count:
            break
        token: address = self.reward_tokens[i]
        if token != self.lp_token:
            self._update_reward_integral_to(token, _timestamp)

@internal
def _update_all_reward_integrals():
    # Non-want eligibility is independent of activation and queued withdrawal state.
    self._update_nonwant_rewards_to(block.timestamp)

    current_boundary: uint256 = block.timestamp // ACTIVATION_STEP_SECONDS * ACTIVATION_STEP_SECONDS
    if self.total_inactive_balance == 0:
        self._update_reward_integral_to(self.lp_token, block.timestamp)
        self._flush_active_want_buffer()
        self.last_activation_boundary = current_boundary
        return

    next_boundary: uint256 = self.last_activation_boundary + ACTIVATION_STEP_SECONDS
    want_finish: uint256 = self.reward_period_finish[self.lp_token]
    horizon_boundary: uint256 = current_boundary
    if want_finish < block.timestamp:
        horizon_boundary = want_finish // ACTIVATION_STEP_SECONDS * ACTIVATION_STEP_SECONDS
        if want_finish % ACTIVATION_STEP_SECONDS != 0:
            horizon_boundary += ACTIVATION_STEP_SECONDS
        if horizon_boundary > current_boundary:
            horizon_boundary = current_boundary

    for j: uint256 in range(MAX_REWARD_BOUNDARY_STEPS):
        if next_boundary > horizon_boundary or next_boundary > current_boundary:
            break
        self._update_reward_integral_to(self.lp_token, next_boundary)
        self._apply_activation_step()
        self._flush_active_want_buffer()
        self.last_activation_boundary = next_boundary
        next_boundary += ACTIVATION_STEP_SECONDS

    if self.last_activation_boundary < current_boundary:
        remaining_steps: uint256 = (current_boundary - self.last_activation_boundary) // ACTIVATION_STEP_SECONDS
        configured_steps: uint256 = self._activation_periods_for_units(self.activation_duration_units)
        if self.total_inactive_balance != 0 and remaining_steps >= configured_steps + 4:
            self._force_global_activation()
            self.last_activation_boundary = current_boundary
        else:
            for k: uint256 in range(MAX_EXTRA_ACTIVATION_STEPS):
                if k >= remaining_steps:
                    break
                self._apply_activation_step()
                self._flush_active_want_buffer()
                self.last_activation_boundary += ACTIVATION_STEP_SECONDS

    self._update_reward_integral_to(self.lp_token, block.timestamp)
    self._flush_active_want_buffer()

@internal
def _checkpoint_user_current(_addr: address, _claim: bool):
    mode: uint256 = self.deposit_mode[_addr]
    bal: uint256 = self.staked_balance[_addr]
    special: uint256 = 0
    if _addr == self.keeper:
        special = self.keeper_attributed_balance

    for i: uint256 in range(MAX_REWARDS):
        if i >= self.reward_count:
            break
        token: address = self.reward_tokens[i]
        integral: uint256 = self.reward_integral[token]
        prior: uint256 = self.reward_integral_for[token][_addr]
        if integral > prior:
            delta: uint256 = integral - prior
            earned: uint256 = 0
            if token == self.lp_token:
                normal: uint256 = 0
                if mode == DEPOSIT_MODE_METHOD1 and bal != 0:
                    normal = self._mul_scale_down(bal, delta)
                    if self.inactive_shares[_addr] != 0:
                        penalty: uint256 = self._inactive_reward_penalty(_addr)
                        if penalty >= normal:
                            normal = 0
                        else:
                            normal -= penalty
                elif mode == DEPOSIT_MODE_METHOD2 and bal != 0:
                    active: uint256 = bal - min(bal, self.queued_balance[_addr])
                    normal = self._mul_scale_down(active, delta)
                earned = normal + self._mul_scale_down(special, delta)
            else:
                earned = self._mul_scale_down(bal + special, delta)
            if earned != 0:
                self.claim_data[_addr][token] += earned

        self.reward_integral_for[token][_addr] = integral
        if token == self.lp_token:
            self.activation_reward_q_for[_addr] = self.activation_reward_q

        if _claim:
            amount: uint256 = self.claim_data[_addr][token]
            if amount != 0:
                self.claim_data[_addr][token] = 0
                extcall IERC20(token).transfer(_addr, amount)

    shares: uint256 = self._current_user_shares(_addr)
    if self.total_inactive_balance == 0:
        shares = 0
    self.inactive_shares[_addr] = shares
    self.inactive_generation_for[_addr] = self.activation_generation

@external
@nonreentrant
def checkpoint(_addr: address):
    """Checkpoint smoothed reward accrual and Method-1 activation without harvesting BoostHub."""
    self._update_all_reward_integrals()
    self._checkpoint_user_current(_addr, False)

@view
@external
def claimable_reward(_addr: address, _token: address) -> uint256:
    # Conservative stored amount. State-changing claim/checkpoint realizes current streamed accrual.
    assert self._is_reward_token(_token), "unknown reward"
    return self.claim_data[_addr][_token]

# ----------------------------- BoostHub writes -----------------------------

@internal
def _forward_deposit_to_boosthub(_value: uint256, _caller: address):
    extcall IERC20(self.lp_token).transferFrom(_caller, self, _value)
    raw_call(
        self.boost_hub,
        concat(method_id("deposit(uint256,uint256)"), convert(self.pid, bytes32), convert(_value, bytes32)),
    )

@internal
def _deposit_held_want_to_boosthub(_value: uint256):
    if _value == 0:
        return
    raw_call(
        self.boost_hub,
        concat(method_id("deposit(uint256,uint256)"), convert(self.pid, bytes32), convert(_value, bytes32)),
    )

@internal
def _credit_method2_stake(_addr: address, _value: uint256):
    """Credit already-held want as immediately-active Method-2 principal; no receipt token is minted."""
    if _value == 0:
        return
    self._checkpoint_user_current(_addr, False)
    mode: uint256 = self.deposit_mode[_addr]
    if mode == DEPOSIT_MODE_METHOD1:
        self._convert_method1_to_method2(_addr, _value)
    else:
        if mode == DEPOSIT_MODE_NONE:
            self._set_user_mode(_addr, DEPOSIT_MODE_METHOD2)
        assert self.deposit_mode[_addr] == DEPOSIT_MODE_METHOD2
        self.withdraw_fee_liability[_addr] += _value * self.withdraw_fee_bps // FEE_DENOMINATOR
    self.total_staked += _value
    self.staked_balance[_addr] += _value
    self._deposit_held_want_to_boosthub(_value)
    log Deposit(_addr, _value, DEPOSIT_MODE_METHOD2)

@internal
def _withdraw_from_boosthub(_value: uint256):
    raw_call(
        self.boost_hub,
        concat(method_id("withdraw(uint256,uint256)"), convert(self.pid, bytes32), convert(_value, bytes32)),
    )

@internal
def _donate_to_boosthub(_amount: uint256):
    if _amount == 0:
        return
    # Reward integrals are current before every donation call. Settle old keeper weight first.
    self._checkpoint_user_current(self.keeper, False)
    raw_call(
        self.boost_hub,
        concat(
            method_id("donateYieldBoostingTokens(uint256,uint256)"),
            convert(self.pid, bytes32),
            convert(_amount, bytes32),
        ),
    )
    attribution: uint256 = _amount * KEEPER_ATTRIBUTION_BPS // FEE_DENOMINATOR
    self.keeper_attributed_balance += attribution
    log BoostHubDonation(_amount, attribution)

@internal
def _process_pending_donation():
    amount: uint256 = self.pending_boosthub_donation_want
    if amount == 0:
        return
    self.pending_boosthub_donation_want = 0
    self._donate_to_boosthub(amount)

# ----------------------------- Reward harvest/smoothing -----------------------------

@internal
def _distribute_immediate(_token: address, _amount: uint256):
    if _amount == 0:
        return
    supply: uint256 = self._total_reward_weight()
    if supply == 0:
        self.reward_remaining[_token] += _amount
        return
    if _token == self.lp_token:
        inactive: uint256 = self._total_want_inactive()
        active_supply: uint256 = supply - inactive
        inactive_nominal: uint256 = 0
        if inactive != 0:
            inactive_nominal = self._mul_ratio_down(_amount, inactive, supply)
        donation: uint256 = inactive_nominal * INACTIVE_DONATION_BPS // FEE_DENOMINATOR
        self.pending_boosthub_donation_want += donation
        active_amount: uint256 = _amount - donation
        if active_supply != 0:
            integral_add: uint256 = active_amount * 10**18 // active_supply
            self.reward_integral[_token] += integral_add
            if self.total_inactive_balance != 0:
                self.activation_reward_q += self._mul_ratio_down(integral_add, ACTIVATION_INDEX_SCALE, self.activation_index)
        else:
            self.active_want_redistribution_buffer += active_amount
    else:
        self.reward_integral[_token] += _amount * 10**18 // supply

@internal
def _schedule_reward(_token: address, _amount: uint256):
    if _amount == 0:
        return
    # Existing stream was checkpointed before harvest, so reward_remaining is the precise carry.
    total_amount: uint256 = _amount + self.reward_remaining[_token]
    duration: uint256 = self.reward_smoothing_units * REWARD_TIME_UNIT
    if duration == 0:
        self.reward_remaining[_token] = 0
        self.reward_rate[_token] = 0
        self.reward_last_update[_token] = block.timestamp
        self.reward_period_finish[_token] = block.timestamp
        self._distribute_immediate(_token, total_amount)
    else:
        self.reward_remaining[_token] = total_amount
        self.reward_rate[_token] = total_amount // duration
        self.reward_last_update[_token] = block.timestamp
        self.reward_period_finish[_token] = block.timestamp + duration

@internal
@view
def _preview_reward_convert(
    _converter: address,
    _token_in: address,
    _amount_in: uint256,
) -> uint256:
    response: Bytes[32] = raw_call(
        _converter,
        concat(
            method_id("previewConvert(address,address,uint256)"),
            convert(_token_in, bytes32),
            convert(self.lp_token, bytes32),
            convert(_amount_in, bytes32),
        ),
        max_outsize=32,
        is_static_call=True,
    )
    assert len(response) == 32, "invalid converter response"
    return convert(response, uint256)

@internal
def _convert_fee_to_want(
    _token: address,
    _amount: uint256,
) -> uint256:
    if _amount == 0:
        return 0
    if _token == self.lp_token:
        return _amount
    converter: address = self.reward_converter[_token]
    assert converter != empty(address), "converter not set"
    extcall IERC20(_token).approve(converter, 0)
    extcall IERC20(_token).approve(converter, _amount)
    quote: uint256 = self._preview_reward_convert(converter, _token, _amount)
    assert quote != 0, "zero quote"
    quote = quote * (FEE_DENOMINATOR - self.fee_conversion_slippage_bps) // FEE_DENOMINATOR
    response: Bytes[32] = raw_call(
        converter,
        concat(
            method_id("convert(address,address,uint256,uint256)"),
            convert(_token, bytes32),
            convert(self.lp_token, bytes32),
            convert(_amount, bytes32),
            convert(quote, bytes32),
        ),
        max_outsize=32,
    )
    extcall IERC20(_token).approve(converter, 0)
    assert len(response) == 32, "invalid converter response"
    want_out: uint256 = convert(response, uint256)
    assert want_out != 0, "zero output"
    return want_out

@external
@nonreentrant
def harvest():
    # Harvest is explicit. Deposits and withdrawals never call it.
    self._update_all_reward_integrals()
    self._process_pending_donation()

    if self._total_reward_weight() == 0:
        return

    raw_call(self.boost_hub, concat(method_id("harvest(uint256)"), convert(self.pid, bytes32)))

    performance_stake_want: uint256 = 0
    for i: uint256 in range(MAX_REWARDS):
        if i >= self.reward_count:
            break
        token: address = self.reward_tokens[i]
        if self.reward_disabled[token]:
            continue
        # Externally-funded rewards (including cyGOV) are streamed by deposit_reward_token()
        # and must never be queried from BoostHub.
        if not self.reward_from_boosthub[token]:
            continue

        before: uint256 = staticcall IERC20(token).balanceOf(self)
        raw_call(
            self.boost_hub,
            concat(
                method_id("claimReward(uint256,address,address)"),
                convert(self.pid, bytes32),
                convert(token, bytes32),
                convert(self, bytes32),
            ),
        )
        gross: uint256 = staticcall IERC20(token).balanceOf(self) - before
        if gross == 0:
            continue

        perf_fee: uint256 = 0
        yield_fee: uint256 = 0
        if token != self.governance_token:
            perf_fee = gross * self.performance_fee_bps // FEE_DENOMINATOR
            if perf_fee != 0:
                if self.performance_fee_staked:
                    performance_stake_want += self._convert_fee_to_want(token, perf_fee)
                else:
                    extcall IERC20(token).transfer(self.performance_fee_receiver, perf_fee)

            yield_fee = gross * self.yield_boost_fee_bps // FEE_DENOMINATOR
            if yield_fee != 0:
                self.pending_boosthub_donation_want += self._convert_fee_to_want(token, yield_fee)

        distributable: uint256 = gross - perf_fee - yield_fee
        self._schedule_reward(token, distributable)
        log Harvest(token, gross, distributable)

    if performance_stake_want != 0:
        self._credit_method2_stake(self.performance_fee_receiver, performance_stake_want)

    # Includes converted yield-token-fee want plus any previously accrued 40% inactive share.
    self._process_pending_donation()

# ----------------------------- Deposit accounting -----------------------------

@internal
def _set_user_mode(_addr: address, _mode: uint256):
    if self.deposit_mode[_addr] != _mode:
        self.deposit_mode[_addr] = _mode
        log DepositModeChanged(_addr, _mode)

@internal
def _check_deposit_authorization(_addr: address, _caller: address):
    assert _addr != empty(address)
    if _addr != _caller:
        assert self.approved_to_deposit[_caller][_addr], "Not approved"

@internal
def _add_method1_deposit(_addr: address, _value: uint256):
    self._set_user_mode(_addr, DEPOSIT_MODE_METHOD1)
    if _value != 0 and self.activation_duration_units != 0:
        shares_add: uint256 = self._shares_for_inactive_at_index(_value, self.activation_index)
        self.inactive_shares[_addr] += shares_add
        self.inactive_generation_for[_addr] = self.activation_generation
        self.total_inactive_balance += _value

@internal
def _convert_method1_to_method2(_addr: address, _new_value: uint256):
    current_inactive: uint256 = self._current_user_inactive(_addr)
    if current_inactive >= self.total_inactive_balance:
        self.total_inactive_balance = 0
    else:
        self.total_inactive_balance -= current_inactive
    self.inactive_shares[_addr] = 0
    self.inactive_generation_for[_addr] = self.activation_generation
    self._set_user_mode(_addr, DEPOSIT_MODE_METHOD2)
    converted: uint256 = self.staked_balance[_addr] + _new_value
    self.withdraw_fee_liability[_addr] = converted * self.withdraw_fee_bps // FEE_DENOMINATOR

@external
@nonreentrant
def deposit(_value: uint256, _addr: address = msg.sender):
    """Method 1. Want eligibility activates fractionally every eight hours."""
    self._check_deposit_authorization(_addr, msg.sender)
    if _value != 0:
        if _addr != msg.sender:
            assert self.deposit_mode[_addr] == DEPOSIT_MODE_METHOD1, "third-party mode mismatch"
        assert self.deposit_mode[_addr] != DEPOSIT_MODE_METHOD2, "method 2 active"
        self._update_all_reward_integrals()
        self._checkpoint_user_current(_addr, False)
        self.total_staked += _value
        self.staked_balance[_addr] += _value
        self._add_method1_deposit(_addr, _value)
        self._forward_deposit_to_boosthub(_value, msg.sender)
    log Deposit(_addr, _value, DEPOSIT_MODE_METHOD1)

@external
@nonreentrant
def deposit_with_withdraw_fee(_value: uint256, _addr: address = msg.sender):
    """Method 2. Full want yield immediately; exits use timelock or the grandfathered withdrawal tax."""
    self._check_deposit_authorization(_addr, msg.sender)
    if _value != 0:
        if _addr != msg.sender:
            assert self.deposit_mode[_addr] == DEPOSIT_MODE_METHOD2, "third-party mode mismatch"
        self._update_all_reward_integrals()
        self._checkpoint_user_current(_addr, False)
        mode: uint256 = self.deposit_mode[_addr]
        if mode == DEPOSIT_MODE_METHOD1:
            self._convert_method1_to_method2(_addr, _value)
        else:
            if mode == DEPOSIT_MODE_NONE:
                self._set_user_mode(_addr, DEPOSIT_MODE_METHOD2)
            assert self.deposit_mode[_addr] == DEPOSIT_MODE_METHOD2
            self.withdraw_fee_liability[_addr] += _value * self.withdraw_fee_bps // FEE_DENOMINATOR
        self.total_staked += _value
        self.staked_balance[_addr] += _value
        self._forward_deposit_to_boosthub(_value, msg.sender)
    log Deposit(_addr, _value, DEPOSIT_MODE_METHOD2)

# ----------------------------- Withdrawals -----------------------------

@internal
def _clear_mode_if_empty(_addr: address):
    if self.staked_balance[_addr] == 0:
        self.inactive_shares[_addr] = 0
        self.queued_balance[_addr] = 0
        self.withdraw_fee_liability[_addr] = 0
        self._set_user_mode(_addr, DEPOSIT_MODE_NONE)

@internal
def _remove_method1_principal(_addr: address, _value: uint256):
    active: uint256 = self.staked_balance[_addr] - self._current_user_inactive(_addr)
    if _value <= active:
        return
    inactive_take: uint256 = _value - active
    shares: uint256 = self.inactive_shares[_addr]
    current_inactive: uint256 = self._inactive_from_shares_at_index(shares, self.activation_index)
    target: uint256 = current_inactive - inactive_take
    new_shares: uint256 = self._shares_for_inactive_at_index(target, self.activation_index)
    new_inactive: uint256 = self._inactive_from_shares_at_index(new_shares, self.activation_index)
    removed: uint256 = current_inactive - new_inactive
    self.inactive_shares[_addr] = new_shares
    if removed >= self.total_inactive_balance:
        self.total_inactive_balance = 0
    else:
        self.total_inactive_balance -= removed

@internal
def _method2_liability_for_amount(_addr: address, _value: uint256) -> uint256:
    active: uint256 = self.staked_balance[_addr] - self.queued_balance[_addr]
    assert _value <= active
    liability: uint256 = self.withdraw_fee_liability[_addr]
    if _value == active:
        return liability
    return liability * _value // active

@external
@nonreentrant
def withdraw(_value: uint256):
    """Method-1 standard withdrawal. No timelock and no withdrawal tax."""
    assert self.deposit_mode[msg.sender] == DEPOSIT_MODE_METHOD1, "method 1 only"
    assert _value <= self.staked_balance[msg.sender]
    self._update_all_reward_integrals()
    self._checkpoint_user_current(msg.sender, False)
    self._remove_method1_principal(msg.sender, _value)
    self.staked_balance[msg.sender] -= _value
    self.total_staked -= _value
    self._withdraw_from_boosthub(_value)
    extcall IERC20(self.lp_token).transfer(msg.sender, _value)
    self._clear_mode_if_empty(msg.sender)
    log Withdraw(msg.sender, _value, 0)

@external
@nonreentrant
def withdraw_with_tax(_value: uint256):
    """Method-2 immediate exit. Uses the fee liability fixed when this principal entered Method 2."""
    assert self.deposit_mode[msg.sender] == DEPOSIT_MODE_METHOD2, "method 2 only"
    self._update_all_reward_integrals()
    self._checkpoint_user_current(msg.sender, False)
    fee: uint256 = self._method2_liability_for_amount(msg.sender, _value)
    self.withdraw_fee_liability[msg.sender] -= fee
    self.staked_balance[msg.sender] -= _value
    self.total_staked -= _value
    self._withdraw_from_boosthub(_value)
    if fee != 0:
        self.pending_boosthub_donation_want += fee
    extcall IERC20(self.lp_token).transfer(msg.sender, _value - fee)
    self._clear_mode_if_empty(msg.sender)
    log Withdraw(msg.sender, _value, fee)

@external
@nonreentrant
def request_withdrawal(_value: uint256) -> (uint256, uint256):
    """Method-2 fee-free queued exit. Queued principal earns non-want rewards but no want rewards."""
    assert self.deposit_mode[msg.sender] == DEPOSIT_MODE_METHOD2, "method 2 only"
    assert _value != 0
    self._update_all_reward_integrals()
    self._checkpoint_user_current(msg.sender, False)
    active: uint256 = self.staked_balance[msg.sender] - self.queued_balance[msg.sender]
    assert _value <= active
    liability: uint256 = self._method2_liability_for_amount(msg.sender, _value)
    self.withdraw_fee_liability[msg.sender] -= liability
    self.queued_balance[msg.sender] += _value
    self.total_queued_balance += _value
    request_id: uint256 = self.next_withdrawal_request_id
    self.next_withdrawal_request_id = request_id + 1
    unlock: uint256 = block.timestamp + self.withdrawal_delay
    self.withdrawal_requests[request_id] = WithdrawalRequest(
        owner=msg.sender,
        amount=_value,
        fee_liability=liability,
        unlock_time=unlock,
        active=True,
    )
    log WithdrawalRequested(msg.sender, request_id, _value, unlock)
    return request_id, unlock

@internal
def _consume_request(_request_id: uint256) -> WithdrawalRequest:
    request: WithdrawalRequest = self.withdrawal_requests[_request_id]
    assert request.active, "inactive request"
    assert request.owner == msg.sender, "not request owner"
    self.withdrawal_requests[_request_id].active = False
    self.queued_balance[msg.sender] -= request.amount
    self.total_queued_balance -= request.amount
    return request

@external
@nonreentrant
def complete_queued_withdrawal(_request_id: uint256) -> uint256:
    self._update_all_reward_integrals()
    self._checkpoint_user_current(msg.sender, False)
    request: WithdrawalRequest = self.withdrawal_requests[_request_id]
    assert request.active and request.owner == msg.sender
    assert block.timestamp >= request.unlock_time, "withdrawal not ready"
    request = self._consume_request(_request_id)
    self.staked_balance[msg.sender] -= request.amount
    self.total_staked -= request.amount
    self._withdraw_from_boosthub(request.amount)
    extcall IERC20(self.lp_token).transfer(msg.sender, request.amount)
    self._clear_mode_if_empty(msg.sender)
    log WithdrawalCompleted(msg.sender, _request_id, request.amount, 0)
    return request.amount

@external
@nonreentrant
def withdraw_queued_immediate(_request_id: uint256) -> uint256:
    self._update_all_reward_integrals()
    self._checkpoint_user_current(msg.sender, False)
    request: WithdrawalRequest = self._consume_request(_request_id)
    self.staked_balance[msg.sender] -= request.amount
    self.total_staked -= request.amount
    self._withdraw_from_boosthub(request.amount)
    if request.fee_liability != 0:
        self.pending_boosthub_donation_want += request.fee_liability
    received: uint256 = request.amount - request.fee_liability
    extcall IERC20(self.lp_token).transfer(msg.sender, received)
    self._clear_mode_if_empty(msg.sender)
    log WithdrawalCompleted(msg.sender, _request_id, request.amount, request.fee_liability)
    return received

# ----------------------------- Claims -----------------------------

@external
@nonreentrant
def claim_rewards():
    self._update_all_reward_integrals()
    self._checkpoint_user_current(msg.sender, True)

@external
@nonreentrant
def claim_reward(_token: address):
    assert self._is_reward_token(_token), "unknown reward"
    self._update_all_reward_integrals()
    self._checkpoint_user_current(msg.sender, False)
    amount: uint256 = self.claim_data[msg.sender][_token]
    if amount != 0:
        self.claim_data[msg.sender][_token] = 0
        extcall IERC20(_token).transfer(msg.sender, amount)

@external
def set_approve_deposit(addr: address, can_deposit: bool):
    self.approved_to_deposit[addr][msg.sender] = can_deposit

# ----------------------------- Reward-token administration -----------------------------

@external
def add_reward(_reward_token: address):
    """Register an admin-approved reward already supported by BoostHub for this PID."""
    assert msg.sender == self.admin, "admin only"
    assert _reward_token != empty(address) and _reward_token != self
    assert not self._is_reward_token(_reward_token), "duplicate reward"
    assert self.reward_count < MAX_REWARDS
    assert staticcall BoostHub(self.boost_hub).isRewardToken(self.pid, _reward_token)
    self.reward_tokens[self.reward_count] = _reward_token
    self.reward_from_boosthub[_reward_token] = True
    self.reward_count += 1
    log AddReward(_reward_token)

@external
def add_external_reward(_reward_token: address):
    """Register a directly-funded reward such as cyGOV; it is never claimed from BoostHub."""
    assert msg.sender == self.admin, "admin only"
    assert _reward_token != empty(address) and _reward_token != self
    assert not self._is_reward_token(_reward_token), "duplicate reward"
    assert self.reward_count < MAX_REWARDS
    if self.performance_fee_staked and _reward_token != self.governance_token:
        assert self.reward_converter[_reward_token] != empty(address), "converter required"
    if _reward_token != self.governance_token and self.yield_boost_fee_bps != 0:
        assert self.reward_converter[_reward_token] != empty(address), "converter required"
    idx: uint256 = self.reward_count
    self.reward_tokens[idx] = _reward_token
    self.reward_from_boosthub[_reward_token] = False
    self.reward_count = idx + 1
    log AddReward(_reward_token)

@external
@nonreentrant
def deposit_reward_token(_reward_token: address, _amount: uint256):
    """Fund a registered external reward stream. Does not call BoostHub."""
    assert _amount != 0, "zero amount"
    assert self._is_reward_token(_reward_token), "unknown reward"
    assert not self.reward_disabled[_reward_token], "reward disabled"
    assert not self.reward_from_boosthub[_reward_token], "BoostHub reward"

    self._update_all_reward_integrals()
    before: uint256 = staticcall IERC20(_reward_token).balanceOf(self)
    extcall IERC20(_reward_token).transferFrom(msg.sender, self, _amount)
    gross: uint256 = staticcall IERC20(_reward_token).balanceOf(self) - before
    assert gross != 0, "zero received"

    perf_fee: uint256 = 0
    yield_fee: uint256 = 0
    performance_stake_want: uint256 = 0
    if _reward_token != self.governance_token:
        perf_fee = gross * self.performance_fee_bps // FEE_DENOMINATOR
        if perf_fee != 0:
            if self.performance_fee_staked:
                performance_stake_want = self._convert_fee_to_want(_reward_token, perf_fee)
            else:
                extcall IERC20(_reward_token).transfer(self.performance_fee_receiver, perf_fee)

        yield_fee = gross * self.yield_boost_fee_bps // FEE_DENOMINATOR
        if yield_fee != 0:
            self.pending_boosthub_donation_want += self._convert_fee_to_want(_reward_token, yield_fee)

    distributable: uint256 = gross - perf_fee - yield_fee
    self._schedule_reward(_reward_token, distributable)

    if performance_stake_want != 0:
        self._credit_method2_stake(self.performance_fee_receiver, performance_stake_want)

    self._process_pending_donation()
    log ExternalRewardFunded(_reward_token, msg.sender, gross, distributable)

@external
@nonreentrant
def disable_reward(_reward_token: address):
    assert msg.sender == self.admin, "admin only"
    assert self._is_reward_token(_reward_token)
    assert _reward_token != self.lp_token, "want required"
    self._update_all_reward_integrals()
    assert block.timestamp >= self.reward_period_finish[_reward_token], "reward stream active"
    if self.reward_from_boosthub[_reward_token]:
        before: uint256 = staticcall IERC20(_reward_token).balanceOf(self)
        raw_call(self.boost_hub, concat(method_id("harvest(uint256)"), convert(self.pid, bytes32)))
        raw_call(
            self.boost_hub,
            concat(
                method_id("claimReward(uint256,address,address)"),
                convert(self.pid, bytes32),
                convert(_reward_token, bytes32),
                convert(self, bytes32),
            ),
        )
        assert staticcall IERC20(_reward_token).balanceOf(self) == before, "fresh reward received"
    self.reward_disabled[_reward_token] = True
    log DisableReward(_reward_token)

# ----------------------------- Config administration -----------------------------

@external
def set_performance_fee_bps(_fee_bps: uint256):
    assert msg.sender == self.admin and _fee_bps <= MAX_PERFORMANCE_FEE_BPS
    self.performance_fee_bps = _fee_bps
    log SetPerformanceFee(_fee_bps)

@external
def set_performance_fee_receiver(_receiver: address):
    assert msg.sender == self.admin and _receiver != empty(address)
    self.performance_fee_receiver = _receiver
    log SetPerformanceFeeReceiver(_receiver)

@external
def set_performance_fee_staked(_enabled: bool):
    assert msg.sender == self.admin, "admin only"
    if _enabled:
        for i: uint256 in range(MAX_REWARDS):
            if i >= self.reward_count:
                break
            token: address = self.reward_tokens[i]
            if token != self.lp_token and token != self.governance_token and not self.reward_disabled[token]:
                assert self.reward_converter[token] != empty(address), "converter required"
    self.performance_fee_staked = _enabled
    log SetPerformanceFeeStaked(_enabled)

@external
def set_yield_boost_fee_bps(_fee_bps: uint256):
    assert msg.sender == self.admin and _fee_bps <= MAX_YIELD_BOOST_FEE_BPS
    self.yield_boost_fee_bps = _fee_bps
    log SetYieldBoostFee(_fee_bps)

@external
def set_fee_conversion_slippage_bps(_slippage_bps: uint256):
    assert msg.sender == self.admin and _slippage_bps <= MAX_FEE_CONVERSION_SLIPPAGE_BPS
    self.fee_conversion_slippage_bps = _slippage_bps

@external
def set_reward_converter(_reward_token: address, _converter: address):
    assert msg.sender == self.admin
    assert self._is_reward_token(_reward_token), "unknown reward"
    assert _reward_token != self.governance_token, "cyGOV fee exempt"
    assert _reward_token != self.lp_token, "converter not allowed"
    assert _converter != empty(address)
    self.reward_converter[_reward_token] = _converter
    log SetRewardConverter(_reward_token, _converter)

@external
def set_withdraw_fee_bps(_fee_bps: uint256):
    assert msg.sender == self.admin and _fee_bps <= MAX_WITHDRAW_FEE_BPS
    self.withdraw_fee_bps = _fee_bps
    log SetWithdrawFee(_fee_bps)

@external
def set_reward_smoothing_units(_units: uint256):
    assert msg.sender == self.admin and _units <= MAX_REWARD_SMOOTHING_UNITS
    self.reward_smoothing_units = _units
    log SetRewardSmoothing(_units)

@external
def set_activation_duration_units(_units: uint256):
    assert msg.sender == self.admin and _units <= MAX_ACTIVATION_DURATION_UNITS
    self._update_all_reward_integrals()
    self.activation_duration_units = _units
    self.activation_remaining_factor = self._remaining_factor_for_units(_units)
    if _units == 0:
        self._force_global_activation()
    log SetActivationDuration(_units)

# ----------------------------- Keeper/admin role transfer -----------------------------

@external
def initiate_keeper_transfer(_new_keeper: address):
    assert msg.sender == self.keeper, "keeper only"
    assert _new_keeper != empty(address)
    self.pending_keeper = _new_keeper
    log CommitKeeperTransfer(_new_keeper)

@external
def accept_keeper():
    assert msg.sender == self.pending_keeper and msg.sender != empty(address)
    self._update_all_reward_integrals()
    old_keeper: address = self.keeper
    self._checkpoint_user_current(old_keeper, False)
    self._checkpoint_user_current(msg.sender, False)
    self.keeper = msg.sender
    self.pending_keeper = empty(address)
    log AcceptKeeperTransfer(msg.sender)

@external
def commit_transfer_ownership(_new_admin: address):
    assert msg.sender == self.admin and _new_admin != empty(address)
    self.future_admin = _new_admin
    log CommitOwnership(_new_admin)

@external
def accept_transfer_ownership():
    assert msg.sender == self.future_admin and msg.sender != empty(address)
    self.admin = msg.sender
    self.future_admin = empty(address)
    log ApplyOwnership(msg.sender)
