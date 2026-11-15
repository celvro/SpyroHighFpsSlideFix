---
name: level-replay
description: Record a hand-played run of a Spyro Reignited level as an input take, replay it at other framerates and compare the traces to find where physics or animations diverge. Use when asked to record or replay a playthrough, test a whole level across FPS, capture inputs for later replay, or check where a level's gameplay first drifts at high framerates.
argument-hint: [level e.g. LS102] [caps e.g. 30,60,320]
---

# Level replay: record once, replay at every framerate

The world tour plays eight-second preset scripts on teleported stops; this plays a **whole level of
real inputs**. The user plays the level once while `tools/replay.lua` (in `ue4ss/DevMods/SpyroFpsProbe`)
records every input; replays re-inject those inputs from the same start at any `t.MaxFPS` cap and
write a trace per run; `tools/compare_replays.py` says where the runs part ways. Takes are kept on
disk per level, so a library of them builds up — including short, targeted takes that go straight
at a bug found late in a full run.

It is **free-run**: nothing corrects the course. The left stick is camera-relative, so after the
first real physics difference (a jump lands short, a glide falls low) the runs separate for good.
**The first divergence is the finding; everything after it is drift.** That is by design — ask the
user to record a shorter take straight to anything suspected later in the level.

## Workflow

1. **Deploy** if the repo's probe Lua is newer than the deployed copy — game closed first
   (`tools/Install-UE4SS.ps1 -ModsOnly -Probe`; deploying into a running game can crash UE4SS).
   Run `tools/Check-Lua.ps1` after any Lua edit.
2. **Record** (the user does this; Claude cannot play the game):
   - Enter the level fresh, stand at the start, set the cap the take should be recorded at (F5 = 30).
   - Press **Home**, play the level start to finish, press **Home** again.
   - Avoid dying mid-take (the respawn teleport is recorded as play). The log line
     `replay: take <id> saved` names the take.
3. **Replay** (the user, or any unattended wrapper that can send keys):
   - In the same level: press the cap key (F5/F6/F7/F8), then **End**. The probe reloads the
     gameplay sublevels, places Spyro on the take's start, and plays it out; **End** again aborts.
   - **End** (nothing running) opens an on-screen take picker (a UMG overlay -- PrintString is
     compiled out of this Shipping build); **Up/Down** move through the takes for this level; **End**
     again plays the selected one (newest if unmoved). The overlay shows `[REC]`/`[PLAY]` status, and
     every selection/status is logged too, so the picker also works from the UE4SS console.
   - One run per cap.
   - **Always include a run at the take's own cap.** A 30→30 pair that diverges early means the
     capture or the start state is broken (read the `replay:` log lines — a button channel that
     could not be hooked is named there), and other caps prove nothing until it is clean.
4. **Compare** (Claude, in the Cowork VM — the game PC has no Python):
   ```
   python3 tools/compare_replays.py --dir "<game>/Falcon/Binaries/Win64/ue4ss/Mods/SpyroFpsProbe" --take LS102_<stamp>
   ```
   It prints and writes `replay_<take>_compare.txt`: first divergence time at 25/100/500 units,
   jump durations and rises while still aligned, movement-mode / montage / charging mismatch
   timelines, and whether a run died or was cut short.

## Reading the result

- Jump segments flagged `<--` while aligned (duration off by > 0.1 s, rise by > 10 units) are the
  jump-height / hover class of bugs — exactly what `docs/findings/jump-glide.md` measured.
- A montage or mode mismatch that starts **before** the position diverges is an animation finding
  in its own right; one that starts after is drift.
- A run that **DIED** where the recording did not is a finding on its own (the log says so too).
- Divergence at the very first seconds of every run, at every cap, is harness noise (start state,
  camera yaw, a missing button channel), not a bug. Fix the harness first.
- **Open issue (2026-11-15): even a 30->30 replay is not yet movement-exact** -- walking heading
  drifts a few degrees in the first seconds before converging (LS102). The opening ~2 s is not a
  trustworthy baseline yet; see the replay section of `docs/probe.md` for candidate causes.
- Treat a single run like a single tour flag: **re-run it before believing it** — same cap, same
  take, twice. A real difference repeats with the same sign at the same spot.

From a confirmed divergence, carry on with the `spyro-fps-bug-hunt` skill: quicksave V/B at the
divergence spot to repro by hand, the matching tracker in the probe's `config.lua`, then the static
pass and the fix recipe in `CLAUDE.md`.

## Files (flat in the deployed probe folder)

| File | What |
|---|---|
| `replay_<level>_<stamp>_inputs.csv` | the take: one row per recorded frame, axes + buttons |
| `replay_<level>_<stamp>_ref.csv` | the trace recorded alongside the take |
| `replay_<level>_<stamp>_run<cap>_<t>.csv` | one replay run's trace |
| `replay_<take>_compare.txt` | the comparison report |
| `replay_takes.txt` | the index; End replays the last line for the current level |

Positions in the traces are level-origin-relative (the same level streams in at a different
LevelTransform per load). Takes live only in the deployed folder, like `routes.txt` — copy the
`_inputs.csv` of any take worth keeping into the repo before an uninstall, or it is gone.

## Limits

- Spyro only for now (the axes read `CharacterInputComponent_Spyro`); other playable characters
  need their component names wired into `tools/replay.lua`.
- FaceTop (FreeLook) is never captured or replayed; DPad and menu/HUD input are not captured, so a
  take must not open menus.
- Conversations and cutscenes are pressed through during a replay the way the world tour does it,
  so their timing can shift by a second or two against the recording; expect mode/montage mismatch
  stretches around them and do not count those as findings.
