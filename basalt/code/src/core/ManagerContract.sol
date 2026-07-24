// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Ownable2Step} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IDepositHandler} from "../interfaces/IDepositHandler.sol";
import {IDolomiteMargin} from "../interfaces/IDolomiteMargin.sol";
import {IFeeAccountingHandler} from "../interfaces/IFeeAccountingHandler.sol";
import {IManagerHandler} from "../interfaces/IManagerHandler.sol";
import {IWithdrawHandler} from "../interfaces/IWithdrawHandler.sol";
import {IDepositHandlerVaultCore} from "../interfaces/IDepositHandlerVaultCore.sol";
import {IFeeAccountingHandlerVaultCore} from "../interfaces/IFeeAccountingHandlerVaultCore.sol";
import {IManagerHandlerVaultCore} from "../interfaces/IManagerHandlerVaultCore.sol";
import {IVaultStateWithdrawView} from "../interfaces/IVaultStateWithdrawView.sol";
import {IVaultCoreGovernance} from "../interfaces/IVaultCoreGovernance.sol";
import {IWithdrawHandlerVaultCore} from "../interfaces/IWithdrawHandlerVaultCore.sol";
import {IBasaltMath} from "../interfaces/IBasaltMath.sol";
import {IInitialCoreAddressBook} from "../interfaces/IInitialCoreAddressBook.sol";
import {BasaltAddresses} from "../libraries/BasaltAddresses.sol";
import {DolomiteReader} from "../libraries/DolomiteReader.sol";
import {VaultState} from "./VaultState.sol";
import {VaultCoreNftFactory} from "./VaultCoreNftFactory.sol";
import {FeeSplitter} from "./FeeSplitter.sol";
import {
    ProtocolManagerProposal,
    NotPendingRole,
    NotFeeCollector,
    NotOperational,
    NotConfigurator,
    NotHandlerProposer,
    NotAddressProposer,
    ZeroFeeSplitter,
    ZeroFactory,
    ZeroProtocolManager,
    ZeroRole,
    SnapshotUnavailable,
    ProposalNotFound,
    ProposalCancelled,
    AlreadySigned,
    AlreadySignedOpposite,
    NoVotingWeight,
    NoPastSupply,
    InsufficientFeeParticipantSupport,
    InsufficientCancelSupport,
    AlreadyExecuted,
    ActiveProposalExists,
    NotCurrentProtocolManager,
    NotAuthorisedToFinalizeProposal,
    NotAuthorisedToCollectFees
} from "./managerContractLibraries/ManagerContractTypes.sol";
import {ManagerContractRequirements} from "./managerContractLibraries/ManagerContractRequirements.sol";

contract ManagerContract is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ════════════════════════════════════════════════════════════════════════
    //  BINDINGS
    // ════════════════════════════════════════════════════════════════════════

    address public configurator;
    address public operational;
    address public handlerProposer;
    address public addressProposer;
    address public feeCollector;

    address public pendingFeeCollector;

    FeeSplitter public immutable feeSplitter;

    // ════════════════════════════════════════════════════════════════════════
    //  CONSTANTS
    // ════════════════════════════════════════════════════════════════════════

    uint256 public constant PROTOCOL_MANAGER_CHANGE_THRESHOLD_BPS = 8000;
    uint256 public constant VOTING_TIMEOUT = 180 days;
    uint8 private constant VAULT_WITHDRAW_STATE_PENDING = 1;

    // ════════════════════════════════════════════════════════════════════════
    //  PROTOCOL MANAGER VOTING STORAGE
    // ════════════════════════════════════════════════════════════════════════

    uint256 public nextProtocolManagerProposalId;
    uint256 public activeProtocolManagerProposalId;

    mapping(uint256 => ProtocolManagerProposal) public protocolManagerProposals;
    mapping(uint256 => mapping(address => bool)) public protocolManagerProposalSigned;
    mapping(uint256 => mapping(address => bool)) public protocolManagerProposalCancelSigned;

    // ════════════════════════════════════════════════════════════════════════
    //  EVENTS
    // ════════════════════════════════════════════════════════════════════════

    event ProtocolManagerChangeProposed(
        uint256 indexed proposalId,
        address indexed factory,
        address indexed nextProtocolManager,
        address proposer,
        uint256 snapshot
    );
    event ProtocolManagerChangeSigned(uint256 indexed proposalId, address indexed signer, uint256 weight);
    event ProtocolManagerChangeCancelSigned(uint256 indexed proposalId, address indexed signer, uint256 weight);
    event ProtocolManagerChangeExecuted(uint256 indexed proposalId, address indexed factory, address nextProtocolManager);
    event ProtocolManagerChangeCancelled(uint256 indexed proposalId);
    event FeesSwept(address indexed token, uint256 amount, address indexed to);
    event ConfiguratorChanged(address indexed previous, address indexed current);
    event OperationalChanged(address indexed previous, address indexed current);
    event HandlerProposerChanged(address indexed previous, address indexed current);
    event AddressProposerChanged(address indexed previous, address indexed current);
    event FeeCollectorChangeProposed(address indexed current, address indexed pending);
    event FeeCollectorChanged(address indexed previous, address indexed current);

    // ════════════════════════════════════════════════════════════════════════
    //  MODIFIERS
    // ════════════════════════════════════════════════════════════════════════

    modifier onlyOperational() {
        if (msg.sender != operational && msg.sender != owner()) revert NotOperational();
        _;
    }

    modifier onlyConfigurator() {
        if (msg.sender != configurator && msg.sender != owner()) revert NotConfigurator();
        _;
    }

    modifier onlyHandlerProposer() {
        if (msg.sender != handlerProposer && msg.sender != owner()) revert NotHandlerProposer();
        _;
    }

    modifier onlyAddressProposer() {
        if (msg.sender != addressProposer && msg.sender != owner()) revert NotAddressProposer();
        _;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  INIT
    // ════════════════════════════════════════════════════════════════════════

    constructor(address feeSplitterAddress) Ownable(msg.sender) {
        if (feeSplitterAddress == address(0)) revert ZeroFeeSplitter();
        feeSplitter = FeeSplitter(feeSplitterAddress);
        configurator = msg.sender;
        operational = msg.sender;
        handlerProposer = msg.sender;
        addressProposer = msg.sender;
        feeCollector = msg.sender;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  OWNER
    // ════════════════════════════════════════════════════════════════════════

    function setConfigurator(address newConfigurator) external onlyOwner {
        if (newConfigurator == address(0)) revert ZeroRole();
        address previous = configurator;
        configurator = newConfigurator;
        emit ConfiguratorChanged(previous, newConfigurator);
    }

    function setOperational(address newOperational) external onlyOwner {
        if (newOperational == address(0)) revert ZeroRole();
        address previous = operational;
        operational = newOperational;
        emit OperationalChanged(previous, newOperational);
    }

    function setHandlerProposer(address newHandlerProposer) external onlyOwner {
        if (newHandlerProposer == address(0)) revert ZeroRole();
        address previous = handlerProposer;
        handlerProposer = newHandlerProposer;
        emit HandlerProposerChanged(previous, newHandlerProposer);
    }

    function setAddressProposer(address newAddressProposer) external onlyOwner {
        if (newAddressProposer == address(0)) revert ZeroRole();
        address previous = addressProposer;
        addressProposer = newAddressProposer;
        emit AddressProposerChanged(previous, newAddressProposer);
    }

    function proposeFeeCollector(address newFeeCollector) external {
        if (msg.sender != feeCollector) revert NotFeeCollector();
        if (newFeeCollector == address(0)) revert ZeroRole();
        pendingFeeCollector = newFeeCollector;
        emit FeeCollectorChangeProposed(feeCollector, newFeeCollector);
    }

    function acceptFeeCollector() external {
        if (msg.sender != pendingFeeCollector) revert NotPendingRole(msg.sender, pendingFeeCollector);
        address previous = feeCollector;
        feeCollector = pendingFeeCollector;
        delete pendingFeeCollector;
        emit FeeCollectorChanged(previous, feeCollector);
    }

    function setInitialCoreAddressBook(
        VaultCoreNftFactory vaultCoreNftFactory,
        IInitialCoreAddressBook nextInitialCoreAddressBook
    ) external onlyOwner {
        vaultCoreNftFactory.setInitialCoreAddressBook(nextInitialCoreAddressBook);
    }

    function addFeeSplitterTrackedToken(IERC20 token) external onlyOwner {
        feeSplitter.addTrackedToken(token);
    }

    function setFeeSplitterTokenSkipped(IERC20 token, bool v) external onlyOwner {
        feeSplitter.setTokenSkipped(token, v);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  PROTOCOL MANAGER VOTING
    // ════════════════════════════════════════════════════════════════════════

    function proposeProtocolManagerChange(VaultCoreNftFactory factory, address nextProtocolManager)
        external
        returns (uint256 proposalId)
    {
        if (address(factory) == address(0)) revert ZeroFactory();
        if (nextProtocolManager == address(0)) revert ZeroProtocolManager();
        if (block.number <= 1) revert SnapshotUnavailable();
        if (factory.protocolManager() != address(this)) revert NotCurrentProtocolManager();

        uint256 activeId = activeProtocolManagerProposalId;
        if (activeId != 0) {
            ProtocolManagerProposal storage active = protocolManagerProposals[activeId];
            if (!active.executed && !active.cancelled) revert ActiveProposalExists(activeId);
        }

        uint256 snapshot = block.number - 1;
        if (feeSplitter.getPastVotes(msg.sender, snapshot) == 0) revert NoVotingWeight();

        proposalId = ++nextProtocolManagerProposalId;
        protocolManagerProposals[proposalId] = ProtocolManagerProposal({
            factory: factory,
            nextProtocolManager: nextProtocolManager,
            snapshot: snapshot,
            yesWeight: 0,
            cancelWeight: 0,
            createdAt: block.timestamp,
            executed: false,
            cancelled: false
        });
        activeProtocolManagerProposalId = proposalId;

        emit ProtocolManagerChangeProposed(proposalId, address(factory), nextProtocolManager, msg.sender, snapshot);
    }

    function signProtocolManagerChange(uint256 proposalId) external {
        ProtocolManagerProposal storage proposal = protocolManagerProposals[proposalId];
        if (proposal.nextProtocolManager == address(0)) revert ProposalNotFound();
        if (proposal.cancelled) revert ProposalCancelled();
        if (proposal.executed) revert AlreadyExecuted();
        if (protocolManagerProposalSigned[proposalId][msg.sender]) revert AlreadySigned();
        if (protocolManagerProposalCancelSigned[proposalId][msg.sender]) revert AlreadySignedOpposite();

        uint256 weight = feeSplitter.getPastVotes(msg.sender, proposal.snapshot);
        if (weight == 0) revert NoVotingWeight();

        protocolManagerProposalSigned[proposalId][msg.sender] = true;
        proposal.yesWeight += weight;

        emit ProtocolManagerChangeSigned(proposalId, msg.sender, weight);
    }

    function signProtocolManagerChangeCancel(uint256 proposalId) external {
        ProtocolManagerProposal storage proposal = protocolManagerProposals[proposalId];
        if (proposal.nextProtocolManager == address(0)) revert ProposalNotFound();
        if (proposal.cancelled) revert ProposalCancelled();
        if (proposal.executed) revert AlreadyExecuted();
        if (protocolManagerProposalCancelSigned[proposalId][msg.sender]) revert AlreadySigned();
        if (protocolManagerProposalSigned[proposalId][msg.sender]) revert AlreadySignedOpposite();

        uint256 weight = feeSplitter.getPastVotes(msg.sender, proposal.snapshot);
        if (weight == 0) revert NoVotingWeight();

        protocolManagerProposalCancelSigned[proposalId][msg.sender] = true;
        proposal.cancelWeight += weight;

        emit ProtocolManagerChangeCancelSigned(proposalId, msg.sender, weight);
    }

    function executeProtocolManagerChange(uint256 proposalId) external {
        ProtocolManagerProposal storage proposal = protocolManagerProposals[proposalId];
        if (proposal.nextProtocolManager == address(0)) revert ProposalNotFound();
        if (proposal.cancelled) revert ProposalCancelled();
        if (proposal.executed) revert AlreadyExecuted();

        ManagerContractRequirements.requireSnapshotHolderOrOperational(feeSplitter, operational, proposal.snapshot);

        uint256 pastSupply = feeSplitter.getPastTotalSupply(proposal.snapshot);
        if (pastSupply == 0) revert NoPastSupply();

        bool timedOut = block.timestamp >= proposal.createdAt + VOTING_TIMEOUT;

        if (timedOut) {
            // After 6 months: majority of votes cast, with minimum 10% quorum
            uint256 MIN_TIMEOUT_QUORUM_BPS = 1000;
            if (proposal.yesWeight * 10_000 < pastSupply * MIN_TIMEOUT_QUORUM_BPS) {
                revert InsufficientFeeParticipantSupport();
            }
            // Ties go to cancel — strict greater required
            if (proposal.yesWeight <= proposal.cancelWeight) {
                revert InsufficientFeeParticipantSupport();
            }
        } else {
            // Normal path: 80% of total supply
            if (proposal.yesWeight * 10_000 < pastSupply * PROTOCOL_MANAGER_CHANGE_THRESHOLD_BPS) {
                revert InsufficientFeeParticipantSupport();
            }
        }

        proposal.executed = true;
        if (activeProtocolManagerProposalId == proposalId) {
            activeProtocolManagerProposalId = 0;
        }
        proposal.factory.setProtocolManager(proposal.nextProtocolManager);

        emit ProtocolManagerChangeExecuted(proposalId, address(proposal.factory), proposal.nextProtocolManager);
    }

    function cancelProtocolManagerChange(uint256 proposalId) external {
        ProtocolManagerProposal storage proposal = protocolManagerProposals[proposalId];
        if (proposal.nextProtocolManager == address(0)) revert ProposalNotFound();
        if (proposal.executed) revert AlreadyExecuted();
        if (proposal.cancelled) revert ProposalCancelled();

        ManagerContractRequirements.requireSnapshotHolderOrOperational(feeSplitter, operational, proposal.snapshot);

        uint256 pastSupply = feeSplitter.getPastTotalSupply(proposal.snapshot);
        if (pastSupply == 0) revert NoPastSupply();

        bool timedOut = block.timestamp >= proposal.createdAt + VOTING_TIMEOUT;

        if (timedOut) {
            // After 6 months: cancel needs majority or tie (ties go to cancel)
            uint256 MIN_TIMEOUT_QUORUM_BPS = 1000;
            if (proposal.cancelWeight * 10_000 < pastSupply * MIN_TIMEOUT_QUORUM_BPS) {
                revert InsufficientCancelSupport();
            }
            // Ties resolve as cancel — cancel needs >= yesWeight
            if (proposal.cancelWeight < proposal.yesWeight) {
                revert InsufficientCancelSupport();
            }
        } else {
            // Normal path: 80% of total supply
            if (proposal.cancelWeight * 10_000 < pastSupply * PROTOCOL_MANAGER_CHANGE_THRESHOLD_BPS) {
                revert InsufficientCancelSupport();
            }
        }

        proposal.cancelled = true;
        if (activeProtocolManagerProposalId == proposalId) {
            activeProtocolManagerProposalId = 0;
        }
        emit ProtocolManagerChangeCancelled(proposalId);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  CONFIGURATOR
    // ════════════════════════════════════════════════════════════════════════

    function setVaultTargetLtv(IManagerHandler handler, IManagerHandlerVaultCore vault, uint256 bps)
        external
        onlyConfigurator
    {
        handler.setTargetLtv(vault, bps);
    }

    function setVaultKeeperDeadline(IManagerHandler handler, IManagerHandlerVaultCore vault, uint256 deadline)
        external
        onlyConfigurator
    {
        handler.setKeeperDeadline(vault, deadline);
    }

    function setVaultRebalanceSlippageCapBps(IManagerHandler handler, IManagerHandlerVaultCore vault, uint256 bps)
        external
        onlyConfigurator
    {
        handler.setRebalanceSlippageCapBps(vault, bps);
    }

    function setVaultUnwrapLongShareBps(IManagerHandler handler, IManagerHandlerVaultCore vault, uint256 bps)
        external
        onlyConfigurator
    {
        handler.setUnwrapLongShareBps(vault, bps);
    }

    function setVaultRebalanceThresholdUpBps(IManagerHandler handler, IManagerHandlerVaultCore vault, uint256 bps)
        external
        onlyConfigurator
    {
        handler.setRebalanceThresholdUpBps(vault, bps);
    }

    function setVaultRebalanceThresholdDownBps(IManagerHandler handler, IManagerHandlerVaultCore vault, uint256 bps)
        external
        onlyConfigurator
    {
        handler.setRebalanceThresholdDownBps(vault, bps);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  HANDLER PROPOSER
    // ════════════════════════════════════════════════════════════════════════

    function proposeHandler(IVaultCoreGovernance vaultCore, address oldHandler, address newHandler)
        external
        onlyHandlerProposer
    {
        vaultCore.proposeHandler(oldHandler, newHandler);
    }

    function cancelHandlerProposal(IVaultCoreGovernance vaultCore) external onlyHandlerProposer {
        vaultCore.cancelHandlerProposal();
    }

    // ════════════════════════════════════════════════════════════════════════
    //  ADDRESS PROPOSER
    // ════════════════════════════════════════════════════════════════════════

    function proposeBasaltAddresses(IVaultCoreGovernance vaultCore, address newBasaltMath, address newBasaltState)
        external
        onlyAddressProposer
    {
        vaultCore.proposeBasaltAddresses(newBasaltMath, newBasaltState);
    }

    function cancelBasaltAddressesProposal(IVaultCoreGovernance vaultCore) external onlyAddressProposer {
        vaultCore.cancelBasaltAddressesProposal();
    }

    // ════════════════════════════════════════════════════════════════════════
    //  OPERATIONAL
    // ════════════════════════════════════════════════════════════════════════

    function rebalanceVault(IManagerHandler handler, IManagerHandlerVaultCore vault, uint256 managerSlippageBps)
        external
        payable
        onlyOperational
    {
        handler.rebalance{value: msg.value}(vault, managerSlippageBps);
    }

    function finalizeRebalance(IManagerHandler handler, IManagerHandlerVaultCore vault) external onlyOperational {
        handler.finalizeRebalance(vault);
    }

    function pingVaultHeartbeat(IManagerHandler handler, IManagerHandlerVaultCore vault) external onlyOperational {
        handler.pingHeartbeat(vault);
    }

    function finalizeDeposit(IDepositHandler depositHandler, IDepositHandlerVaultCore vault) external onlyOperational {
        depositHandler.finalizeDeposit(vault);
    }

    function notifyFeeSplitterReward(IERC20 token) external onlyOperational {
        feeSplitter.notifyReward(token);
    }

    function finalizeWithdraw(IWithdrawHandler withdrawHandler, IWithdrawHandlerVaultCore vault) external onlyOperational {
        withdrawHandler.finalizeWithdraw(vault);
    }

    function accrueManagerFee(
        IFeeAccountingHandler feeAccountingHandler,
        IFeeAccountingHandlerVaultCore vault,
        IBasaltMath basaltMath
    ) external onlyOperational {
        feeAccountingHandler.accrueManagerFee(vault, basaltMath, address(this));
    }

    function withdrawManagerFee(
        IWithdrawHandler withdrawHandler,
        IWithdrawHandlerVaultCore vault,
        uint256 sharesToWithdrawE18,
        uint256 minWbtcOutE8
    ) external payable onlyOperational {
        withdrawHandler.withdrawManagerFeeShares{value: msg.value}(vault, sharesToWithdrawE18, minWbtcOutE8);
    }

    function collectManagerFeesFromVaultAndSweep(
        IWithdrawHandler withdrawHandler,
        IWithdrawHandlerVaultCore vault,
        uint256 sharesToWithdrawE18,
        uint256 minWbtcOutE8,
        IERC20[] calldata tokens
    ) external payable onlyOperational {
        withdrawHandler.withdrawManagerFeeShares{value: msg.value}(vault, sharesToWithdrawE18, minWbtcOutE8);

        IVaultStateWithdrawView vaultWithdrawLifecycle = IVaultStateWithdrawView(vault.basaltState());
        if (vaultWithdrawLifecycle.withdrawState() == VAULT_WITHDRAW_STATE_PENDING) {
            uint256 collateralAtPendingStartE18 = vaultWithdrawLifecycle.pendingWithdrawCollateralSnapshotE18();
            address dolomiteIsolationVaultAddress = VaultState(vault.basaltState()).dolomiteIsolationVault();
            uint256 currentGmCollateralE18 = dolomiteIsolationVaultAddress == address(0)
                ? 0
                : DolomiteReader.getActualGmCollateralE18(
                    IDolomiteMargin(BasaltAddresses.DOLOMITE_MARGIN),
                    dolomiteIsolationVaultAddress
                );
            if (currentGmCollateralE18 != collateralAtPendingStartE18) {
                withdrawHandler.finalizeWithdraw(vault);
            }
        }

        _sweepTokensToFeeSplitter(tokens);
    }

    function finalizeManagerFeeWithdrawAndSweep(IWithdrawHandler withdrawHandler, IWithdrawHandlerVaultCore vault, IERC20[] calldata tokens)
        external
        onlyOperational
    {
        withdrawHandler.finalizeWithdraw(vault);
        _sweepTokensToFeeSplitter(tokens);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  FEE HUB
    // ════════════════════════════════════════════════════════════════════════

    function collectFees(IERC20[] calldata tokens) external nonReentrant {
        if (msg.sender != operational && feeSplitter.balanceOf(msg.sender) == 0) {
            revert NotAuthorisedToCollectFees(msg.sender);
        }
        _sweepTokensToFeeSplitter(tokens);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  INTERNALS
    // ════════════════════════════════════════════════════════════════════════

    function _sweepTokensToFeeSplitter(IERC20[] calldata tokens) private {
        address to = address(feeSplitter);
        for (uint256 i = 0; i < tokens.length; i++) {
            IERC20 t = tokens[i];
            if (!feeSplitter.isTrackedToken(t)) continue;
            uint256 bal = t.balanceOf(address(this));
            if (bal > 0) {
                t.safeTransfer(to, bal);
                feeSplitter.notifyReward(t);
                emit FeesSwept(address(t), bal, to);
            }
        }
    }
}
