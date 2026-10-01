#!/usr/bin/env python3
"""
STRCon feed updates + SyntheticSharesOracle sValue/pause activity over a block range.

Reads RPC_URL from the environment (never printed). Uses `cast`.

Usage:
  python3 docs/drafts/strcon_feed_pull.py <from_block> <to_block> [asset_addr ...]
  python3 docs/drafts/strcon_feed_pull.py --csv --days 30
  python3 docs/drafts/strcon_feed_pull.py <from_block> <to_block> --csv output.csv

CSV mode exports both feeds only, defaults to the last 30 days through a finalized
block, and saves beside this script when no output path is given. The RPC must
support historical calls for the boundary checks. A range spanning an aggregator
phase change is rejected; collect each phase separately. Existing files are not overwritten.

  - Always pulls the Ondo + Calc Chainlink feeds (AnswerUpdated).
  - For each asset address you pass (e.g. the STRCon token) it reads getSValue()/assetData()
    and stars that asset's oracle events.

SyntheticSharesOracle facts (from its ABI):
  - per-asset getter: getSValue(asset) -> (uint128 sValue, bool paused)   # the module's isPaused()
  - routine dividend drift:           SValueUpdated(asset, old, new)
  - scheduled corporate action+pause: CorporateActionScheduled / ...Applied / ...Cancelled
"""
import argparse
import csv
import json
import os
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("from_block", nargs="?", type=int)
parser.add_argument("to_block", nargs="?", type=int)
parser.add_argument("assets", nargs="*")
parser.add_argument("--csv", nargs="?", const="", metavar="PATH", help="export both feeds as CSV")
parser.add_argument("--days", type=int, default=30, help="CSV lookback when blocks are omitted (default: 30)")
parser.add_argument("--chunk-size", type=int, default=2000, help="CSV log-query block span (default: 2000)")
args = parser.parse_args()
RPC = os.environ.get("RPC_URL")
if not RPC:
    sys.exit("Set RPC_URL in the process environment before running this script.")
if (args.from_block is None) != (args.to_block is None):
    parser.error("supply both from_block and to_block")
if args.csv is None and args.from_block is None:
    parser.error("supply from_block and to_block, or use --csv")
if args.days <= 0 or args.chunk_size <= 0:
    parser.error("--days and --chunk-size must be positive")
FROM, TO = args.from_block, args.to_block
ASSETS = [a.lower() for a in args.assets]

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
    # An explicit RPC and a temporary cwd avoid loading a repository dotenv file.
    try:
        r = subprocess.run(["cast", *map(str, a), "--rpc-url", RPC], capture_output=True,
                           text=True, timeout=30, cwd=tempfile.gettempdir())
    except (subprocess.TimeoutExpired, OSError):
        sys.exit(f"cast {a[0]} could not complete. Check cast installation and RPC connectivity.")
    if r.returncode != 0 and args.csv is not None:
        # Do not print stderr: providers can include a credential-bearing URL.
        sys.exit(f"cast {a[0]} failed. Check RPC connectivity, historical-state access, and log limits. No CSV written.")
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


def export_csv():
    def number(*command):
        return to_int(cast(*command).split()[0])

    if number("chain-id") != 1:
        sys.exit("CSV export requires Ethereum mainnet (chain ID 1).")
    finalized = number("block", "finalized", "--field", "number")
    start, end = args.from_block, args.to_block
    if start is None:
        end = finalized
        target = number("block", end, "--field", "timestamp") - args.days * 86400
        low, high = 0, end
        # Find the first block at/after the target date, without scanning every block.
        while low < high:
            middle = (low + high) // 2
            if number("block", middle, "--field", "timestamp") < target:
                low = middle + 1
            else:
                high = middle
        start = low
    if not 0 <= start <= end <= finalized:
        sys.exit("Require 0 <= from_block <= to_block <= finalized block.")
    output = Path(args.csv) if args.csv else Path(__file__).with_name(f"strcon_feed_prices_{start}_{end}.csv")
    if output.exists():
        sys.exit(f"Refusing to overwrite {output}.")
    print(f"Collecting both feeds over blocks {start}..{end}.", file=sys.stderr)
    fields = ["feed", "proxy_address", "aggregator_address", "phase_id", "aggregator_round_id",
              "block_number", "block_hash", "transaction_hash", "transaction_index", "log_index",
              "answer_raw", "decimals", "price_usd", "updated_at", "updated_at_utc",
              "range_from_block", "range_to_block"]
    rows = []
    for name, proxy in FEEDS.items():
        feed = "reference" if name.startswith("Ondo") else "primary"
        # Include a possible phase transition inside the first requested block.
        boundaries = (max(start - 1, 0), end)
        phases = [number("call", proxy, "phaseId()(uint16)", "--block", block) for block in boundaries]
        aggregators = [cast("call", proxy, "aggregator()(address)", "--block", block).lower()
                       for block in boundaries]
        if phases[0] != phases[1] or aggregators[0] != aggregators[1]:
            sys.exit(f"{feed}: aggregator phase changed in this range. Split the range by phase. No CSV written.")
        if number("call", proxy, "decimals()(uint8)", "--block", end) != 8:
            sys.exit(f"{feed}: expected 8 feed decimals. No CSV written.")
        count = 0
        for first in range(start, end + 1, args.chunk_size):
            last = min(first + args.chunk_size - 1, end)
            events = json.loads(cast("logs", ANSWER_UPDATED, "--address", aggregators[1],
                                     "--from-block", first, "--to-block", last, "--json"))
            for event in events:
                answer = int(event["topics"][1], 16)
                if answer >= 1 << 255:
                    answer -= 1 << 256
                updated_at = int(event["data"], 16)
                magnitude = abs(answer)
                price = f"{'-' if answer < 0 else ''}{magnitude // 10**8}.{magnitude % 10**8:08d}"
                rows.append(dict(zip(fields, [feed, proxy, aggregators[1], phases[1],
                    int(event["topics"][2], 16), to_int(event["blockNumber"]), event["blockHash"],
                    event["transactionHash"], to_int(event["transactionIndex"]), to_int(event["logIndex"]),
                    answer, 8, price, updated_at, datetime.fromtimestamp(updated_at, timezone.utc).isoformat(),
                    start, end])))
                count += 1
        print(f"{feed}: {count} updates collected.", file=sys.stderr)
    rows.sort(key=lambda row: (row["block_number"], row["transaction_index"], row["log_index"]))
    # Open only after both feeds succeed, and never replace an existing export.
    with output.open("x", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)
    print(f"Saved {len(rows)} feed updates to {output}.")


if args.csv is not None:
    export_csv()
    sys.exit(0)


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
