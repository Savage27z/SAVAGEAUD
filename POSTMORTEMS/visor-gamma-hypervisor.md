# Visor/Gamma Hypervisor — 10.7 ETH Spot-Price Minting Asymmetry (Aug 31, 2026, Ethereum)

**Lesson:** Minting priced at spot while redemption is priced at proportional real
tokens = a free drain whenever the spot price can be moved (flash loan). Two legacy
Visor/Gamma FLOAT-ETH Hypervisor vaults hit for ~10.7 ETH.

## The mechanism (ExVul)

- `deposit()` mints LP shares off the Uniswap V3 pool's **INSTANTANEOUS spot price**
  (`currentTick()`/`slot0`) — **no TWAP, no spot-vs-oracle deviation check**.
- `withdraw()` redeems shares for a **proportional slice of the real underlying
  tokens**.
- **Minting is spot-priced; redemption is not.** Flash-loan the spot price one way →
  deposit at the inflated/deflated spot (cheap shares) → withdraw the proportional
  real tokens (full value) → net drain. Deposits are permissionless (whitelist
  disabled).

## Receipts
- Attacker: `0xaea29218262dc6b0904ca077f6527c49dfd426d9`
- Contract: `0x05303c95ee7ff76daf1421b28e024635d7fe51ab`
- Vaults: `0x85cbed52…a8a70c`, `0xc86b1e7f…c1153`
- Tx: `0x3d7549db65344da2a41067e17791b17fac16ec6b8e5132e82e243f6541de5cff` (block 25874402, 2026-08-31)

## Checklist additions (share-pricing asymmetry)

1. **What prices the mint vs what prices the redeem?** If deposit uses spot/tick and
   withdraw uses proportional real tokens (or TWAP), the asymmetry is exploitable.
   Both sides must use the same price basis, or spot must be deviation-checked.
2. **`currentTick()`/`slot0` as a pricing basis** — never without TWAP or a deviation
   check; it's manipulable in one swap.
3. **Legacy hypervisor/strategy vaults** (Visor, Gamma, etc.) with permissionless
   deposits = prime targets: old code, real assets, no TWAP.
4. Same family as first-depositor inflation: any deposit path where share price can be
   skewed before a deposit lands.
