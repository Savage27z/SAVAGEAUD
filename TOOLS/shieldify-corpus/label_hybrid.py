#!/usr/bin/env python3
"""Hybrid label pass:
  - keyword classifier (imported from cluster_shieldify RULES/FAM) labels all 1022 titles
  - LLM labels an annotated 150-title random sample  -> measures keyword accuracy
  - LLM labels all keyword-UNCLASSIFIED titles       -> folds them into the ranking
Outputs shieldify-labels-hybrid.json + prints agreement + merged distribution.
"""
import json, os, re, random, time, urllib.request
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
import importlib.util
import sys

STUDY = os.path.expanduser('~/.hermes/workspace/study')
sys.path.insert(0, STUDY)
random.seed(7)

# ---- reuse the keyword classifier from cluster_shieldify.py
src = open(os.path.join(STUDY, 'cluster_shieldify.py')).read()
src = src.split("fam = Counter(); fam_sev")[0]     # everything up to the aggregation pass
ns = {'re': re, 'json': json, 'os': os, 'Counter': Counter, 'defaultdict': defaultdict}
exec(src, ns)                                      # defines FAM + classify + R
classify = ns['classify']

R = json.load(open(os.path.join(STUDY, 'shieldify-findings.json')))
rows = []
for name, r in R.items():
    for f in r['findings']:
        rows.append(dict(report=name, id=f['id'], title=f['title'], severity=f['severity']))
for i, r in enumerate(rows):
    r['kw'] = classify(r['title'])[0]      # classify returns (family, score)
print("titles:", len(rows))
print("keyword-unclassified:", sum(1 for r in rows if r['kw'] == 'UNCLASSIFIED'))

uncls = [r for r in rows if r['kw'] == 'UNCLASSIFIED']
others = [r for r in rows if r['kw'] != 'UNCLASSIFIED']
sample = random.sample(others, min(150, len(others)))

TAX = ("access_control, reentrancy, oracle_price, slippage_mev, rounding_precision, "
       "reward_accounting, share_inflation_4626, funds_locked_dos, input_validation, "
       "token_standard_edge, upgrade_proxy_init, external_call_unchecked, stale_state_sync, "
       "fee_tax, liquidation_solvency, withdrawal_exit_queue, pause_emergency_migration, "
       "amm_liquidity_tick, governance_voting, auction_bidding, events_returns, docs_spec, "
       "gas_optimization, randomness_vrf, signature_replay, web2_offchain, other_logic_flaw")
SYS = ("Classify each numbered smart-contract audit finding TITLE into exactly one of: " + TAX +
       ". Do not explain or think step by step. Output ONLY lines of the form N|category.")

API = "https://api.deepseek.com/chat/completions"
KEY = os.environ["CLAWDI_OPENAI_API_KEY"]

def llm_labels(batch):
    body = "\n".join(f"{i}|{r['title']}" for i, r in enumerate(batch))
    for attempt in range(3):
        try:
            req = urllib.request.Request(API, data=json.dumps({
                "model": "deepseek-v4-flash",
                "messages": [{"role": "system", "content": SYS}, {"role": "user", "content": body}],
                "max_tokens": 32000, "temperature": 0}).encode(),
                headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"})
            resp = json.load(urllib.request.urlopen(req, timeout=1800))
            c = resp["choices"][0]["message"].get("content") or ""
            out = {}
            for line in c.splitlines():
                m = re.match(r'\s*(\d+)\s*\|\s*([a-z_0-9]+)', line.strip())
                if m and int(m.group(1)) < len(batch):
                    out[int(m.group(1))] = m.group(2)
            if len(out) >= len(batch) * 0.7:
                return out
            print(f"   thin batch ({len(out)}/{len(batch)}), retry", flush=True)
        except Exception as e:
            print(f"   err {type(e).__name__} {e}", flush=True)
        time.sleep(5 * (attempt + 1))
    return {}

BS = 25
def run_group(items, tag):
    batches = [items[i:i+BS] for i in range(0, len(items), BS)]
    print(f"{tag}: {len(items)} titles in {len(batches)} batches", flush=True)
    res = [None] * len(batches)
    with ThreadPoolExecutor(max_workers=3) as ex:
        for idx, out in ex.map(lambda p: (p[0], llm_labels(p[1])), enumerate(batches)):
            res[idx] = out
            print(f"   {tag} batch {idx}: {len(out)}/{len(batches[idx])}", flush=True)
    flat = {}
    for idx, out in enumerate(res):
        for k, v in out.items():
            flat[idx * BS + k] = v
    return flat

samp_lab = run_group(sample, "SAMPLE")
uncls_lab = run_group(uncls, "UNCLASSIFIED")

# agreement on the sample
agree = sum(1 for i, r in enumerate(sample) if samp_lab.get(i) == r['kw'])
print(f"\nKEYWORD-vs-LLM agreement on {len(sample)} sampled titles: "
      f"{agree}/{len(sample)} = {100*agree/max(len(sample),1):.1f}%")

for i, r in enumerate(sample):
    r['llm'] = samp_lab.get(i, '')
for i, r in enumerate(uncls):
    r['llm'] = uncls_lab.get(i, '')

json.dump({'rows': rows, 'sample_idx_titles': [r['title'] for r in sample],
           'uncls_titles': [r['title'] for r in uncls],
           'sample_llm': samp_lab, 'uncls_llm': uncls_lab},
          open(os.path.join(STUDY, 'shieldify-labels-hybrid.json'), 'w'), indent=1, ensure_ascii=False)
print("saved shieldify-labels-hybrid.json")
