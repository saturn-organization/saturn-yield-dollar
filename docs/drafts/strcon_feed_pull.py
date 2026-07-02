#!/usr/bin/env python3
"""
STRCon feed updates + SyntheticSharesOracle sValue/pause activity over a block range.

Reads RPC_URL from the environment (never printed). Uses `cast`. Logs need no archive node.

Usage:
  set -a; . ./.env; set +a
  python3 docs/strcon_feed_pull.py <from_block> <to_block> [asset_addr ...]

  - Always pulls the Ondo + Calc Chainlink feeds (AnswerUpdated).
  - For each asset address you pass (e.g. the STRCon token) it reads getSValue()/assetData()
    and stars that asset's oracle events.

SyntheticSharesOracle facts (from its ABI):
  - per-asset getter: getSValue(asset) -> (uint128 sValue, bool paused)   # the module's isPaused()
  - routine dividend drift:           SValueUpdated(asset, old, new)
  - scheduled corporate action+pause: CorporateActionScheduled / ...Applied / ...Cancelled
"""
import json
import os
import subprocess
import sys
from datetime import datetime, timezone

RPC = os.environ.get("RPC_URL")
if not RPC:
    sys.exit("RPC_URL not in env. Run:  set -a; . ./.env; set +a")
if len(sys.argv) < 3:
    sys.exit("usage: strcon_feed_pull.py <from_block> <to_block> [asset_addr ...]")
FROM, TO = sys.argv[1], sys.argv[2]
ASSETS = [a.lower() for a in sys.argv[3:]]

FEEDS = {"Ondo (STRCon/USD)": "0x67d4Ae9f265270aE123c08D2657536771D19cD91",
         "Calc (STRCon-USD)": "0xC353ac4b425f818Ad87E228bf816E15c2173AC07"}
ORACLE = "0x9BC39DB6fbB44B91a48b8D5A6C208B82B1741bE6"
ANSWER_UPDATED = "AnswerUpdated(int256,uint256,uint256)"

# topic0 -> (name, [(label, kind) per non-indexed data word]); kind: e18 | ts | raw
EVENTS = {
    "0xacf4cb25f16a3eeea932371aa43e3d44041d4f249c3287ffdb738ad9b7a79d8b": ("SValueUpdated",            [("old", "e18"), ("new", "e18")]),
    "0x099d73d6bfcc30d71c018b07224ab40835e5c15e321557a07c4fe2c272e87777": ("CorporateActionApplied",   [("old", "e18"), ("new", "e18")]),
    "0x0d46859590346aabf78b4f0fb6d73309d9bf4f875edc024b1a5c32552cea2bb3": ("CorporateActionScheduled", [("sValue", "e18"), ("pauseStart", "ts")]),
    "0xbe86f5d388381e78a12e12e08f347157c59c8ecedda911a72930a611e70c5e56": ("CorporateActionCancelled", []),
    "0x016de277906da9bccd612597bb3387946bd3815de9eea61ae16105325e09d7be": ("AssetAdded",               [("initSValue", "e18"), ("driftBps", "raw"), ("cooldown", "raw")]),
    "0x70eaf6020684692aa5f9ad62916aeae94d696c7e84edf16d6ee19f9813b0994a": ("DriftParametersUpdated",   [("oldBps", "raw"), ("newBps", "raw"), ("oldCD", "raw"), ("newCD", "raw")]),
}


def cast(*a):
    r = subprocess.run(["cast", *a, "--rpc-url", RPC], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


def to_int(x):
    if x is None:
        return None
    x = str(x)
    try:
        return int(x, 16) if x.startswith("0x") else int(x)
    except ValueError:
        return None


def t(ts):
    return datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%m-%d %H:%M:%S") if ts else "-"


def logs(addr, *extra):
    raw = cast("logs", *extra, "--address", addr, "--from-block", FROM, "--to-block", TO, "--json")
    return json.loads(raw) if raw else None


# ---- feeds: every AnswerUpdated ----
for name, proxy in FEEDS.items():
    agg = cast("call", proxy, "aggregator()(address)")
    print("=" * 72)
    print(f"{name}   aggregator {agg}")
    ev = logs(agg or proxy, ANSWER_UPDATED)
    if not ev:
        print("  no logs")
        continue
    rows = sorted((int(l["data"], 16), int(l["topics"][1], 16), int(l["topics"][2], 16)) for l in ev)
    print(f"  {'round':>6} {'price':>10} {'Δ%':>8} {'updatedAt (UTC)':>21} {'Δt':>9}")
    prev = None
    for u, p, rid in rows:
        dpx = "" if not prev else f"{(p - prev[1]) / prev[1] * 100:+.3f}"
        dt = "" if not prev else f"{u - prev[0]}s"
        print(f"  {rid:>6} {p / 1e8:>10.4f} {dpx:>8} {t(u):>21} {dt:>9}")
        prev = (u, p)

# ---- SyntheticSharesOracle: per-asset state + decoded events ----
print("=" * 72)
print(f"SyntheticSharesOracle   {ORACLE}")
for a in ASSETS:
    sv = cast("call", ORACLE, "getSValue(address)(uint128,bool)", a)
    ad = cast("call", ORACLE, "assetData(address)(uint128,uint128,uint256,uint256,uint16,uint48)", a)
    svv = to_int(sv.split()[0]) if sv else None
    print(f"  asset {a}")
    print(f"    getSValue -> {sv}" + (f"   (sValue/1e18 = {svv / 1e18:.10f})" if svv else ""))
    print(f"    assetData -> {ad}")

ev = logs(ORACLE)
if ev is None:
    print("  events: query failed")
else:
    print(f"  {len(ev)} events in range:")
    for l in sorted(ev, key=lambda x: to_int(x["blockNumber"]) or 0):
        name, params = EVENTS.get(l["topics"][0], (f"unknown {l['topics'][0][:10]}…", None))
        asset = "0x" + l["topics"][1][-40:] if len(l["topics"]) > 1 else "-"
        star = "  <== watched asset" if asset.lower() in ASSETS else ""
        bn = to_int(l["blockNumber"])
        bts = to_int(cast("block", str(bn), "--field", "timestamp")) if bn is not None else None
        print(f"    {t(bts)}  block {bn}  {name}  asset={asset}{star}")
        d = l.get("data", "0x")[2:]
        if params is None:
            print(f"        data={l.get('data', '0x')}")
        for i, (label, kind) in enumerate(params or []):
            wv = int(d[i * 64:(i + 1) * 64] or "0", 16)
            val = f"{wv / 1e18:.10f}" if kind == "e18" else t(wv) if kind == "ts" else str(wv)
            print(f"        {label} = {val}")
