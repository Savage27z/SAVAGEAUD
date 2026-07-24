// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IVaultStateWithdrawView {
    // 0 = IDLE, 1 = PENDING.
    function withdrawState() external view returns (uint8 state);

    function pendingWithdrawCollateralSnapshotE18() external view returns (uint256);
}
