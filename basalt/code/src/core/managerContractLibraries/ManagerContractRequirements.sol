// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FeeSplitter} from "../FeeSplitter.sol";
import {NotAuthorisedToFinalizeProposal} from "./ManagerContractTypes.sol";

library ManagerContractRequirements {
    function requireSnapshotHolderOrOperational(
        FeeSplitter feeSplitter,
        address operational,
        uint256 snapshot
    ) internal view {
        if (msg.sender == operational) return;
        if (feeSplitter.getPastVotes(msg.sender, snapshot) > 0) return;
        revert NotAuthorisedToFinalizeProposal(msg.sender);
    }
}
