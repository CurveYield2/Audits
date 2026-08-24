// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

/// @notice Minimal interface for Curve's cross-chain ChildGauge v1.1.x reward funding surface.
interface ICurveChildGauge {
    function lp_token() external view returns (address);

    function reward_data(address token)
        external
        view
        returns (
            address distributor,
            uint256 periodFinish,
            uint256 rate,
            uint256 lastUpdate,
            uint256 integral
        );

    function deposit_reward_token(address rewardToken, uint256 amount, uint256 epoch) external;
}
