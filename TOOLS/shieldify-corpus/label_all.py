#!/usr/bin/env python3
"""Label ALL 1022 titles with the LLM and produce the authoritative ranking.
Saves incrementally so a partial run is still usable."""
import json, os, re, time, urllib.request
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor

STUDY = os.path.expanduser('~/.hermes/workspace/study')
API = "https://api.deepseek.com/chat/completions"
KEY = os.environ["CLAWDI_OPENAI_API_KEY"]
OUTF = os.path.join(STUDY, 'shieldify-labels-all.json')

TAX = ("access_control, reentrancy, oracle_price, slippage_mev, rounding_precision, "
       "reward_accounting, share_inflation_4626, funds_locked_dos, input_validation, "
       "token_standard_edge, upgrade_proxy_init, external_call_unchecked, stale_state_sync, "
       "fee_tax, liquidation_solvency, withdrawal_exit_queue, pause_emergency_migration, "
       "amm_liquidity_tick, governance_voting, auction_bidding, events_returns, docs_spec, "
       "gas_optimization, randomness_vrf, signature_replay, web2_offchain, other_logic_flaw")
SYS = ("Classify each numbered smart-contract audit finding TITLE into exactly one of: " + TAX +
       ". Do not explain or think step by step. Output ONLY lines of the form N|category.")

R = json.load(open(os.path.join(STUDY, 'shieldify-findings.json')))
titles = [f['title'] for name, r in R.items() for f in r['findings']]
print("titles:", len(titles), flush=True)

BS = 25
batches = [titles[i:i+BS] for i in range(0, len(titles), BS)]

def llm(batch):
    body = "\n".join(f"{i}|{t}" for i, t in enumerate(batch))
    for a in range(3):
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
            print(f"   thin {len(out)}/{len(batch)} retry", flush=True)
        except Exception as e:
            print(f"   err {type(e).__name__} {e}", flush=True)
        time.sleep(5 * (a + 1))
    return {}

labels = {}
done = 0
with ThreadPoolExecutor(max_workers=3) as ex:
    for idx, out in ex.map(lambda p: (p[0], llm(p[1])), enumerate(batches)):
        base = idx * BS
        for k, v in out.items():
            labels[base + k] = v
        done += len(out)
        print(f"batch {idx}: {len(out)}/{len(batches[idx])}  total {done}", flush=True)
        json.dump(labels, open(OUTF, 'w'), indent=1)
print("labelled:", len(labels), "of", len(titles), flush=True)
