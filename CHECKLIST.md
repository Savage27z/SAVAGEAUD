# Vulnerability Checklist

Systematic checklist to run against every target. Check off each item and link findings.
Use Claudit (MCP) to search Solodit's 20k+ findings for similar patterns.

## Access Control
- [ ] `onlyOwner` / `onlyRole` on every sensitive function
- [ ] Initializers protected against re-call (upgradeable contracts)
- [ ] Role assignment is itself protected
- [ ] No functions that assume an internal caller without enforcement
- [ ] Emergency functions (pause, panic) — who can call? Can they unpause/unpanic?
- [ ] Timelocks — can they be bypassed? Is the delay meaningful?
- [ ] Self-destruct or delegatecall — any rug vectors?

## Reentrancy
- [ ] CEI pattern in every state-changing function
- [ ] Cross-function reentrancy (two functions share state, one makes external call)
- [ ] Cross-contract reentrancy (shared state across two contracts)
- [ ] Read-only reentrancy (view function returns manipulated state)
- [ ] `nonReentrant` modifier on all user-facing entry points
- [ ] Emergency exits (pause/panic) — do they properly halt reentrant flows?
- [ ] Callback tokens (ERC-777, ERC-1155 hooks, Uniswap V3 callbacks)

## Accounting & Share Math
- [ ] Rounding direction — always check favorability
- [ ] First-depositor / share inflation attacks
- [ ] Donation attacks (donate to inflate PPS)
- [ ] Division before multiplication (precision loss)
- [ ] Fees — taken from yield or principal? Can fees be inflated?
- [ ] Cumulative rounding loss over many transactions
- [ ] Share price calculation — what's in the numerator and denominator?

## Price & Oracle
- [ ] Spot price usage — any manipulation protection?
- [ ] TWAP window — long enough? Minimum enforced?
- [ ] Calmness checks — what defines calm? Can it be manipulated?
- [ ] Oracle fallback — what if primary oracle fails?
- [ ] Single point of failure (one price source)
- [ ] Price deviation tolerance — too wide?

## Economic
- [ ] MEV exposure — slippage, deadlines, sandwich protection
- [ ] Front-running — is there a predictable state change?
- [ ] Griefing — can one user prevent others from using the protocol?
- [ ] Flash loan attack surface — can a flash loan move the state?
- [ ] Rebalancing — can keeper extract value?
- [ ] Deposit/withdraw race conditions — can someone jump ahead of you?

## External Calls & Integrations
- [ ] Unchecked return values from external calls
- [ ] Arbitrary call targets — unbounded external calls
- [ ] Fee-on-transfer tokens — balance assumptions
- [ ] Rebasing tokens — balance assumptions
- [ ] ERC-777 / callback tokens — reentrancy via token hooks
- [ ] Infinite approvals / standing approvals to external contracts
- [ ] Delegatecall — storage collision risk

## Upgrades & Proxies
- [ ] Storage layout compatibility (upgradeable contracts)
- [ ] Initializer protection (OpenZeppelin initializer modifier)
- [ ] Proxy admin — who controls it? Can they rug?
- [ ] Timelock on upgrades — delay meaningful?
- [ ] Beacon / UUPS — different upgrade paths, different risks

## Gas & Optimization (bonus)
- [ ] Unbounded loops (DoS)
- [ ] Redundant storage reads
- [ ] Inefficient data structures
- [ ] Unnecessary external calls

## Target-Specific
- [ ] DEX: AMM math, price impact, impermanent loss accounting
- [ ] Lending: Liquidation logic, LTV calculations, oracle usage
- [ ] Vault: Share accounting, harvest/compound, keeper rebalancing
- [ ] Bridge: Message verification, relayer trust assumptions
- [ ] Yield Aggregator: Strategy swaps, fee-on-transfer tokens, harvest math
