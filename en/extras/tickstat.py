# -*- coding: utf-8 -*-
"""
tickstat.py -- parse the l4d2_auto_add_zombie heartbeat log and report on
server stability / value balancing.

Usage:
    python tickstat.py <logfile>                      # full log (accepts both formats)
    python tickstat.py <logfile> 3000                 # only the last 3000 lines
    python tickstat.py <logfile> 3000 60              # last 3000 lines, target tick 60
    python tickstat.py <logfile> 3000 64 main         # only main-plugin lines
    python tickstat.py <logfile> 3000 64 watch        # only observer lines

    <logfile> defaults to ./l4d2_zombie_watch.log if omitted.

NOTE: both formats can end up in the same log file (both are named
l4d2_zombie_watch.log):
   main plugin line : ...,tick=64.0,fps=64.0,ft=15.62                (no realp/twarn)
   observer line    : ...,realp=0,...,tick=...,twarn=3,waves=2,...   (has realp/twarn)
   Running two instances on one machine, or loading both plugins, mixes them.
   Use the filter argument to pick one.

Output:
  1. tick distribution (min/p5/p25/p50/p75/p95/max + pass rate)
  2. worst 10 samples
  3. TICKWARN event detail (with the alive count / spawn count / pulse state at
     that moment) -- the key to lining up cause and effect
  4. tick x alive bucket table  <- directly answers "at how many zombies does
     tick start dropping"
  5. grouped by map

Dependency: log lines must contain a tick= field (main plugin v1.8.2+ /
observer v1.0.0+).
"""
import os
import sys
from collections import defaultdict

# Log path: 1st CLI arg, else ./l4d2_zombie_watch.log next to this script.
_DEFAULT_LOG = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "l4d2_zombie_watch.log")
LOG = sys.argv[1] if len(sys.argv) > 1 else _DEFAULT_LOG
ARG_N = int(sys.argv[2]) if len(sys.argv) > 2 else 0
TARGET = int(sys.argv[3]) if len(sys.argv) > 3 else 64
FILTER = (sys.argv[4] if len(sys.argv) > 4 else "all").lower()   # all | main | watch


def pct(sorted_vals, p):
    if not sorted_vals:
        return 0.0
    i = min(len(sorted_vals) - 1, max(0, int(round((p / 100.0) * (len(sorted_vals) - 1)))))
    return sorted_vals[i]


def kvs(line):
    """Parse `a=1,b=2,...` into a dict"""
    d = {}
    head = line
    p = line.find(",alive=")
    if p >= 0:
        head = line[p + 1:]
    for part in head.split(","):
        if "=" in part:
            k, v = part.split("=", 1)
            try:
                d[k] = float(v)
            except ValueError:
                d[k] = v
    return d


def parse_ts(line):
    p = line.find(",alive=")
    if p >= 19:
        return line[p - 19:p]
    return "?"


def main():
    if not os.path.exists(LOG):
        print("Log not found:", LOG)
        return

    lines = []
    with open(LOG, encoding="utf-8", errors="replace") as f:
        for line in f:
            lines.append(line.rstrip("\n"))
    if ARG_N > 0:
        lines = lines[-ARG_N:]

    hb = []          # (ts, dict, mapname)
    warns = []       # raw lines
    no_data = 0
    cur_map = "?"

    for line in lines:
        # Header lines (the ===== lines carrying map=) track the current map
        if "=====" in line and "map=" in line:
            i = line.find("map=")
            cur_map = line[i + 4:].split()[0].strip()
            continue
        if "TICKWARN" in line:
            is_watch_warn = "连续" in line          # observer format contains "连续 N 拍"
            if FILTER == "main" and is_watch_warn:
                continue
            if FILTER == "watch" and not is_watch_warn:
                continue
            warns.append(line)
            continue
        if ",alive=" in line and ",tick=" in line:
            d = kvs(line)
            is_watch = ("realp" in d) or ("twarn" in d)
            if FILTER == "main" and is_watch:
                continue
            if FILTER == "watch" and not is_watch:
                continue
            if isinstance(d.get("tick"), float):
                if d["tick"] > 0:
                    hb.append((parse_ts(line), d, cur_map))
                else:
                    no_data += 1
        elif ",alive=" in line:
            no_data += 1

    print("=" * 78)
    print(" tick health report   log: %s" % os.path.basename(LOG))
    print("=" * 78)
    print("parsed: %d valid tick samples | %d no-data lines (-1 or old format) | %d TICKWARN | filter=%s"
          % (len(hb), no_data, len(warns), FILTER))

    if not hb:
        print("\nNo valid tick samples.")
        print("Possible causes: 1) the log was written by an older plugin (no tick= field)")
        print("                 2) l4d2_ai_log_enable=0 or interval=0 (logging is off)")
        return

    ticks = sorted(d["tick"] for _, d, _ in hb)
    n = len(ticks)
    avg = sum(ticks) / n
    mn, mx = ticks[0], ticks[-1]

    print("\n1) tick distribution (target %d)" % TARGET)
    print("   min %.1f | p5 %.1f | p25 %.1f | p50 %.1f | p75 %.1f | p95 %.1f | max %.1f | mean %.2f"
          % (mn, pct(ticks, 5), pct(ticks, 25), pct(ticks, 50),
             pct(ticks, 75), pct(ticks, 95), mx, avg))

    def rate(below):
        c = sum(1 for t in ticks if t < below)
        return c, 100.0 * c / n

    for thr in (TARGET, TARGET - 3, TARGET - 6, 30, 20, 10):
        c, r = rate(thr)
        bar = "#" * int(r / 2)
        print("   < %-3d : %6d lines (%5.2f%%) %s" % (thr, c, r, bar))

    # 2) worst samples
    print("\n2) worst 10 samples")
    worst = sorted(hb, key=lambda x: x[1]["tick"])[:10]
    print("   %-19s %7s %6s %6s %6s %6s %5s  %s"
          % ("time", "tick", "alive", "cap", "spawn", "SI", "pulse", "horde"))
    for ts, d, _ in worst:
        print("   %-19s %7.1f %6.0f %6.0f %6.0f %6.0f %5s  %.0f"
              % (ts, d["tick"], d.get("alive", -1), d.get("cap", -1),
                 d.get("spawned", -1), d.get("si", -1),
                 "ON" if d.get("pulse", 0) == 1 else "OFF",
                 d.get("mob_left", -1)))

    # 3) TICKWARN detail
    print("\n3) TICKWARN detail (= moments of real tick drop, with battlefield state)")
    if not warns:
        print("   (none)")
    else:
        for w in warns[:40]:
            i = w.find("===== TICKWARN")
            print("   " + (w[i:] if i >= 0 else w.strip()))
        if len(warns) > 40:
            print("   ... %d more" % (len(warns) - 40))

    # 4) tick x alive buckets -- directly answers "at how many zombies tick drops"
    print("\n4) tick x live commons (buckets)  <- use this to judge whether zombie count is the bottleneck")
    buckets = [(0, 20), (20, 40), (40, 60), (60, 80), (80, 100),
               (100, 120), (120, 150), (150, 200), (200, 9999)]
    tbl = defaultdict(list)
    for _, d, _ in hb:
        a = d.get("alive", -1)
        if a < 0:
            continue
        for lo, hi in buckets:
            if lo <= a < hi:
                tbl[(lo, hi)].append(d["tick"])
                break
    print("   %-12s %7s %9s %9s %9s" % ("alive range", "samples", "tick mean", "tick min", "below target%"))
    for lo, hi in buckets:
        v = tbl.get((lo, hi))
        if not v:
            continue
        lab = "%d-%d" % (lo, hi if hi < 9999 else 999)
        below = 100.0 * sum(1 for t in v if t < TARGET) / len(v)
        print("   %-12s %7d %9.2f %9.1f %8.1f%%" % (lab, len(v), sum(v) / len(v), min(v), below))

    # 5) by map
    print("\n5) by map")
    perm = defaultdict(list)
    for _, d, m in hb:
        perm[m].append(d["tick"])
    for m, v in sorted(perm.items(), key=lambda kv: -len(kv[1])):
        v2 = sorted(v)
        print("   %-28s samples %6d | mean %6.2f | min %5.1f | <target %5.1f%%"
              % (m, len(v), sum(v) / len(v), v2[0],
                 100.0 * sum(1 for t in v if t < TARGET) / len(v)))

    print("\n" + "=" * 78)


if __name__ == "__main__":
    main()
