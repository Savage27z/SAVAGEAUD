# 0xFlorent Puzzle — Bug Classes Case Study (Aug 31, 2026)

Source: AcayDr's public audit thread (x.com/acaydr/status/2094311445773377863, full
note via fxtwitter) + our own on-chain verification (source pulled from eth.blockscout.com).

**Context:** 0xFlorent (white-hat who returned 1,003.62 ETH from a 2016 ICO contract
to 48 investors) deployed an 11-contract on-chain puzzle collection on Ethereum and
publicly invited exploitation. AcayDr audited it: **19 findings, 3 high severity**
(v12.sh/runs/7245). We verified the two main contracts ourselves.

## The bug classes (verified in source)

### 1. Integer-division price formula — "the price never rises" (High)
Fork.sol:
```solidity
constructor(address steward_, IArt art_, address vault_, uint256 start) {
    vault = vault_;
    price = start;                    // ← NO validation
}
function mint() external payable returns (uint256 id) {
    uint256 p = price;
    require(msg.value >= p, "underpaid");
    id = ++minted;
    _mint(msg.sender, id);
    price = p * 11 / 10;              // ← x1.1 via integer division
    _sold(p);
    _pay(vault, p);
    if (msg.value > p) _pay(msg.sender, msg.value - p);
}
```
- `p * 11 / 10` for p in 0..9 wei: `0→0`, `1→1`, ..., `9→9` — price NEVER rises.
- start=0 → `require(msg.value >= 0)` always passes → **free editions forever**.
- start=1..9 → unlimited editions at dust cost.
- Editions are the collection's governance weight → **full voting control for free**.
- **Verification:** live Fork has `price() = 0.011 ETH` (started 0.01, 1 mint) — the
  deployed instance dodges the bug; it remains a class-level bug for any contract
  deployed with start < 10 wei.

### 2. Reentrancy despite perfect CEI — broken state makes the guard worthless (High)
Same `mint()`: `price = p * 11 / 10` runs BEFORE `_pay(vault, p)`, and `_pay` forwards
all gas to the vault. CEI is followed correctly — but with price frozen (bug 1), a
malicious vault contract can reenter `mint()` paying the same 0/dust amount it just
received, minting a new edition each recursion, looping until gas runs out:
**one payment, unlimited mints.** The defense (fresh state) was only sound because the
state was expected to change.

### 3. Overpayment refund — traced, dead end (verified by AcayDr opcode-by-opcode)
`if (msg.value > p) _pay(msg.sender, msg.value - p)` — the new price is written to
storage BEFORE the refund call, so a nested mint always pays the higher price. No
discount loop exists. (Good example of checking the false lead.)

### 4. Unvalidated immutable renderer (Medium-ish)
Metadata renderer address is immutable and never checked — zero address / EOA /
reverting contract all pass deployment → `tokenURI()` breaks for the whole collection
permanently, no fallback.

### 5. Raw string-concat JSON metadata (Low)
On-chain JSON built with concatenation, no escaping/URI encoding — embedded SVG double
quotes terminate the JSON string; raw `#` in colors breaks URI parsing → indexers reject
tokens.

### 6. ERC721 interface misdeclaration (Medium-ish)
Skips receiver check on safe transfers and lacks the 4-arg `safeTransferFrom` while
advertising the interface → editions stranded in non-receiver contracts forever.

### 7. Volume accounting lies (Low)
Secondary sales don't touch the volume counter but governance gates depend on total
volume.

## The Vault (sealed pool) — verified

```solidity
bytes32 public immutable SEAL;   // keccak256(secret); secret held OFF-CHAIN by steward
function unlock(bytes calldata secret, address payable to) external {
    require(!found, "found");
    require(keccak256(secret) == SEAL, "wrong key");  // caller picks ANY destination
    found = true;
    (bool ok,) = to.call{value: address(this).balance}("");
    ...
}
```
- Prize: **0.21 ETH (~$510)** at verification time, growing (Fork mints + Lineage
  increments flow in).
- `rules()`: "one of a set. read the hands that fill it." — the hint is that the secret
  is one of a set, discoverable from the vault's funders ("hands").
- AcayDr brute-forced ~2,500 candidates, no match. The preimage is off-chain; on-chain
  brute force is a guessing game unless the set is discovered.

## Receipts
- Vault: `0x0596702ae60a2b27593a89f2e69855817e1f2cc2` (0.21 ETH, SEAL immutable)
- Fork: `0x4f33e5aa6d6c83e0bd32887b3a65a6d26e28b57b` (price 0.011 ETH, minted 1)
- Art registry: `0xa01a0386b0fb47296c52d5d2492fbe01bfda85b8`
- AcayDr methodology worth copying: headless-browser source pull when Etherscan API is
  dead + **Python EVM disassembler bytecode-vs-source comparison** (caught a PUSH0
  misread — the "audit code that runs on chain, not code that claims to" discipline).

## Checklist additions
1. **Integer-division price/curve formulas**: any `x * k / d` where small inputs make
   the delta vanish — validate the START/initial value in the constructor (0..d-1
   ranges). Especially when the price feeds payment requirements or governance weight.
2. **CEI is not enough if the state update is a no-op**: reentrancy guards rely on the
   fresh state actually changing. If a bug makes the update idempotent (price stays
   same), a "safe" CEI order is exploitable. Chain bugs together — check whether bug A
   defeats the guard for bug B.
3. **Interface honesty**: don't inherit/declare ERC721 metadata + safe-transfer support
   without implementing the checks; check `supportsInterface` vs actual behavior.
4. **Constructor param validation**: `start`, fee rates, decimals, addresses — anything
   user-configurable at deploy must be range-checked.
5. **Sealed-pool vaults**: `unlock(secret, to)` — caller-chosen destination + off-chain
   secret = the prize is only as safe as the secret's discoverability. "Read the hands
   that fill it" = funder analysis is the clue trail for such puzzles.
