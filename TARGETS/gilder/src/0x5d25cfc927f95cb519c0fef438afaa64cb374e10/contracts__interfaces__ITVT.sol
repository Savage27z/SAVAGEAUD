// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface ITVT {
    event CirculatingSupplyUpdated(uint256 newSupply);
    event TvtSnapshotTaken(uint256 indexed snapshotId, uint256 totalAllocated, uint256 circulatingSupply, uint256 tvt);

    function currentTvt() external view returns (uint256 tvt);

    function recordSupplyChange(int256 delta) external;

    function snapshotTvt() external returns (uint256 snapshotId);

    function snapshotAt(uint256 snapshotId) external view returns (uint256 totalAllocated, uint256 circulatingSupply, uint256 tvt);
}
