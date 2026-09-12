#!/usr/bin/env python3
"""v2: weighted-scoring cluster of Shieldify finding titles (replaces first-match).
Each family contributes a score per matched keyword; argmax wins. Multi-word / specific
phrases score higher than generic single words, so one stray word can't hijack a title."""
import json, re, os
from collections import Counter, defaultdict

R = json.load(open(os.path.expanduser('~/.hermes/workspace/study/shieldify-findings.json')))

# (family, [(pattern, weight), ...])
FAM = [
 ('Signature / replay / nonce / EIP-712', [
   (r'eip-?712', 3), (r'domain separator', 3), (r'signature', 3), (r'replay', 3),
   (r'nonce', 2), (r'permit\b', 2), (r'signer', 2), (r'signed (?:message|data|tx)', 3),
   (r'ecdsa|ecrecover', 3), (r'merkle (?:proof|tree|root)', 3), (r'malleab', 2)]),
 ('Access control / missing authorization', [
   (r'unauthoriz', 3), (r'access control', 3), (r'only ?owner', 3), (r'ownership', 2),
   (r'arbitrary (?:caller|user|address)', 2), (r'anyone can', 2), (r'no permission', 3),
   (r'privileg', 2), (r'role\b', 2), (r'not restricted|unrestricted', 2),
   (r'missing.*(?:auth|owner|role|permission)', 3), (r'admin\b', 1), (r'centraliz', 2)]),
 ('Reentrancy / callback abuse', [
   (r'reentran|re-entran', 4), (r'callback', 2), (r'malicious (?:contract|token|user)', 2),
   (r'cross-function|cross-contract', 2), (r'external call.*(?:state|before)', 2)]),
 ('Oracle / price manipulation / TWAP', [
   (r'oracle', 3), (r'twap', 3), (r'price manipulat', 4), (r'spot price', 4),
   (r'slot0|sqrtprice', 3), (r'price feed', 3), (r'chainlink', 2), (r'stale price', 3),
   (r'deviation', 2), (r'manipulat\w* (?:price|pool|tick|rate)', 4), (r'\bgetprice', 2),
   (r'market cap', 2), (r'price\b', 1)]),
 ('Slippage / MEV / front-run / deadline', [
   (r'slippage', 3), (r'min(?:imum)? ?(?:out|amount|received|returned)', 2),
   (r'front-?run', 3), (r'sandwich', 3), (r'\bmev\b', 3), (r'deadline', 2),
   (r'price impact', 2), (r'back-?run', 2), (r'jit\b', 2), (r'no (?:min|slippage)', 3)]),
 ('Rounding / precision / decimals / arithmetic', [
   (r'round(?:ing|s)?\b', 3), (r'precision', 3), (r'decimal', 3), (r'truncat', 3),
   (r'overflow', 3), (r'underflow', 3), (r'scaling|scale\b', 2), (r'downcast|type cast', 2),
   (r'1e\d+', 2), (r'divisio', 2), (r'loss of (?:funds|precision|value)', 1),
   (r'incorrect (?:math|calculation|arithmetic)', 3), (r'unit (?:mismatch|conversion)', 3)]),
 ('Reward / share / points accrual accounting', [
   (r'reward', 3), (r'incentive', 2), (r'accru', 3), (r'claim', 2), (r'stake|staking', 2),
   (r'points?\b', 2), (r'emission', 3), (r'per-share|pershare', 3), (r'reward debt', 4),
   (r'distribut', 1), (r'yield (?:distribution|calc)', 2), (r'interest (?:accru|calc)', 2),
   (r'unstake', 2), (r'vesting|vest\b', 2)]),
 ('Share price / inflation / first-depositor / donation', [
   (r'(?:first|initial|early) deposit', 4), (r'inflation attack', 4), (r'donat', 3),
   (r'share price', 3), (r'exchange rate', 3), (r'erc-?4626', 2), (r'convertto', 2),
   (r'virtual share', 3), (r'empty vault', 3), (r'initial share', 3), (r'preview', 2),
   (r'round-?trip|roundtrip', 2), (r'share(?:s)? (?:accounting|calculation|price)', 3)]),
 ('Funds locked / stuck / DoS / griefing', [
   (r'lock(?:ed|ing|s)?\b', 3), (r'stuck', 3), (r'permanent', 3), (r'unrecoverable', 3),
   (r'\bdos\b|denial of service', 3), (r'grief', 3), (r'freez|frozen', 3), (r'brick', 3),
   (r'cannot (?:withdraw|claim|be|retrieve)', 2), (r'insolven', 2), (r'stuck funds', 4),
   (r'unclaimable', 3), (r'should be recoverable', 2), (r'dead ?lock', 3), (r'trap', 2)]),
 ('Missing input validation / unbounded params', [
   (r'missing (?:input |param\w* |config\w* |value |check|validation|verification)', 3),
   (r'not validated|unvalidated', 3), (r'unchecked|without (?:checking|validation)', 3),
   (r'zero address', 3), (r'no (?:upper|lower) bound', 3), (r'bound\w* (?:check|missing)', 3),
   (r'sanitiz', 2), (r'misconfigur', 3), (r'wrong (?:config|param|address|token)', 2),
   (r'does not (?:verify|validate|check|ensure)', 2), (r'improper (?:input|param|validation)', 3),
   (r'unrevoked|not revoked', 3), (r'setter', 2), (r'constructor', 2),
   (r'incorrect (?:config|param|initialization)', 3), (r'arbitrary (?:token|input|address)', 2)]),
 ('Token standard edge cases (FoT / rebasing / blacklist / decimals)', [
   (r'fee-?on-?transfer', 4), (r'rebas', 3), (r'blacklist', 3), (r'non-standard (?:erc|token)', 3),
   (r'weird erc', 3), (r'erc-?20', 2), (r'reverting token', 3), (r'usdt|usdc', 2),
   (r'token (?:extension|program)', 2), (r'freeze (?:authority|account)', 2),
   (r'decimals', 2), (r'token (?:with|having|that) ', 2), (r'hook', 1)]),
 ('Upgradeability / proxy / initializer / storage', [
   (r'\bproxy\b', 3), (r'upgrad', 3), (r'initiali[sz]', 3), (r'storage (?:collision|layout|slot|gap)', 4),
   (r'delegatecall', 3), (r'implementation', 2), (r'uups|transparent|beacon', 3),
   (r'reinitializ|re-initializ', 3), (r'uninitializ', 3), (r'immutable.*upgrade', 2)]),
 ('External call / unchecked return / low-level call', [
   (r'unchecked (?:return|call|low|external)', 4), (r'return value', 3),
   (r'low-?level call', 3), (r'\.call\{|\.call\(', 3), (r'try/?catch', 3),
   (r'(?:failed|failing) (?:call|transfer|tx)', 2), (r'safe ?transfer|safetransfer', 2),
   (r'approve.*(?:race|front|infinite)', 3), (r'allowance', 2), (r'nonce.*reuse', 2),
   (r'send\b.*fail', 2), (r'ignore\w* (?:error|return)', 3), (r'\bccip\b|bridge|relayer', 2)]),
 ('Stale state / cache / sync / ordering', [
   (r'stale', 3), (r'cach(?:e|ed|ing)', 3), (r'not updated|out of (?:sync|date)', 3),
   (r'sync\w*', 2), (r'ordering|order of (?:operations|checks)', 3), (r'recompute|recalculat', 3),
   (r'inconsistent state', 3), (r'wrong (?:state|variable|value|amount|total|ledger|balance)', 2),
   (r'update\w* (?:before|after)', 2), (r'ledger', 2), (r'desync', 3), (r'does not update', 3)]),
 ('Fee / tax / commission calculation', [
   (r'\bfee\b', 2), (r'\btax\b', 3), (r'commission', 3), (r'royalt', 2),
   (r'performance fee|management fee', 3), (r'fee (?:calc|distrib|share|on|charged)', 3),
   (r'incentive fee', 3), (r'referral', 2), (r'spread', 2)]),
 ('Liquidation / bad debt / solvency', [
   (r'liquidat', 3), (r'bad debt', 4), (r'health (?:factor|check)', 3), (r'solvenc', 3),
   (r'collateral (?:check|value|ratio|factor)', 3), (r'seiz', 2), (r'undercollateral', 3),
   (r'bad debt|deficit', 3), (r'margin call', 2)]),
 ('Withdrawal / exit / queue / cooldown', [
   (r'withdraw', 2), (r'redeem', 2), (r'exit\b', 2), (r'redemption', 2),
   (r'queue', 2), (r'cooldown|cool-down', 3), (r'unbond', 2), (r'rage ?quit', 3),
   (r'escape hatch', 3), (r'queued', 2), (r'processing (?:time|delay)', 2)]),
 ('Pause / emergency / migration controls', [
   (r'pausab|pauser', 4), (r'pause\b|paused|unpause', 3), (r'emergency', 3),
   (r'migrat', 2), (r'shutdown|halt', 2), (r'circuit breaker', 3)]),
 ('Liquidity management / tick / position (AMM)', [
   (r'\btick', 3), (r'position', 2), (r'liquidity (?:add|remov|provision|manag|range)', 3),
   (r'concentrated', 2), (r'range (?:order|bound)', 3), (r'univ[234]\b|uniswap', 3),
   (r'\bamm\b', 3), (r'pool (?:creation|init|config|key|price)', 2), (r'rebalanc', 3),
   (r'sweep', 2), (r'\blp\b|liquidity provider', 2)]),
 ('Governance / voting / timelock', [
   (r'governance', 3), (r'voting|vote', 3), (r'quorum', 3), (r'proposal', 2),
   (r'timelock', 3), (r'veto', 2), (r'delegate\b(?!call)', 2)]),
 ('Auction / bidding / bonding curve', [
   (r'auction', 3), (r'\bbid', 3), (r'bonding curve', 3), (r'dutch', 2),
   (r'reserve price', 3), (r'bidding', 3), (r'curve (?:price|math)', 2)]),
 ('Event / log / return-value correctness', [
   (r'\bevent', 3), (r'\bemit', 3), (r'\blogs?\b|logging|log\b', 2),
   (r'returns? (?:wrong|invalid|incorrect)|incorrect (?:return|value returned)', 3),
   (r'view function', 2), (r'missing event', 4), (r'error (?:used|handling|message|type)', 2)]),
 ('Documentation / spec / comment mismatch', [
   (r'document\w*', 3), (r'comment', 3), (r'natspec', 3), (r'\bspec\b', 2),
   (r'readme|whitepaper', 3), (r'contradict', 3), (r'mislead', 2),
   (r'incorrect (?:comment|doc|description)', 4), (r'naming', 2), (r'mismatch(?:es)? with (?:the )?(?:doc|spec|comment)', 3)]),
 ('Gas / optimization / code quality', [
   (r'\bgas\b', 3), (r'optimiz', 3), (r'redundant', 3), (r'unnecessary', 3),
   (r'inefficien', 3), (r'code quality', 3), (r'best practice', 3), (r'simplif', 2),
   (r'immutable|constant\b', 2), (r'cheaper|cheaply', 2), (r'storage (?:read|write)s? can be', 2), (r'float|literal', 1)]),
 ('Randomness / VRF / RNG', [
   (r'random', 3), (r'\bvrf\b', 3), (r'\brng\b', 3), (r'entropy', 3), (r'seed\b', 2),
   (r'blockhash|block\.(?:hash|timestamp)', 2), (r'predictab', 3), (r'deterministic outcome', 3)]),
 ('Web2 / off-chain / content / API', [
   (r'spoof', 3), (r'\bxss\b|csrf|injection', 3), (r'api\b', 2), (r'frontend|backend|server', 2),
   (r'off-?chain', 2), (r'content\b', 2), (r'\burl\b|redirect', 2), (r'signature verific\w* server', 2), (r'error handling in param', 2)]),
]

def classify(title):
    t = title.lower()
    best, bestscore, hits = None, 0, []
    for famname, pats in FAM:
        s = 0; matched = []
        for rx, w in pats:
            if re.search(rx, t):
                s += w; matched.append(rx)
        if s > bestscore:
            best, bestscore, hits = famname, s, matched
    return best or 'UNCLASSIFIED', bestscore

fam = Counter(); fam_sev = defaultdict(Counter); examples = defaultdict(list); unmatched = []
for name, r in R.items():
    for f in r['findings']:
        k, sc = classify(f['title'])
        if k == 'UNCLASSIFIED':
            unmatched.append((name, f['id'], f['title']))
        fam[k] += 1; fam_sev[k][f['severity']] += 1
        if len(examples[k]) < 6:
            examples[k].append(f"[{name.replace('-Security-Review','')}] {f['title'][:88]}")

tot = sum(fam.values())
print(f"TOTAL {tot} | unclassified {len(unmatched)} ({100*len(unmatched)/tot:.1f}%)\n")
print(f"{'family':58s} {'n':>4s} {'CR':>3s} {'HI':>3s} {'MED':>4s} {'LOW':>4s} {'INF':>4s} {'CR+HI':>6s}")
for k, v in fam.most_common():
    s = fam_sev[k]; ch = s['critical'] + s['high']
    print(f"{k:58s} {v:4d} {s['critical']:3d} {s['high']:3d} {s['medium']:4d} {s['low']:4d} {s['info']:4d} {ch:6d}")
print("\n\n===== EXAMPLES =====")
for k, _ in fam.most_common():
    print(f"\n## {k} (n={fam[k]})")
    for e in examples[k]: print("   -", e)
print("\n\n===== UNCLASSIFIED (first 50) =====")
for u in unmatched[:50]: print("   -", u[0].replace('-Security-Review',''), u[1], '|', u[2][:95])
json.dump({'fam': dict(fam), 'fam_sev': {k: dict(v) for k, v in fam_sev.items()}, 'unmatched': unmatched},
          open(os.path.expanduser('~/.hermes/workspace/study/shieldify-clusters.json'), 'w'), indent=1)
