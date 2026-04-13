#!/usr/bin/env python3
"""Print side-by-side latency table from same-rack and cross-rack benchmark results."""
import json
import os
import sys

results_dir = sys.argv[1] if len(sys.argv) > 1 else "results"

rows = []
for name in ["same-rack", "cross-rack"]:
    path = os.path.join(results_dir, name + ".json")
    if not os.path.exists(path):
        print(f" {name:<16}  (no results — run: make phase3-{name} run-benchmark)")
        continue
    d = json.load(open(path))
    p50 = round(d.get("request_latency", {}).get("p50", 0), 2)
    p99 = round(d.get("request_latency", {}).get("p99", 0), 2)
    tput = round(d.get("request_throughput", {}).get("avg", 0), 1)
    rows.append((name, p50, p99, tput))
    print(f" {name:<16} {p50:>12.2f}   {p99:>12.2f}   {tput:>14.1f}")

if len(rows) == 2:
    sr, cr = rows
    p50r = cr[1] / sr[1] if sr[1] else 0
    p99r = cr[2] / sr[2] if sr[2] else 0
    tputr = cr[3] / sr[3] if sr[3] else 0
    print("----------------------------------------------------------------")
    print(f" {'Cross/Same':<16} {p50r:>11.2f}x   {p99r:>11.2f}x   {tputr:>13.2f}x")
