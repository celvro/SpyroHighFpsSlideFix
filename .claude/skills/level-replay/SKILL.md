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

## Keys (the idle overlay lists them in game)

| Key | Does |
|---|---|
| Home | record a take; again to stop |
| End | take picker / play selected / abort a running replay |
| PageUp | reset the level: reload gameplay sublevels, Spyro to the selected take's start (no playback) |
| Up/Down | move through the picker (game-bound too — only with the picker open, standing still) |
| F5/F6/F7/F8 | cap 30 / 60 / 120 / uncapped |

## Workflow

1. **Deploy** if the repo's probe Lua is newer than the deployed copy — game closed first
   (`tools/Install-UE4SS.ps1 -ModsOnly -Probe`; deploying into a running game can crash UE4SS, and
   a hot reload after a mid-run copy does not reliably pick the new code up — **restart the game**
   to be sure, see the `restart-game` skill). Run `tools/Check-Lua.ps1` after any Lua edit.
2. **Record** (the user, or Claude holding keys through computer use for simple takes):
   - Enter the level fresh, stand at the start, set the cap the take should be recorded at (F5 = 30).
   - Press **Home**, play the level start to finish, press **Home** again. When Claude starts and
     stops the take for someone playing, use `Invoke-Probe.ps1 cap 30`, then `replay-record start`,
     then `replay-record stop`. Stop answers with the saved take's id, so there is no need to read
     the log, and no key goes to the game window, which the player is using. Movement still needs
     the player, or computer use holding keys.
   - Avoid dying mid-take (the respawn teleport is recorded as play). The log line
     `replay: take <id> saved` names the take.
   - Mouse camera look IS captured — not as an axis, but as the camera rotation per frame (see
     take format below). Takes recorded before 2026-11-16 predate this and replay with the camera
     running free, losing any mouse look.
3. **Replay** (the user, or from a script with no keys at all:
   `tools\Invoke-Probe.ps1 replay take=<id> cap=320 -Timeout 600` plays one take and returns when it
   ends, with the trace path; `takes` lists them, `replay-reset` is PgUp, `replay-abort` is End.
   See "Command channel" in `docs/probe.md`):
   - In the same level: press the cap key, then **End**. The probe reloads the gameplay sublevels,
     places Spyro on the take's start, restores the recorded camera heading and control rotation,
     and plays it out; **End** again aborts.
   - **End** (nothing running) opens an on-screen take picker (a UMG overlay — PrintString is
     compiled out of this Shipping build); **Up/Down** move through the takes for this level; **End**
     again plays the selected one (newest if unmoved). Every selection/status is logged too, so the
     picker also works from the UE4SS console.
   - One run per cap. **Replays of one take are deterministic** (two 30→30 runs of the same take
     matched each other to the frame, 2026-11-15), so a second run checks the harness, not the game.
   - **Always include a run at the take's own cap.** A 30→30 pair that diverges early means the
     capture or the start state is broken (read the `replay:` log lines — a button channel that
     could not be hooked is named there), and other caps prove nothing until it is clean.
   - **Breakables and enemies do not reset with the level reload**: chests and barrels already
     smashed before a replay stay gone, so a take that breaks things only compares cleanly against
     a fresh level entry. PageUp alone is not enough after such a take; leave and re-enter.
4. **Compare** (Claude, in the Cowork VM — the game PC has no Python):
   ```
   python3 tools/compare_replays.py --dir "<game>/Falcon/Binaries/Win64/ue4ss/Mods/SpyroFpsProbe" --take LS102_<stamp>
   ```
   It prints and writes `replay_<take>_compare.txt`: first divergence time at 25/100/500 units,
   the movement the CMC consumed around the first half-unit gap (`acc`/`last`/`pend` columns),
   jump durations and rises while still aligned, movement-mode / montage / charging mismatch
   timelines, and whether a run died or was cut short.
5. **Every other character** (on the game PC, PowerShell; never read the CSVs themselves):
   ```
   tools\Compare-ReplayActors.ps1 -Take LS102_<stamp> [-Class Ram]
   ```
   Each replay also writes `replay_<take>_run<cap>_<t>_actors.csv`: every character's position and
   velocity per frame (`lib/actortrace.lua`, config `REPLAY_ACTORS`). The script compares the newest
   30 FPS run with the newest run at another cap and prints, per class and per character, the largest
   position gap and when it passed 5 units, and for every move from a standstill the time to 50/90% of
   its top speed (`t50`/`t90`) and the distance in its first 0.5 s (`d0.5`). A slow starter at high FPS
   shows as a longer t90 and a shorter d0.5. Gaps after Spyro's own run has drifted (or after he
   touched the character) are drift; the per-move acceleration numbers are not.

## Reading the result

- Jump segments flagged `<--` while aligned (duration off by > 0.1 s, rise by > 10 units) are the
  jump-height / hover class of bugs — exactly what `docs/findings/jump-glide.md` measured.
- A montage or mode mismatch that starts **before** the position diverges is an animation finding
  in its own right; one that starts after is drift.
- A run that **DIED** where the recording did not is a finding on its own (the log says so too).
- Divergence at the very first seconds of every run, at every cap, is harness noise (start state,
  camera yaw, a missing button channel), not a bug. Fix the harness first.
- **Fidelity (2026-11-16): a 30->30 replay matches its recording frame for frame, keys and gamepad.**
  - The left stick goes out the way the engine sends it (`input.sendLeftStick`: walking consumes
    |(x_k, y_(k-1))| + |(x_k, y_k)| a frame).
  - The stored stick the charge reads is restored every frame, and since 2026-11-19 the stored
    right-stick X too, which is what mouse charge steering reads (before, a mouse-steered charge went
    straight in the replay).
  - The camera is set to the ended frame's heading before the sticks, and to the next frame's after
    them, unless the game is turning it itself (charge centering).
  - Keyboard takes match to 0.03 units. A 21 s gamepad take with charges and jumps kept Spyro's yaw
    within 0.03 deg and drifted 3.3 units, from 4-decimal stick rounding (takes are full precision now)
    and frame pacing.
  - Frame pacing is the noise floor: 1-2% of frames run up to 0.25% long, moving Spyro a float32 step,
    which a wall contact can grow to about 1 unit. A 30->30 pair that drifts by more than a few units
    is a harness problem worth reading. Details in the replay section of `docs/probe.md`.
- **Across caps, read the time-based lines only.** The "first frame >0.5 units apart" block indexes
  frames by number, which is meaningful only when both runs are at the same cap.
- **Enemies repeat at 30->30 but not across caps.** A take that meets an enemy compares cleanly only
  up to the meeting. A hit (`Damage_Knockback` montage) in either run marks it.
- **Fodder can make a run diverge (2026-11-17).** Fodder wander and pick their states at random, with
  no seed, so they stand somewhere else on every run. A bug critter blocked a replay walking to Tub's
  cannon in Zephyr. The fodder capsules themselves don't block Spyro, so what does is still unknown
  (`docs/probe.md`). A run that meets a critter the recording didn't is noise, not a finding. Making
  fodder ignore Spyro during replays was dropped on 2026-11-19 (the user's call): treat such a run as
  noise and record another take rather than chase it.
- **NPCs can be talked to after a reset (2026-11-17/18).** The reset's sublevel reload skips two
  level-start events, and each alone stopped every conversation in the level:
  - the player-ready event, which every NPC dialogue selector (`IGC_Selector_C`) needs to pick its
    conversation;
  - the game state change, which every dialogue/cutscene (`Spyro_IGC_Base_C`) needs before it plays
    (`GameState_CutsceneReady`).
  So after PgUp or End, Spyro walked up to Zephyr's Sergeant Tub and no conversation played, and Tub
  stayed on his cannon. The probe now re-sends both to the reloaded actors (`lib/playerready.lua`,
  config `REPLAY_PLAYER_READY`; log line `replay: PlayerReady sent to N ..., game state 3 sent to M ...`).
  Verified with `LS213_20261117_161516`: intro plays, the take's own Space presses close it, Tub walks off.
  A conversation that waits for the talk button still cannot be started by a replay: that is FreeLook
  (FaceTop), which takes never capture. One that starts on its own now starts again after every reset.
- First uncapped results (2026-11-16, ~250 FPS): walking, braking, charge speed and jump arcs match 30.
  The first real difference found is the 8-way input snap below 75% walk speed, decided per frame
  (`docs/findings/sliding-walking.md`): starting off from rest with a slightly off-axis stick, facing
  can differ by 10+ deg within one frame.
- Treat a single cross-cap difference like a single tour flag: **re-run it before believing it.**

From a confirmed divergence, carry on with the `spyro-fps-bug-hunt` skill: quicksave V/B at the
divergence spot to repro by hand, the matching tracker in the probe's `config.lua`, then the static
pass and the fix recipe in `CLAUDE.md`.

## Files (flat in the deployed probe folder)

| File | What |
|---|---|
| `replay_<level>_<stamp>_inputs.csv` | the take: one row per recorded frame — stored axes + buttons, raw left stick (`rlx,rly`), camera rotation (`cpitch,cyaw`) |
| `replay_<level>_<stamp>_ref.csv` | the trace recorded alongside the take |
| `replay_<level>_<stamp>_run<cap>_<t>.csv` | one replay run's trace |
| `replay_<take>_compare.txt` | the comparison report |
| `replay_takes.txt` | the index; End replays the last line for the current level |

Traces also carry diagnostic columns: `acc` (CMC current acceleration), `last`/`pend` (pawn
movement-input vector lengths) and `ami` (every AddMovementInput call that frame, `x|y|scale;...`).
Positions are level-origin-relative (the same level streams in at a different LevelTransform per
load). Takes live only in the deployed folder, like `routes.txt` — copy the `_inputs.csv` of any
take worth keeping into the repo before an uninstall, or it is gone.

## Limits

- Spyro only for now (the axes read `CharacterInputComponent_Spyro`); other playable characters
  need their component names wired into `tools/replay.lua`.
- FaceTop (FreeLook) is never captured or replayed; DPad and menu/HUD input are not captured, so a
  take must not open menus.
- A camera-driven replay (any take from 2026-11-16 on) no longer exercises the game's own camera
  behaviour — camera-centering bugs still need takes judged by eye or the camera trackers.
- A replay only sends the take's own inputs; nothing in it looks for text boxes or cutscenes. Jump
  goes out as a **real Space key** (`lib/realkeys.lua`, `KeyPipe.ps1`), so the presses you made to
  close a conversation close it in the replay too. Record conversations the way you play them.
  Never close a text box by calling its Blueprint functions from Lua: that froze the game
  (2026-11-18, `docs/probe.md`). The log says `replay: playing (Jump as a real Space key)`; anything
  else means the key helper or the Jump hook was not ready and the Jump was injected instead.
