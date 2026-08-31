# Allbridge Phantom CCTP Deposit — Case Study (Aug 19, 2026, ~$190K, Base)

**Lesson:** An attested cross-chain message is NOT proof that value moved. The destination
contract treated "Circle signed this message" as "USDC arrived" — and paid out.

## The mechanism (verified on-chain)

1. **Jul 26 (24 days before):** attacker called Circle's `MessageTransmitterV2.sendMessage`
   on Polygon with a forged CCTP-style message declaring a 1,000,000 USDC transfer —
   **no USDC was burned**. Circle's attestation service signed it anyway: attestation
   proves the message is well-formed and signed, not that the transfer happened.
2. **Aug 19 01:47:** a REAL CCTP deposit minted ~191,112 USDC to Allbridge's Base router.
3. **6 seconds later:** attacker redeemed the forged message. Allbridge's
   `CCTPTokenMessenger.receiveCctpMessage` lacked:
   - a check that message `sender` == the remote TokenMessenger, and
   - a check that `recipient` == Circle's TokenMessengerV2 (the contract that mints).
   The forged message's `recipient` was the attacker's own contract, which returned
   success without minting. The messenger credited `receivedMessages[messageHash] = 1,000,000`.
4. Router `receiveToken` recomputed the hash from caller-supplied params, checked
   `receivedTokenAmount(messageHash) > 0` — **the only solvency test** — and paid out.
5. Attacker flash-loaned 808,844 USDC from Aave to top the router's balance up to the
   declared figure, withdrew ~999,000 USDC (0.1% fee), repaid the loan.
   **Net: ~189,752 USDC.** The loss was mostly the real user's in-flight deposit.

## Root cause

`_calculateMessageHash` is a pure `keccak256` over **caller-supplied** values → attacker
precomputed the hash offline, embedded it in `hookData`, had Circle sign it. The router
never checked the messenger's credit corresponded to an actual mint or balance increase.

## Receipts (verified via base.blockscout.com)

- Attack tx: `0x9f906fcd8fceaa6745e8d1c004861dcfa9b5e6a893fe1e8c5d0013a4e982e6a8`
  (block 50157345) — **to harness `0xb6fBDFA5F3CBEB139D4ccE86D92F4ac8687B16c0`**
  (deployed 25 days earlier; drainer ran from initcode — never existed as a readable
  deployed contract before executing)
- Sender EOA: `0x2419432344b0B892E592b2601B98eaE702Ba360e` (EIP-7702 delegator)
- Router: `0xaA119F7442ecc28b9a8f236707ada8362cff24ff` ("Router", verified)
- Vulnerable messenger: `0xf9b710E427bf4d93598e0F80A84dE22C7Ad9b577` ("CCTPTokenMessenger")
- Forged message creation (Polygon): `0x2a88d79756b4547b33fea7b3c1420793680e2b8952bef4c65e99879e16b22140`
- Copycat: `0xf33f35046afd68ed900a3c7fbd9a1828d2464da0` reproduced within 25 min,
  twice more (1,000 + 1 USDC). **Public exploit → reproduced in <30 min.**
- Same bytecode deployed on Polygon + Arbitrum (closed, not exploited); fix = credit
  only on observed balance change, or require `message[76:108]` == TokenMessengerV2.

## Checklist additions

1. **What is the "deposit received" truth?** Balance delta across the message call?
   Actual mint? Or a number written by the messenger? If the latter → forged-able.
2. **Message sender/recipient binding**: the destination contract must verify the
   message's `sender` == the KNOWN remote messenger and `recipient` == the KNOWN
   minting contract. Attacker-controlled recipient = free callback that "confirms".
3. **Attestation ≠ settlement**: Circle/chain attestation proves well-formedness, not
   value movement. Any bridge crediting on attestation alone is paying against air.
4. **initcode drainers**: an exploit that runs from creation code never exists as a
   readable contract before it executes — monitoring must catch the tx, not the contract.
5. **Flash-loan top-up**: a solvency check on "router balance ≥ claim" is meaningless
   when the attacker can flash-loan the difference in the same tx.
