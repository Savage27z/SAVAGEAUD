// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IAutoCompound {
    enum CompoundMode {
        Off,
        Standard,
        Turbo
    }

    event CompoundModeSet(uint256 indexed depositId, CompoundMode mode);

    function setCompoundMode(uint256 depositId, CompoundMode mode) external;
}

