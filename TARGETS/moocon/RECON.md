# MOOCON — Phase 0 Recon (Solana, no-loss lottery on Jupiter Lend)

**Status:** 🟡 In progress — Phase 0 (recon) + 0.5 (TMAAR) done. Phase 1 (code read) blocked on
no public source / no IDL; substituted with BPF string-extraction recon (see Method below).
**Date:** 2026-09-09
**Program ID:** `mooxHpyFXFemZDNmGQE8KxW93aK8eRVG51nbsK2H52v` (Solana mainnet-beta)
**Program data account:** `8wrmT7eEiqMTGV8wksQWpSAW1948fK5UB6cQBbyx1ViH` (848,749 bytes)
**Upgrade authority:** `JsvR5eLkPzfJ3TqiumoowRTco1m5qf21V5NCWn9H5UR` — single EOA, no multisig/timelock observed
**Verified on Solscan:** No. No `security.txt`. No IDL published on-chain (checked the standard
Anchor IDL PDA — empty).
**Website:** moocon.xyz / app.moocon.xyz — **Twitter:** [@moocon_](https://x.com/moocon_) (joined July 2026,
81 followers, small/solo builder `@Sn13zka` via MagicBlock's "Forge Builder Program")
**TVL:** ~$14K (SOL + JupUSD deposits), live money, real users

## What it is (from public marketing + on-chain behavior)

"No-loss lottery" — user deposits SOL or JupUSD, funds are supplied to **Jupiter Lend** for yield,
and the accumulated yield (not principal) is periodically awarded to one depositor via a
"verifiable draw." Principal is claimed to always be withdrawable. Currently advertising
**1061% APY on JupUSD** (worth independently sanity-checking — anomalously high pooled-prize
"APY" is often a symptom of a prize-accounting or exchange-rate bug, not real yield).

## Method — reversing a closed-source program

No verified source, no GitHub repo for the on-chain program (only DefiLlama's TVL-reader
adapter is public), no on-chain Anchor IDL account. To build a surface map without source:

1. Pulled the program's executable data account (848KB) directly via RPC (`getAccountInfo` on
   the `programData` address from the upgradeable-loader program account).
2. Extracted printable ASCII runs (custom script — Windows environment has no `strings` binary)
   to recover **every Anchor discriminator name, account name, and `require!()`/error string**
   compiled into the binary. Anchor/Borsh embed these as literals, so this is a complete and
   accurate instruction/account/error surface even without the source — just not the control
   flow or exact line-level logic.
3. Cross-referenced against ~20 real recent transactions (`getSignaturesForAddress` +
   `getTransaction`) to see which instructions actually fire, in what order, and by whom.

Evidence saved: `/tmp` scratch scripts used are `fetch_idl.js`, `dump_elf.js`, `inspect3.js`,
`strings.js`, output `moocon_strings.txt` (transient scratchpad — re-derivable from the program
ID any time; not checked into the repo since it's a 850KB raw binary dump).

## Full instruction surface (from binary + on-chain observation)

Admin/setup:
`Initialize`, `InitializeVault`, `SetVrfAuthority`, `SetNewActivityPaused`, `SetWithdrawFee`,
`SetDistributionTierIntervals`, `SyncRate`, `CollectFee`, `UnfreezeCommitment`

Round/authority (keeper-only, judging by folder path `instructions/authority/`):
`Commit`, `DelegateRewardResult`, `RequestRandomness`, `ConsumeRandomness`,
`UndelegateRewardResult`, `Reveal`, `Harvest`

User-facing:
`Deposit`, `Withdraw`, `Claim`

MagicBlock Ephemeral Rollups delegation framework (standard, not moocon-specific):
`ProcessUndelegation` + the `Idl*` Anchor stub instructions

## Observed live keeper loop (single hot wallet)

Every ~35-55 minutes, wallet `H9Q6c1RYvoQ64QdQcbnQJFrTEsdH3ojR4jvMxTQFm83L` fires a fixed
3-instruction sequence against the program, confirmed from 20 consecutive real transactions:

```
Reveal → ProcessUndelegation → Commit
```

(Solscan's own instruction-name decoding is wrong/generic for this program — it showed
`mintTo` / `commit_state` / `update_rate`; the real on-chain logs say `Reveal`,
`ProcessUndelegation`, `Commit`. Always verify against raw `getTransaction` logs, not a
block-explorer's guessed labels.)

**No other signer has triggered these three instructions in the sample.** This is a single
keeper key running the entire reveal → undelegate → commit pipeline for every round.

## Architecture inferred from account names + error strings

- **Jupiter Lend integration** — accounts `lending`, `lending_admin`, `f_token_mint`,
  `supply_token_reserves_liquidity`, `lending_supply_position_on_liquidity`, `rate_model`,
  `lending_vault`, `liquidity`, `liquidity_program`, `lending_program`; error `"CPI to Jup
  program failed"`. Vault deposits are CPI'd into Jupiter's lending market for yield.
- **Dual randomness surface** — TWO distinct randomness mechanisms visible:
  1. An oracle/VRF path: `vrf_authority`, `oracle_queue`, `vrf_program`, `slot_hashes`
     accounts, admin-settable via `SetVrfAuthority`.
  2. A commit-reveal path: error `"Secret seed does not match committed hash"`, account
     `commitment`, instructions `Commit` / `Reveal`, `"Invalid slot for this reward
     commitment"`.
- **Ticket-range / merkle winner selection** — `"Invalid merkle proof"`, `"Ticket range count
  must be greater than zero"`, `"Ticket range extends past total_tickets"`, `"Winner index
  falls outside the submitted ticket range"`, `"Computed winner index does not match the
  expected index"`, `"Ticket supply does not match mint supply"`. Winner is determined by a
  random index into a ticket range, proven against depositors via merkle proof — a pattern
  that lives or dies on **when** the merkle root locks relative to when the random index is
  known.
- **MagicBlock Ephemeral Rollups** — `delegation_program`, `delegation_record_request`,
  `delegation_metadata_request`, `owner_program`, `magic_program`, `magic_context`,
  `undelegate-buffer` seeds. Confirms the tweet ("@magicblock Forge Builder Program"): reward
  state is delegated into an ephemeral rollup, ticked there, then undelegated + committed back
  to Solana L1 by the keeper. Enforced ordering exists: `"Reward result delegation must
  immediately follow its commit"` — a real defensive check against front-running the
  delegation window, worth noting as a positive.
- **High-water-mark exchange rate guard** — `"Exchange rate dropped below the vault high-water
  mark"`, `"Exchange rate already synced"` / `"not synced yet"` — looks like a defense against
  a donation/inflation-style attack on the share price, similar in spirit to ERC-4626
  first-depositor protections. Needs confirmation of what triggers `SyncRate` and who can call
  it (folder says `admin/sync_rate.rs` — admin-only).
- **Token-2022 defenses present** — `"Active Token-2022 transfer fees are not supported"`,
  `"...transfer hooks are not supported"`, `"...unsupported extension"` — good sign, shows the
  dev thought about fee-on-transfer/hook tokens.
- Source file paths recovered (Cargo build path embedded in panic strings) confirm the crate
  is literally named `moocon-vaults`:
  `programs/moocon-vaults/src/{lib.rs, math.rs, merkle.rs, cpi/exchange_rate.rs,
  token_validation.rs, events.rs, state/vault.rs, instructions/{admin,authority,user,payout}/*.rs}`

## Confirmed on-chain fact (not a hypothesis — direct account read, Anchor-discriminator-verified)

Pulled the 3 accounts currently owned by the program directly (`getProgramAccounts`), decoded
raw bytes, and identified the account TYPE by brute-forcing candidate struct names against
Anchor's discriminator formula (`sha256("account:<Name>")[..8]`) until they matched — this
confirms account identity with certainty, not guesswork:

- `CAGLvoMYP1XTyLdJzceAWW7coqW7MzQbFFiJ5yKEcHBZ` (80 bytes) — discriminator matches
  **`account:State`** exactly. This is the program's single global config/state account (not a
  per-round reward record as first assumed — corrected from the initial pass).
  - bytes `[8:40]` = `JsvR5eLkPzfJ3TqiumoowRTco1m5qf21V5NCWn9H5UR` — the program's **upgrade
    authority**, byte-for-byte. Almost certainly the `State.authority`/admin field (first field
    after the discriminator is the conventional Anchor layout for an admin pubkey).
  - bytes `[40:72]` = `H9Q6c1RYvoQ64QdQcbnQJFrTEsdH3ojR4jvMxTQFm83L` — the keeper bot wallet
    that fires `Reveal`/`ProcessUndelegation`/`Commit`. Distinct key from the admin — **not**
    the same EOA (correcting the earlier draft of this doc, which read the two adjacent 32-byte
    fields as one match and overstated this as a single identical key. They are two different
    keys.)
- `7Cb6CFeh6etzsEY46Wq7LEjFTRmnuYUQa6T1e5ez2STt` / `He8zmi8tVbDJxeH8th8bNH6pdz9k1DksBoVEowcHhw8a`
  (296 bytes each) — discriminator matches **`account:Vault`**. Two Vault accounts = one per
  asset (SOL, JupUSD), as expected. Byte `[72:104]` of the first one = `GwnavJALxWXSvS4XXXETsaAgFkuVbrrZpFTsPFf1i8ym` — matches the mint seen in the sampled `Reveal`
  transaction (almost certainly `p_mint`, the prize/ticket mint for that vault).

**Corrected finding:** the admin/upgrade-authority key and the keeper/round-execution key are
**two separate EOAs**, not one identical key as the first draft of this doc claimed — that was
wrong and has been fixed. What IS still true and still worth flagging: `SetVrfAuthority` is a
confirmed admin-only instruction (per the extracted instruction list), meaning the admin key can
almost certainly repoint that second `State` field to any keypair it wants, at any time, with no
timelock observed on either the program upgrade path or this setter. So while the *current*
keeper is a distinct key, **ultimate control of "who gets to reveal/commit rounds" still
collapses to the single admin EOA** — it's one hop away (a `SetVrfAuthority` call) rather than
already identical. That's a real but smaller claim than the original draft made, and the
correction matters (RULES.md #3 — never inflate).

**Why this still matters against the "verifiable draw" claim (moocon.xyz marketing copy):** a
draw's verifiability rests on nobody being able to unilaterally control both the code and who
computes randomness. Here: one EOA can (a) upgrade the program's `reveal`/`consume_randomness`/
`commit` logic at any time, and (b) reassign the round-authority key via `SetVrfAuthority` at
any time. Both levers exist, neither is timelocked as far as observed. Whether this rises to a
formally reportable finding (vs. a documented TMAAR risk) depends on confirming there's truly no
timelock on `SetVrfAuthority` specifically — worth a targeted decompile of that one instruction
before writing it up as a finding, rather than the whole program.

## Attack-surface hypotheses (NOT yet findings — no fork PoC, per RULES.md #2)

These are leads from the Feynman/Inversion pass on the reconstructed surface. Ranked by how
much they contradict the "verifiable draw" / "no-loss" marketing claims specifically, since
that's the trust-minimization angle RULES.md #6 asks for before an admin-power observation
counts as reportable:

**Corroborating check (string-absence, not proof):** re-scanned the full extracted string list
for any timelock/two-step/deadline vocabulary. Zero hits for `pending`, `propose`, `timelock`,
`delay`, `two-step`, `cooldown`, `grace` (admin-setter timelock terms) AND zero hits for
`deadline`, `expire`, `expiry`, `forfeit`, `grace_period`, `permissionless`, `crank`, `timeout`
(reveal-deadline / permissionless-fallback terms). Idiomatic Anchor code almost always ships a
distinct `require!()` error string for a timelock or deadline check, so a genuine absence of ALL
of these across the entire binary is meaningful signal — not conclusive (a check could exist
using only a generic/reused error), but it lines up with hypotheses #1 and #2 below rather than
against them.

1. **`SetVrfAuthority` is an admin-only setter with (so far) no timelock/multisig evidence.**
   If the admin can repoint VRF authority to a keypair they control, "verifiable draw" is not
   actually verifiable — the admin can supply randomness of their choosing. Need: (a) confirm
   admin key == upgrade authority `JsvR5e...` or a separate key, (b) check for any on-chain
   commitment (VRF pubkey pinned at `InitializeVault` and never changeable) vs. a freely
   mutable setter, (c) check whether the "commit-reveal secret seed" path is the actual
   randomness source for winner selection (in which case `SetVrfAuthority` might gate something
   less central) or is central to it.
2. **Reveal/Commit pipeline has one signer with no observed permissionless fallback**
   (see string-absence corroboration above — no `deadline`/`crank`/`permissionless`/`timeout`
   vocabulary found anywhere in the binary). If the
   keeper is the only party who can call `Reveal`/`ConsumeRandomness`/`Commit`, and there's no
   deadline-triggered permissionless path or slashing for a keeper who simply never reveals an
   unfavorable round, this opens a "look-then-abort" grief: request randomness, peek at what it
   would produce (e.g. via simulation before submitting), and only submit `Reveal` when the
   outcome doesn't cost the keeper/house. Need: check `RequestRandomness`/`ConsumeRandomness`
   ordering — is the commitment made (hash pinned on-chain) BEFORE the value that determines the
   outcome is knowable to the keeper? Standard commit-reveal is only safe if the committer can't
   selectively withhold reveals — verify there's a deadline + forfeiture/permissionless-resolve
   path.
3. **Merkle-root timing vs. randomness reveal order.** If whoever builds the ticket-range merkle
   tree (looks admin/keeper-side, no evidence of on-chain enforcement that ranges match actual
   deposit records) can submit/adjust the root AFTER the winning index is already fixed by
   `Reveal`, that's a direct "pick the winner" bug. Need the actual call-order constraint from
   decompiled logic — string extraction alone can't confirm this, it only tells us the checks
   exist (`"Winner index falls outside the submitted ticket range"`,
   `"Computed winner index does not match the expected index"`), not their sequencing.
4. **1061% APY claim.** Given the high-water-mark / sync-rate guard machinery visible, worth
   independently computing whether the advertised rate is consistent with real Jupiter Lend
   JupUSD yield, or whether it's inflated by a exchange-rate/rounding bug in `sync_rate.rs` /
   `cpi/exchange_rate.rs`. A wrong "up" rounding direction on `SyncRate` would show up exactly
   as "impossibly high APY."
5. **`UnfreezeCommitment`** exists as an admin instruction — worth understanding what state it
   reverses. If it lets admin undo a committed-but-inconvenient round, similar concern to #2.

## What's needed to move from hypothesis → finding

Per RULES.md #2, none of the above is reportable yet. Next steps (depth — 𝖲𝖠𝖵𝖠𝖦𝖤's side, or a
follow-up session with more budget for real decompilation):
- Full BPF disassembly (via a SBF decompiler, e.g. Ghidra + Solana loader, or Dedaub if it
  supports SBF) of the `authority/reveal.rs`, `authority/commit.rs`, `authority/
  request_randomness.rs`, `authority/consume_randomness.rs`, and `merkle.rs` logic paths, to
  confirm actual call-order enforcement, not just the existence of the checks.
- Pull the live `state`/`vault` PDA account data and decode it (once discriminators are known
  from the extracted strings) to read the current admin pubkey, VRF authority pubkey, and
  round/commitment state directly — confirms/refutes hypothesis #1 without any disassembly.
- `solana-test-validator` fork (Solana's anvil-equivalent) cloning the program + its state
  accounts, to actually attempt request→simulate→selective-reveal on a copy. **RULES.md #1 still
  applies — test on a local validator clone, never mainnet.**
- Contact `@moocon_` / `@Sn13zka` for source access before going further — reachable via
  Twitter DM per the target filter's "reachable team" criterion; a friendly source request is
  cheaper than blind SBF decompilation and may resolve #1 and #3 immediately.
