// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {VaultCore} from "../core/VaultCore.sol";
import {VaultState} from "../core/VaultState.sol";
import {IInitialCoreAddressBook} from "../interfaces/IInitialCoreAddressBook.sol";
import {
    ZeroOwner,
    VaultAlreadyIssued,
    UnknownTokenId,
    ZeroAddressBook,
    ZeroProtocolManager,
    NotCurrentProtocolManager,
    AddressBookCooldownActive
} from "./vaultCoreNftFactoryLibraries/VaultCoreNftFactoryTypes.sol";

contract VaultCoreNftFactory is ERC721, Ownable2Step, ReentrancyGuard {
    // ════════════════════════════════════════════════════════════════════════
    //  CONSTANTS
    // ════════════════════════════════════════════════════════════════════════

    uint256 public constant ADDRESS_BOOK_COOLDOWN_CHANGE_PERIOD = 24 hours;

    // ════════════════════════════════════════════════════════════════════════
    //  STORAGE
    // ════════════════════════════════════════════════════════════════════════

    uint256 public nextTokenId;
    IInitialCoreAddressBook public initialCoreAddressBook;
    uint256 public addressBookCooldownEndsAt;
    address public protocolManager;

    mapping(uint256 => address) public vaultByTokenId;
    mapping(address => uint256) public tokenIdByVault;

    // ════════════════════════════════════════════════════════════════════════
    //  EVENTS
    // ════════════════════════════════════════════════════════════════════════

    event VaultIssued(uint256 indexed tokenId, address indexed owner, address indexed vaultCore);
    event ProtocolManagerUpdated(address indexed previousProtocolManager, address indexed nextProtocolManager);
    event InitialCoreAddressBookUpdated(
        address indexed oldAddressBook, address indexed newAddressBook, uint256 cooldownEndsAt
    );

    // ════════════════════════════════════════════════════════════════════════
    //  INIT
    // ════════════════════════════════════════════════════════════════════════

    constructor(IInitialCoreAddressBook initial, address initialOwner, address initialProtocolManager)
        ERC721("Basalt Vault Ownership", "BV-OWN")
        Ownable(initialOwner)
    {
        if (address(initial) == address(0)) revert ZeroAddressBook();
        if (initialProtocolManager == address(0)) revert ZeroProtocolManager();
        initialCoreAddressBook = initial;
        protocolManager = initialProtocolManager;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  PROTOCOL MANAGER ROTATION
    // ════════════════════════════════════════════════════════════════════════

    function setProtocolManager(address nextProtocolManager) external {
        if (msg.sender != protocolManager) revert NotCurrentProtocolManager();
        if (nextProtocolManager == address(0)) revert ZeroProtocolManager();
        address previous = protocolManager;
        protocolManager = nextProtocolManager;
        emit ProtocolManagerUpdated(previous, nextProtocolManager);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  ADDRESS BOOK GOVERNANCE
    // ════════════════════════════════════════════════════════════════════════

    function setInitialCoreAddressBook(IInitialCoreAddressBook nextInitial) external onlyOwner {
        if (address(nextInitial) == address(0)) revert ZeroAddressBook();
        address oldAddressBook = address(initialCoreAddressBook);
        initialCoreAddressBook = nextInitial;
        addressBookCooldownEndsAt = block.timestamp + ADDRESS_BOOK_COOLDOWN_CHANGE_PERIOD;
        emit InitialCoreAddressBookUpdated(oldAddressBook, address(nextInitial), addressBookCooldownEndsAt);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  VAULT ISSUANCE
    // ════════════════════════════════════════════════════════════════════════

    function createVaultCore(address owner) external nonReentrant returns (uint256 tokenId, address vaultCore) {
        if (owner == address(0)) revert ZeroOwner();
        if (block.timestamp < addressBookCooldownEndsAt) {
            revert AddressBookCooldownActive(
                address(initialCoreAddressBook), addressBookCooldownEndsAt, addressBookCooldownEndsAt - block.timestamp
            );
        }

        IInitialCoreAddressBook initial = initialCoreAddressBook;
        vaultCore = Clones.clone(initial.vaultCore());
        address vaultState = Clones.clone(initial.basaltState());
        VaultCore(payable(vaultCore))
            .initialize(
                address(this),
                initial.basaltMath(),
                initial.depositHandler(),
                initial.withdrawHandler(),
                initial.managerHandler(),
                initial.asyncRecoveryHandler(),
                initial.feeAccountingHandler(),
                vaultState,
                initial.extensionHandler1(),
                initial.extensionHandler2(),
                initial.extensionHandler3()
            );
        VaultState(vaultState).initialize(vaultCore, owner);
        if (tokenIdByVault[vaultCore] != 0) revert VaultAlreadyIssued();

        tokenId = ++nextTokenId;
        _mint(owner, tokenId);

        vaultByTokenId[tokenId] = vaultCore;
        tokenIdByVault[vaultCore] = tokenId;

        emit VaultIssued(tokenId, owner, vaultCore);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  LOOKUPS
    // ════════════════════════════════════════════════════════════════════════

    function ownerOfVault(address vaultCore) external view returns (address owner) {
        uint256 tokenId = tokenIdByVault[vaultCore];
        if (tokenId == 0) revert UnknownTokenId();
        return ownerOf(tokenId);
    }
}
