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
                    "cam": float(p[idx["cam_yaw"]]) if "cam_yaw" in idx else float("nan"),
                    "acc": float(p[idx["acc"]]) if "acc" in idx else float("nan"),
                    "last": float(p[idx["last"]]) if "last" in idx else float("nan"),
                    "pend": float(p[idx["pend"]]) if "pend" in idx else float("nan"),
                    "dt": float(p[idx["dt"]]) if "dt" in idx else float("nan"),
                })
            except ValueError:
                continue
    if not rows:
        sys.exit(f"{path}: no rows")
    return rows


def sample(rows, t):
    """The trace's state at time t: positions interpolated, the rest from the row at or before t."""
    import bisect
    # Cached per trace by id(), holding the list itself too: an id is only unique while its object lives,
    # and a freed run's id is handed to the next run read, so a bare id key served the next run the last
    # one's timestamps (every run after the first in a report diverged "at 0.2 s", 2026-11-16).
    hit = sample.cache.get(id(rows))
    if hit is None or hit[0] is not rows:
        hit = (rows, [r["t"] for r in rows])
        sample.cache[id(rows)] = hit
    times = hit[1]
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
    # Angles too, the short way round. Taken from the row at or before t they flagged false yaw
    # differences: a replay's timestamps run a few 1e-5 s off the recording's, so a grid point can land
    # between the two traces' rows for the same frame, and during a turn of 25 deg a frame one trace
    # reported frame k and the other frame k-1 (14-21 deg "off" on runs that match frame for frame to
    # 0.02 deg, 2026-11-16). It also settles the one-sample ~100 deg camera spikes at a camera snap.
    for k in ("yaw", "cam"):
        if a[k] == a[k] and b[k] == b[k]:  # neither is NaN
            out[k] = a[k] + ((b[k] - a[k] + 180.0) % 360.0 - 180.0) * f
    return out


sample.cache = {}


def yaw_diff(a, b):
    return abs((a - b + 180.0) % 360.0 - 180.0)


def airborne_segments(rows):
    """(start t, duration, apex rise) of every Falling stretch — the jump/glide/fall shape."""
    # Measured from the last ground row before the launch: from the first Falling row, a trace at 30 FPS
    # had already risen a whole frame (~7 units at 209 u/s) and an uncapped one under 1, so every jump
    # compared 6 units "higher" uncapped when the probe's own apex matched to 0.04 (2026-11-16). Timed from
    # that ground row too, since a jump launches at the start of the frame whose row first reads Falling,
    # and to halfway between the rows either side of the landing, which happens somewhere inside a frame.
    segs, start, z0, apex = [], None, 0.0, 0.0
    prev = None
    for r in rows:
        if r["mode"] == 3:
            if start is None:
                start = prev["t"] if prev else r["t"]
                z0 = prev["z"] if prev else r["z"]
                apex = r["z"]
            apex = max(apex, r["z"])
        elif start is not None:
            end = (prev["t"] + r["t"]) / 2
            segs.append((start, end - start, apex - z0))
            start = None
        prev = r
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
    cam_first = yaw_first = None       # first time camera / Spyro yaw is > 2 deg off the recording
    cam_max = yaw_max = 0.0
    early = []                         # (t, yaw diff, cam diff) at 0.5 s steps for the first 3 s
    for i in range(n + 1):
        t = min(i * GRID, end)
        a, b = sample(ref, t), sample(run, t)
        d = math.dist((a["x"], a["y"], a["z"]), (b["x"], b["y"], b["z"]))
        if d > max_delta:
            max_delta, max_delta_t = d, t
        for th in THRESHOLDS:
            if th not in crossings and d > th:
                crossings[th] = t
        yd, cd = yaw_diff(a["yaw"], b["yaw"]), yaw_diff(a["cam"], b["cam"])
        yaw_max = max(yaw_max, yd)
        if yd > 2.0 and yaw_first is None:
            yaw_first = t
        if cd == cd:  # not NaN
            cam_max = max(cam_max, cd)
            if cd > 2.0 and cam_first is None:
                cam_first = t
        if t <= 3.0 and i % 5 == 0:
            early.append((t, yd, cd))
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

    # What the movement consumed on the frames just before and at the first frame where the runs part by more
    # than half a unit (acc = CMC acceleration, last/pend = the pawn's movement input vector lengths).
    # Needs a ref and run recorded with the acc/last/pend columns (tools/replay.lua, 2026-11-15).
    k = next((j for j in range(min(len(ref), len(run)))
              if math.dist((ref[j]["x"], ref[j]["y"]), (run[j]["x"], run[j]["y"])) > 0.5), None)
    if k is not None and ref[k]["acc"] == ref[k]["acc"]:
        out(f"  first frame >0.5 units apart: #{k} (t={ref[k]['t']:.2f} s); acc / last / pend, ref vs run:")
        for j in range(max(0, k - 2), min(len(ref), len(run), k + 4)):
            a, b = ref[j], run[j]
            out(f"    #{j}: acc {a['acc']:7.1f} vs {b['acc']:7.1f}   last {a['last']:.3f} vs {b['last']:.3f}"
                f"   pend {a['pend']:.3f} vs {b['pend']:.3f}   speed {a['speed']:.0f} vs {b['speed']:.0f}")
    # Heading vs camera. The left stick is camera-relative, so a camera that is off by a few degrees
    # at the start sends the walk off by the same few degrees. If the camera yaw diverges first (or at
    # all) the replay's camera seeding / right-stick path is the cause; if Spyro's yaw diverges while
    # the camera stays on the recording, it is input timing or the movement itself.
    out(f"  Spyro yaw: first >2 deg off at "
        + (f"t={yaw_first:.1f} s" if yaw_first is not None else "never") + f", max {yaw_max:.1f} deg")
    out(f"  camera yaw: first >2 deg off at "
        + (f"t={cam_first:.1f} s" if cam_first is not None else "never") + f", max {cam_max:.1f} deg")
    out("  first 3 s, every 0.5 s (t: spyro yaw diff / camera yaw diff, deg): "
        + "  ".join(f"{t:.1f}: {yd:.1f}/{cd:.1f}" for t, yd, cd in early))
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
