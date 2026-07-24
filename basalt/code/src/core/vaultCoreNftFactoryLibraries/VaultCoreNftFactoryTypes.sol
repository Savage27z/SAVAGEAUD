// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

error ZeroOwner();
error VaultAlreadyIssued();
error UnknownTokenId();
error ZeroAddressBook();
error ZeroProtocolManager();
error NotCurrentProtocolManager();
error AddressBookCooldownActive(address currentAddressBook, uint256 cooldownEndsAt, uint256 secondsLeft);

library VaultCoreNftFactoryTypes {}
