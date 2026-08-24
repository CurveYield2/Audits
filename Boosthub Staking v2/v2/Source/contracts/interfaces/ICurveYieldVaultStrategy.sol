// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

interface ICurveYieldVaultStrategy {
    function want() external view returns (address);
    function vault() external view returns (address);
    function balanceOf() external view returns (uint256);
    function estimatedUnharvestedWant() external view returns (uint256);
    function estimatedTokenAprBps() external view returns (uint256);
    function beforeDeposit() external;
    function beforeDepositStrict() external;
    function beforeWithdraw() external;
    function beforeWithdrawStrict() external;
    function deposit() external;
    function withdrawInstant(uint256 amount) external returns (uint256 received);
    function requestWithdrawal(uint256 amount) external returns (uint256 requestId, uint256 unlockTime);
    function completeWithdrawal(uint256 requestId) external returns (uint256 received);
    function withdrawPendingInstant(uint256 requestId) external returns (uint256 received);
}
