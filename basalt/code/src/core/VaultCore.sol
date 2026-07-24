// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IVaultCoreGovernance} from "../interfaces/IVaultCoreGovernance.sol";
import {IVaultCoreNftFactory} from "../interfaces/IVaultCoreNftFactory.sol";
import {VaultState} from "./VaultState.sol";
import {BasaltConstants} from "../libraries/BasaltConstants.sol";
import {
    HandlerProposal,
    BasaltAddressesProposal,
    NotManager,
    NotHandler,
    NotNftOwner,
    NotManagerOrNftOwner,
    NoHandlerProposal,
    NoBasaltAddressesProposal,
    UnknownHandler,
    AlreadyInitialized,
    ZeroHandler,
    DuplicateHandler,
    DeadmanAlreadyTriggered,
    DeadmanPeriodNotElapsed
} from "./vaultCoreLibraries/VaultCoreTypes.sol";
import {VaultCoreRequirements} from "./vaultCoreLibraries/VaultCoreRequirements.sol";

contract VaultCore is IVaultCoreGovernance {
    // ════════════════════════════════════════════════════════════════════════
    //  BINDINGS
    // ════════════════════════════════════════════════════════════════════════

    address public FACTORY;
    bool public initialized;
    address public basaltMath;
    address public basaltState;
    uint256 public accountedCapital;

    // ════════════════════════════════════════════════════════════════════════
    //  HANDLER SLOTS
    // ════════════════════════════════════════════════════════════════════════

    address public depositHandler;
    address public withdrawHandler;
    address public managerHandler;
    address public asyncRecoveryHandler;
    address public feeAccountingHandler;
    address public extensionHandler1;
    address public extensionHandler2;
    address public extensionHandler3;

    // ════════════════════════════════════════════════════════════════════════
    //  GOVERNANCE PROPOSALS
    // ════════════════════════════════════════════════════════════════════════

    HandlerProposal public handlerProposal;
    BasaltAddressesProposal public basaltAddressesProposal;

    // ════════════════════════════════════════════════════════════════════════
    //  EVENTS
    // ════════════════════════════════════════════════════════════════════════

    event UniversalCallExecuted(
        address indexed handler,
        address indexed initiator,
        address indexed target,
        uint256 value,
        bool useDelegateCall,
        bool success,
        bytes result
    );
    event HandlerProposalCreated(address indexed manager, address indexed oldHandler, address indexed newHandler);
    event HandlerProposalAccepted(address indexed nftOwner, address indexed oldHandler, address indexed newHandler);
    event HandlerProposalCancelled(address indexed caller, address indexed oldHandler, address indexed newHandler);
    event BasaltAddressesProposalCreated(
        address indexed manager, address indexed newBasaltMath, address indexed newBasaltState
    );
    event BasaltAddressesProposalAccepted(
        address indexed nftOwner, address indexed newBasaltMath, address indexed newBasaltState
    );
    event BasaltAddressesProposalCancelled(
        address indexed caller, address indexed newBasaltMath, address indexed newBasaltState
    );
    event ManagerDeadmanTriggered(address indexed nftOwner, uint256 atBlock, uint256 lastManagerActionBlock);

    // ════════════════════════════════════════════════════════════════════════
    //  MODIFIERS
    // ════════════════════════════════════════════════════════════════════════

    modifier onlyManager() {
        address protocolManager = IVaultCoreNftFactory(FACTORY).protocolManager();
        if (msg.sender == protocolManager) {
            _;
            return;
        }
        if (
            VaultState(basaltState).managerDeadmanTriggered()
                && msg.sender == IVaultCoreNftFactory(FACTORY).ownerOfVault(address(this))
        ) {
            _;
            return;
        }
        revert NotManager();
    }

    modifier onlyHandler() {
        if (!_isHandlerSlot(msg.sender)) revert NotHandler();
        _;
    }

    modifier onlyNftOwner() {
        if (msg.sender != IVaultCoreNftFactory(FACTORY).ownerOfVault(address(this))) revert NotNftOwner();
        _;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  INIT
    // ════════════════════════════════════════════════════════════════════════

    constructor() {
        initialized = true;
    }

    function initialize(
        address initialFactory,
        address initialBasaltMath,
        address initialDepositHandler,
        address initialWithdrawHandler,
        address initialManagerHandler,
        address initialAsyncRecoveryHandler,
        address initialFeeAccountingHandler,
        address initialBasaltState,
        address initialExtensionHandler1,
        address initialExtensionHandler2,
        address initialExtensionHandler3
    ) external {
        if (initialized) revert AlreadyInitialized();
        initialized = true;
        FACTORY = initialFactory;
        basaltMath = initialBasaltMath;
        depositHandler = initialDepositHandler;
        withdrawHandler = initialWithdrawHandler;
        managerHandler = initialManagerHandler;
        asyncRecoveryHandler = initialAsyncRecoveryHandler;
        feeAccountingHandler = initialFeeAccountingHandler;
        basaltState = initialBasaltState;
        extensionHandler1 = initialExtensionHandler1;
        extensionHandler2 = initialExtensionHandler2;
        extensionHandler3 = initialExtensionHandler3;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  UNIVERSAL CALL
    // ════════════════════════════════════════════════════════════════════════

    function universalCall(address initiator, address target, bytes calldata data, uint256 value, bool useDelegateCall)
        external
        payable
        onlyHandler
        returns (bytes memory)
    {
        IVaultCoreNftFactory factory = IVaultCoreNftFactory(FACTORY);
        address vaultNftOwner = factory.ownerOfVault(address(this));
        address protocolManager = factory.protocolManager();
        if (initiator != vaultNftOwner && initiator != protocolManager) revert NotManagerOrNftOwner();

        bool callSucceeded;
        bytes memory returnData;
        if (useDelegateCall) {
            (callSucceeded, returnData) = target.delegatecall(data);
        } else {
            (callSucceeded, returnData) = target.call{value: value}(data);
        }
        emit UniversalCallExecuted(msg.sender, initiator, target, value, useDelegateCall, callSucceeded, returnData);
        if (!callSucceeded) assembly { revert(add(returnData, 32), mload(returnData)) }
        return returnData;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  HANDLER GOVERNANCE
    // ════════════════════════════════════════════════════════════════════════

    function proposeHandler(address oldHandler, address newHandler) external onlyManager {
        if (!_isHandlerSlot(oldHandler)) revert UnknownHandler();
        if (newHandler == address(0)) revert ZeroHandler();
        if (_isHandlerSlot(newHandler)) revert DuplicateHandler();
        handlerProposal = HandlerProposal({oldHandler: oldHandler, newHandler: newHandler, exists: true});
        emit HandlerProposalCreated(msg.sender, oldHandler, newHandler);
    }

    function acceptHandler() external onlyNftOwner {
        HandlerProposal memory proposal = handlerProposal;
        if (!proposal.exists) revert NoHandlerProposal();

        _replaceHandler(proposal.oldHandler, proposal.newHandler);

        delete handlerProposal;
        emit HandlerProposalAccepted(msg.sender, proposal.oldHandler, proposal.newHandler);
    }

    function cancelHandlerProposal() external {
        VaultCoreRequirements.requireProtocolManagerOrVaultNftOwner(FACTORY, address(this));
        if (!handlerProposal.exists) revert NoHandlerProposal();
        HandlerProposal memory proposal = handlerProposal;
        delete handlerProposal;
        emit HandlerProposalCancelled(msg.sender, proposal.oldHandler, proposal.newHandler);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  BASALT ADDRESSES GOVERNANCE
    // ════════════════════════════════════════════════════════════════════════

    function proposeBasaltAddresses(address newBasaltMath, address newBasaltState) external onlyManager {
        basaltAddressesProposal =
            BasaltAddressesProposal({newBasaltMath: newBasaltMath, newBasaltState: newBasaltState, exists: true});
        emit BasaltAddressesProposalCreated(msg.sender, newBasaltMath, newBasaltState);
    }

    function acceptBasaltAddresses() external onlyNftOwner {
        BasaltAddressesProposal memory proposal = basaltAddressesProposal;
        if (!proposal.exists) revert NoBasaltAddressesProposal();

        basaltMath = proposal.newBasaltMath;
        basaltState = proposal.newBasaltState;

        delete basaltAddressesProposal;
        emit BasaltAddressesProposalAccepted(msg.sender, proposal.newBasaltMath, proposal.newBasaltState);
    }

    function cancelBasaltAddressesProposal() external {
        VaultCoreRequirements.requireProtocolManagerOrVaultNftOwner(FACTORY, address(this));
        BasaltAddressesProposal memory proposal = basaltAddressesProposal;
        if (!proposal.exists) revert NoBasaltAddressesProposal();
        delete basaltAddressesProposal;
        emit BasaltAddressesProposalCancelled(msg.sender, proposal.newBasaltMath, proposal.newBasaltState);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  DEADMAN SWITCH
    // ════════════════════════════════════════════════════════════════════════

    function triggerManagerDeadman() external {
        VaultState vs = VaultState(basaltState);
        if (vs.managerDeadmanTriggered()) revert DeadmanAlreadyTriggered();
        if (msg.sender != IVaultCoreNftFactory(FACTORY).ownerOfVault(address(this))) revert NotNftOwner();
        uint256 lastAction = vs.lastManagerActionBlock();
        uint256 unlockAt = lastAction + BasaltConstants.MANAGER_DEADMAN_BLOCKS;
        if (block.number <= unlockAt) revert DeadmanPeriodNotElapsed(block.number, unlockAt);
        vs.setManagerDeadmanTriggered();
        emit ManagerDeadmanTriggered(msg.sender, block.number, lastAction);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  ETH RECEIVE
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Accept ETH (Dolomite execution fee refunds, GMX keeper refunds, etc.)
    receive() external payable {}

    // ════════════════════════════════════════════════════════════════════════
    //  HANDLER SLOT INTERNALS
    // ════════════════════════════════════════════════════════════════════════

    function _isHandlerSlot(address handler) internal view returns (bool) {
        return handler == depositHandler || handler == withdrawHandler || handler == managerHandler
            || handler == asyncRecoveryHandler || handler == feeAccountingHandler || handler == extensionHandler1
            || handler == extensionHandler2 || handler == extensionHandler3;
    }

    function _replaceHandler(address oldHandler, address newHandler) internal {
        if (oldHandler == depositHandler) depositHandler = newHandler;
        else if (oldHandler == withdrawHandler) withdrawHandler = newHandler;
        else if (oldHandler == managerHandler) managerHandler = newHandler;
        else if (oldHandler == asyncRecoveryHandler) asyncRecoveryHandler = newHandler;
        else if (oldHandler == feeAccountingHandler) feeAccountingHandler = newHandler;
        else if (oldHandler == extensionHandler1) extensionHandler1 = newHandler;
        else if (oldHandler == extensionHandler2) extensionHandler2 = newHandler;
        else if (oldHandler == extensionHandler3) extensionHandler3 = newHandler;
    }
}
