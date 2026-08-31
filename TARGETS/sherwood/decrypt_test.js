// Definitive decrypt test: bundle-exact key derivation + note layout.
// key = bytes(keccak256(arrayify(sig))); layout = IV(12) || TAG(16) || CT
const BASE = "https://sherwood.cash";
const SIG = "0x3d2e877eebbbb5abce5135c978c3694d773d6b30b2607413f5d9f570b5b95b3027b5ef761ff949f3c284618367aed36bea55e53d637207babbbb2d66182f50c81c";

function keccak256(bytes) {
  // use node crypto's keccak via createHash if available, else subtle
  const { createHash } = require("crypto");
  return createHash("sha3-256").update(bytes).digest(); // WRONG — keccak != sha3. See below.
}
