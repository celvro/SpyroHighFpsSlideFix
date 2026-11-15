#!/usr/bin/env python3
"""Compare a replay run's trace against its take's reference trace (tools/replay.lua).

Runs under python3 (the Cowork VM or any Linux/mac box); the game PC has no Python, so this is the
one tool in this repo that is not PowerShell. Stdlib only.

Usage:
  python3 tools/compare_replays.py --dir <probe mod folder> --take LS102_20261115_140000
  python3 tools/compare_replays.py <ref.csv> <run.csv> [<run2.csv> ...]

With --dir/--take it finds replay_<take>_ref.csv and every replay_<take>_run*.csv, compares each run
against the ref, prints the report and writes replay_<take>_compare.txt next to them.

What a divergence means here: the runs are free-run replays (no course correction), so the FIRST
divergence is the finding; everything after it is the drift that follows from it. The first
divergence time is where to look in both traces (and in game, with quicksave) for the bug.
Positions are level-origin-relative in the traces, so refs and runs compare across level reloads.
"""
import argparse, glob, math, os, re, sys

GRID = 0.1           # seconds between comparison samples
THRESHOLDS = (25.0, 100.0, 500.0)  # units of 3D divergence worth reporting (Spyro is ~100 tall)
MODE_NAMES = {0: "None", 1: "Walking", 2: "NavWalking", 3: "Falling", 4: "Swimming", 5: "Flying", 6: "Custom"}


def mode_name(m):
    return MODE_NAMES.get(m, str(m))


def read_trace(path):
    rows = []
    with open(path, newline="") as f:
        header = f.readline().strip().split(",")
        idx = {name: i for i, name in enumerate(header)}
        need = ["t", "x", "y", "z", "yaw", "vz", "speed", "mode", "montage"]
        for name in need:
            if name not in idx:
                sys.exit(f"{path}: no '{name}' column (not a replay trace?)")
        for line in f:
            p = line.rstrip("\n").split(",")
            if len(p) < len(header):
                continue
            try:
                rows.append({
                    "t": float(p[idx["t"]]), "x": float(p[idx["x"]]), "y": float(p[idx["y"]]),
                    "z": float(p[idx["z"]]), "yaw": float(p[idx["yaw"]]), "vz": float(p[idx["vz"]]),
                    "speed": float(p[idx["speed"]]), "mode": int(float(p[idx["mode"]])),
                    "charging": p[idx["charging"]] == "true" if "charging" in idx else False,
                    "montage": p[idx["montage"]],
                })
            except ValueError:
                continue
    if not rows:
        sys.exit(f"{path}: no rows")
    return rows


def sample(rows, t):
    """The trace's state at time t: positions interpolated, the rest from the row at or before t."""
    import bisect
    times = sample.cache.get(id(rows))
    if times is None:
        times = [r["t"] for r in rows]
        sample.cache[id(rows)] = times
    i = bisect.bisect_right(times, t) - 1
    if i < 0:
        return rows[0]
    if i >= len(rows) - 1:
        return rows[-1]
    a, b = rows[i], rows[i + 1]
    if b["t"] <= a["t"]:
        return a
    f = (t - a["t"]) / (b["t"] - a["t"])
    out = dict(a)
    for k in ("x", "y", "z"):
        out[k] = a[k] + (b[k] - a[k]) * f
    return out


sample.cache = {}


def yaw_diff(a, b):
    return abs((a - b + 180.0) % 360.0 - 180.0)


def airborne_segments(rows):
    """(start t, duration, apex rise) of every Falling stretch — the jump/glide/fall shape."""
    segs, start, z0, apex = [], None, 0.0, 0.0
    for r in rows:
        if r["mode"] == 3:
            if start is None:
                start, z0, apex = r["t"], r["z"], r["z"]
            apex = max(apex, r["z"])
        elif start is not None:
            segs.append((start, r["t"] - start, apex - z0))
            start = None
    if start is not None:
        segs.append((start, rows[-1]["t"] - start, apex - z0))
    return segs


def compare(ref, run, run_name, out):
    end = min(ref[-1]["t"], run[-1]["t"])
    n = max(2, int(end / GRID))
    crossings = {}
    max_delta, max_delta_t = 0.0, 0.0
    mode_mismatch = montage_mismatch = charging_mismatch = 0
    mode_intervals, current = [], None
    montage_pairs = {}
    for i in range(n + 1):
        t = min(i * GRID, end)
        a, b = sample(ref, t), sample(run, t)
        d = math.dist((a["x"], a["y"], a["z"]), (b["x"], b["y"], b["z"]))
        if d > max_delta:
            max_delta, max_delta_t = d, t
        for th in THRESHOLDS:
            if th not in crossings and d > th:
                crossings[th] = t
        if a["mode"] != b["mode"]:
            mode_mismatch += 1
            if current and current[1] == a["mode"] and current[2] == b["mode"]:
                current[3] = t
            else:
                current = [t, a["mode"], b["mode"], t]
                mode_intervals.append(current)
        else:
            current = None
        if a["montage"] != b["montage"]:
            montage_mismatch += 1
            key = (a["montage"] or "-", b["montage"] or "-")
            if key not in montage_pairs:
                montage_pairs[key] = t
        if a["charging"] != b["charging"]:
            charging_mismatch += 1
    total = n + 1

    out(f"\n== {run_name} (compared over {end:.1f} s) ==")
    first = crossings.get(THRESHOLDS[0])
    if first is None:
        out(f"  position: never diverged past {THRESHOLDS[0]:.0f} units (max {max_delta:.1f} at {max_delta_t:.1f} s)")
    else:
        for th in THRESHOLDS:
            if th in crossings:
                out(f"  position: diverged past {th:>4.0f} units at t={crossings[th]:.1f} s")
        out(f"  position: max divergence {max_delta:.0f} units at t={max_delta_t:.1f} s")
        out(f"  >>> look at t={first:.1f} s in both traces: the first divergence is the finding; the rest is drift")
    aligned_until = first if first is not None else end

    # Jump shape while the runs were still on the same path.
    ref_segs = [s for s in airborne_segments(ref) if s[0] + s[1] <= aligned_until]
    run_segs = [s for s in airborne_segments(run) if s[0] + s[1] <= aligned_until]
    out(f"  airborne segments while aligned (first {aligned_until:.1f} s): ref {len(ref_segs)}, run {len(run_segs)}")
    for i, (rs, qs) in enumerate(zip(ref_segs, run_segs)):
        d_dur, d_apex = qs[1] - rs[1], qs[2] - rs[2]
        flag = " <-- " if abs(d_dur) > 0.1 or abs(d_apex) > 10 else ""
        out(f"    seg {i + 1} at t={rs[0]:.1f}: duration {rs[1]:.2f} vs {qs[1]:.2f} s ({d_dur:+.2f}), "
            f"rise {rs[2]:.0f} vs {qs[2]:.0f} ({d_apex:+.0f}){flag}")

    out(f"  movement mode: differs {100.0 * mode_mismatch / total:.1f}% of the time")
    for t0, ma, mb, t1 in mode_intervals[:8]:
        if t1 - t0 >= 0.2:
            out(f"    {t0:.1f}-{t1:.1f} s: ref {mode_name(ma)}, run {mode_name(mb)}")
    out(f"  montage: differs {100.0 * montage_mismatch / total:.1f}% of the time")
    for (ma, mb), t0 in sorted(montage_pairs.items(), key=lambda kv: kv[1])[:8]:
        out(f"    first at {t0:.1f} s: ref {ma}, run {mb}")
    out(f"  charging: differs {100.0 * charging_mismatch / total:.1f}% of the time")
    out(f"  run ended at {run[-1]['t']:.1f} s of the take's {ref[-1]['t']:.1f} s"
        + (" (cut short)" if run[-1]["t"] < ref[-1]["t"] - 1.0 else ""))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="*", help="ref.csv run.csv [run2.csv ...]")
    ap.add_argument("--dir", help="probe mod folder holding the replay_*.csv files")
    ap.add_argument("--take", help="take id, e.g. LS102_20261115_140000")
    args = ap.parse_args()

    if args.dir and args.take:
        ref_path = os.path.join(args.dir, f"replay_{args.take}_ref.csv")
        run_paths = sorted(glob.glob(os.path.join(args.dir, f"replay_{args.take}_run*.csv")))
        report = os.path.join(args.dir, f"replay_{args.take}_compare.txt")
    elif len(args.files) >= 2:
        ref_path, run_paths = args.files[0], args.files[1:]
        report = None
    else:
        ap.error("give --dir and --take, or a ref.csv and at least one run.csv")
    if not os.path.exists(ref_path):
        sys.exit(f"{ref_path} is missing")
    if not run_paths:
        sys.exit(f"no runs for this take yet (replay one with End)")

    lines = []
    def out(s):
        print(s)
        lines.append(s)
    ref = read_trace(ref_path)
    out(f"ref: {os.path.basename(ref_path)} ({ref[-1]['t']:.1f} s, {len(ref)} frames)")
    for p in run_paths:
        m = re.search(r"_run(\d+)_", os.path.basename(p))
        label = f"{os.path.basename(p)}" + (f" [{m.group(1)} FPS cap]" if m else "")
        compare(ref, read_trace(p), label, out)
    if report:
        with open(report, "w") as f:
            f.write("\n".join(lines) + "\n")
        print(f"\nwritten: {report}")


if __name__ == "__main__":
    main()
