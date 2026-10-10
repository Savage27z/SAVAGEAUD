#!/usr/bin/env python3
"""Pull verified source for the obol.sh (Daemon) contracts from Sourcify into TARGETS/obol/."""
import json, os, sys, urllib.request

CHAIN = 4663
OUT = "/root/.hermes/workspace/SAVAGEAUD/TARGETS/obol"
UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/153.0.0.0 Safari/537.36"

TARGETS = {
    "collection": "0x1BD783d8dcc50db3f610d1c46ec7e97d7f457402",
    "sale":       "0xD22301bcA4eCfFb9F4B87792885D766595e7363c",
    "treasury_safe": "0xA7DC540d12E53Cf8d6615921Fe7b4f9Ca73A0dBC",
}

def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=90) as r:
        return r.read().decode("utf8", "replace")

def main():
    os.makedirs(os.path.join(OUT, "src"), exist_ok=True)
    os.makedirs(os.path.join(OUT, "meta"), exist_ok=True)
    summary = {}
    for name, addr in TARGETS.items():
        url = f"https://sourcify.dev/server/v2/contract/{CHAIN}/{addr}?fields=all"
        try:
            raw = get(url)
        except Exception as e:
            print(f"{name:14s} FETCH FAIL {e}")
            summary[name] = {"address": addr, "error": str(e)}
            continue
        try:
            d = json.loads(raw)
        except Exception as e:
            print(f"{name:14s} BAD JSON ({len(raw)}b) {e}")
            summary[name] = {"address": addr, "error": "bad json", "bytes": len(raw)}
            continue
        with open(os.path.join(OUT, "meta", f"{name}.json"), "w") as f:
            json.dump(d, f, indent=1)
        files = d.get("sources") or (d.get("sourceCode") or {}).get("sources") or ((d.get("stdJsonInput") or {}).get("sources")) or {}
        written = []
        for path, obj in files.items():
            content = obj.get("content") if isinstance(obj, dict) else None
            if content is None:
                continue
            safe = path.replace("..", "_").lstrip("/")
            dest = os.path.join(OUT, "src", name + "__" + safe.replace("/", "__"))
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with open(dest, "w") as f:
                f.write(content)
            written.append((safe, len(content)))
        summary[name] = {
            "address": addr,
            "creationMatch": d.get("creationMatch"),
            "runtimeMatch": d.get("runtimeMatch"),
            "verifiedAt": d.get("verifiedAt"),
            "compiler": (lambda c: c.get("version") if isinstance(c, dict) else c)(
                (d.get("compilation") or {}).get("compilerVersion") or (d.get("metadata") or {}).get("compiler")),
            "files": sorted(written, key=lambda x: -x[1]),
        }
        print(f"\n=== {name} {addr} ===")
        print("  match:", d.get("creationMatch"), "/", d.get("runtimeMatch"), " verifiedAt:", d.get("verifiedAt"))
        print("  compiler:", summary[name]["compiler"])
        print("  sources:", len(written))
        for p, n in summary[name]["files"]:
            print(f"    {n:7d}  {p}")
    with open(os.path.join(OUT, "sourcify_summary.json"), "w") as f:
        json.dump(summary, f, indent=1)
    print("\nwrote", os.path.join(OUT, "sourcify_summary.json"))

if __name__ == "__main__":
    main()
