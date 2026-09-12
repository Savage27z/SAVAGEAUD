#!/usr/bin/env python3
"""Final analysis: map keyword family names -> slugs, measure keyword-vs-LLM agreement,
merge into one label per title, and produce the ranked family table by frequency and by
severe (critical+high) density."""
import json, os, re
from collections import Counter, defaultdict

STUDY = os.path.expanduser('~/.hermes/workspace/study')
R = json.load(open(os.path.join(STUDY, 'shieldify-findings.json')))
H = json.load(open(os.path.join(STUDY, 'shieldify-labels-hybrid.json')))
H['sample_llm'] = {int(k): v for k, v in H['sample_llm'].items()}
H['uncls_llm'] = {int(k): v for k, v in H['uncls_llm'].items()}

NAME2SLUG = {
 'Signature / replay / nonce / EIP-712': 'signature_replay',
 'Access control / missing authorization': 'access_control',
 'Reentrancy / callback abuse': 'reentrancy',
 'Oracle / price manipulation / TWAP': 'oracle_price',
 'Slippage / MEV / front-run / deadline': 'slippage_mev',
 'Rounding / precision / decimals / arithmetic': 'rounding_precision',
 'Reward / share / points accrual accounting': 'reward_accounting',
 'Share price / inflation / first-depositor / donation': 'share_inflation_4626',
 'Funds locked / stuck / DoS / griefing': 'funds_locked_dos',
 'Missing input validation / unbounded params': 'input_validation',
 'Token standard edge cases (FoT / rebasing / blacklist / decimals)': 'token_standard_edge',
 'Upgradeability / proxy / initializer / storage': 'upgrade_proxy_init',
 'External call / unchecked return / low-level call': 'external_call_unchecked',
 'Stale state / cache / sync / ordering': 'stale_state_sync',
 'Fee / tax / commission calculation': 'fee_tax',
 'Liquidation / bad debt / solvency': 'liquidation_solvency',
 'Withdrawal / exit / queue / cooldown': 'withdrawal_exit_queue',
 'Pause / emergency / migration controls': 'pause_emergency_migration',
 'Liquidity management / tick / position (AMM)': 'amm_liquidity_tick',
 'Governance / voting / timelock': 'governance_voting',
 'Auction / bidding / bonding curve': 'auction_bidding',
 'Event / log / return-value correctness': 'events_returns',
 'Documentation / spec / comment mismatch': 'docs_spec',
 'Gas / optimization / code quality': 'gas_optimization',
 'Randomness / VRF / RNG': 'randomness_vrf',
 'Web2 / off-chain / content / API': 'web2_offchain',
 'UNCLASSIFIED': 'other_logic_flaw',
}

# rebuild the row list in the SAME order as label_hybrid.py (dict iteration of R)
rows = []
for name, r in R.items():
    for f in r['findings']:
        rows.append(dict(report=name, id=f['id'], title=f['title'], severity=f['severity']))

# keyword label per row via the classifier
import sys
sys.path.insert(0, STUDY)
src = open(os.path.join(STUDY, 'cluster_shieldify.py')).read().split("fam = Counter(); fam_sev")[0]
ns = {'re': re, 'json': json, 'os': os, 'Counter': Counter, 'defaultdict': defaultdict}
exec(src, ns)
classify = ns['classify']
for r in rows:
    r['kw'] = NAME2SLUG.get(classify(r['title'])[0], 'other_logic_flaw')

# agreement: sample was random.sample(others,150) with seed 7 in the same order
sample_titles = H['sample_idx_titles']
agree = mism = 0
mism_examples = []
slug_by_title = {}
for r in rows:
    slug_by_title.setdefault(r['title'], r['kw'])
for i, t in enumerate(sample_titles):
    llm = H['sample_llm'].get(i, '')
    kw = slug_by_title.get(t, '')
    if llm == kw:
        agree += 1
    else:
        mism += 1
        if len(mism_examples) < 15:
            mism_examples.append((t[:70], kw, llm))
tot_s = len(sample_titles)
print(f"KEYWORD-vs-LLM agreement: {agree}/{tot_s} = {100*agree/tot_s:.1f}%  (disagreements {mism})")
print("\nsample disagreements (title | keyword | LLM):")
for t, k, l in mism_examples:
    print(f"   {t}\n      kw={k}  llm={l}")

# merge: LLM wins where present
uncls_titles = H['uncls_titles']
uncls_map = {t: H['uncls_llm'].get(str(i), H['uncls_llm'].get(i, '')) for i, t in enumerate(uncls_titles)}
sample_llm_map = {t: H['sample_llm'].get(i, '') for i, t in enumerate(sample_titles)}
for r in rows:
    lab = sample_llm_map.get(r['title']) or uncls_map.get(r['title']) or r['kw']
    r['label'] = lab or 'other_logic_flaw'

fam = Counter(); fam_sev = defaultdict(Counter); fam_ex = defaultdict(list)
for r in rows:
    k = r['label']; fam[k] += 1; fam_sev[k][r['severity']] += 1
    if len(fam_ex[k]) < 4:
        fam_ex[k].append(f"[{r['report'].replace('-Security-Review','')}] {r['title'][:78]}")

tot = sum(fam.values())
print(f"\n\n=== FINAL FAMILY RANKING (n={tot}) ===")
print(f"{'family':30s} {'n':>4s} {'%':>5s} {'CR':>3s} {'HI':>3s} {'MED':>4s} {'LOW':>4s} {'INF':>4s} {'sev n':>6s}")
order = sorted(fam.items(), key=lambda kv: -(fam_sev[kv[0]]['critical'] + fam_sev[kv[0]]['high']))
for k, v in order:
    s = fam_sev[k]; ch = s['critical'] + s['high']
    print(f"{k:30s} {v:4d} {100*v/tot:5.1f} {s['critical']:3d} {s['high']:3d} {s['medium']:4d} {s['low']:4d} {s['info']:4d} {ch:6d}")

print("\n=== by raw frequency ===")
for k, v in fam.most_common():
    s = fam_sev[k]
    print(f"{k:30s} {v:4d}  cr+hi={s['critical']+s['high']:3d}")

json.dump({'rows': rows, 'fam': dict(fam), 'fam_sev': {k: dict(v) for k, v in fam_sev.items()},
           'fam_ex': {k: v for k, v in fam_ex.items()}, 'agreement': f"{agree}/{tot_s}"},
          open(os.path.join(STUDY, 'shieldify-final.json'), 'w'), indent=1, ensure_ascii=False)
print("\nsaved shieldify-final.json")
