# cfetch — read Cloudflare-walled explorers through real headless Chrome

**Why this exists:** `robinhoodchain.blockscout.com` (Robinhood Chain Blockscout) returns
**403 "Just a moment…"** to `curl` from this container — a Cloudflare JS bot challenge. A spoofed
browser `User-Agent` does not pass it. Driving **real headless Chrome** does, and the same API then
returns full verified contract source. This one script is how the entire Longbow target map (28 markets,
28 oracles, vaults, feed classification) was built — without it, Robinhood Chain targets are effectively
black-box, the same ceiling that Monad targets hit.

`*.sh` is gitignored in this repo, so the script lives here as a snippet. Keep a copy at
`~/.hermes/scripts/cfetch.sh` (chmod +x) for local use.

```bash
#!/usr/bin/env bash
# cfetch <url> [wait_ms]  — print the page BODY; strips the JSON <pre> wrapper.
set -u
URL="$1"; WAIT="${2:-12000}"
export LD_LIBRARY_PATH=/opt/chrome-libs/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}
PROF="$(mktemp -d)"
timeout 120 google-chrome --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage \
  --virtual-time-budget="$WAIT" --user-data-dir="$PROF" --dump-dom "$URL" 2>/dev/null \
  | sed -e 's/^.*<pre>//' -e 's/<\/pre>.*$//' -e 's/<[^>]*>//g'
rm -rf "$PROF"
```

Requires Chrome + its libs on the box — see the `headless-chrome-setup` skill and `CHAIN_INFO.md`
("Headless browser on the Linux container").

## Usage

```bash
# verified source + ABI for one contract (JSON)
./cfetch.sh "https://robinhoodchain.blockscout.com/api/v2/smart-contracts/0x8cb8AA35228c96C1C4E956E69AbAEBCc2aA7Dcfe"

# pull just the source out of it
./cfetch.sh "<url>" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['source_code'])"
```

## Pitfalls (all hit for real, 2026-09-13)

1. **Verification status lives in the response FIELD, not the HTTP status.**
   Verified ⇒ a **36-key** object including `is_verified` / `name` / `abi` / `source_code`.
   Unverified ⇒ a **6-key** object (with `creation_bytecode`, no `name`).
   A `500 "Internal server error"` showed up **intermittently for both kinds** — a control re-fetch of a
   known-verified contract returned the same 500 as a known-unverified address. Always fetch a
   known-verified control **in the same batch** and compare the JSON *shape*. (I first read that 500 as
   "unverified" and had to retract it.)
2. **Batch it, don't loop it.** Each call cold-starts a Chrome; ~10–20 s each. Fetch a handful of the
   addresses that actually matter rather than all N in a loop — or get the identical information far more
   cheaply from the RPC (`cast codesize` / selector census, see below).
3. **`cast codesize` first, Chrome second.** Identical code size across a family of addresses ⇒ same
   implementation with different **immutables** (why 28 oracle instances had 28 distinct code hashes at an
   identical 1,277 bytes). A sibling that deviates in size is where the custom code is — that is how
   Longbow's two hand-written oracle feeds (5,207 B and 23,186 B vs 9,571 B Chainlink proxies) surfaced.
   Only the deviating ones need a Chrome fetch.
