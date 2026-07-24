// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

error AlreadyInitialized();
error DolomiteIsolationVaultAlreadyInitialized();
error InvalidManagementFee(uint256 nextManagementFeeBps, uint256 minManagementFeeBps, uint256 maxManagementFeeBps);
error ManagementFeeCannotIncrease(uint256 currentManagementFeeBps, uint256 nextManagementFeeBps);
error InvalidKeeperDeadline(uint256 nextKeeperDeadline, uint256 minKeeperDeadline, uint256 maxKeeperDeadline);
error InvalidTargetLtv(uint256 nextTargetLtvBps, uint256 minTargetLtvBps, uint256 maxTargetLtvBps);
error VaultNotIdle();
error NotVaultCore();

library VaultStateTypes {}
