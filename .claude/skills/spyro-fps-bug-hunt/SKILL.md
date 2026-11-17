---
name: spyro-fps-bug-hunt
description: Find, prove and fix framerate-dependent bugs in Spyro Reignited Trilogy (UE 4.19, UE4SS Lua) using this repo's own tools — AssetDump bytecode reading, the SpyroFpsProbe trackers, the world tour, the animation test room and the fix recipe. Use whenever the user reports or suspects something in Spyro behaves differently at high FPS (jumps, glides, charges, camera, enemies, NPCs, minigames, particles, animations), asks to triage a tour or compare-*.txt result, wants to check whether a flagged stop is real, or wants to turn a measured difference into a fix — even if they don't say "framerate bug".
---

# Hunting a framerate bug in Spyro

The goal is always the same: **every framerate must behave like 30 FPS**, the console tuning. A
"fix" that makes 30 FPS behave like 144 is wrong, because some glides are only possible at 30.

This repo already has the measuring tools. Don't write a new harness, don't hook
`Actor:ReceiveTick` globally, don't reach for FModel or `ObjectDump.txt`. Pick the existing tool
that fits the symptom, and spend your effort on deciding whether a difference is real. That
decision is where most of the time went on this project: most flagged differences turned out to be
noise.

Work in these stages. The user may come in partway through (for example "LS322/1556 looks real,
fix it"), so start at the stage that matches.

## 0. Is it already known?

Read the findings table in `CLAUDE.md` and grep `docs/findings/` and the headers of
`ue4ss/Mods/HighFpsSlidingAndJumpFix/Scripts/fixes/*.lua` for the character, level or mechanic.
Plenty of symptoms are already fixed, already measured as matching 30 FPS, or already ruled out
(thief chase: "not worth fixing"; Cupid: an arrow, not the framerate). If a doc exists, read it
before doing anything else. It records the false positives that have already cost days.

## 1. Static pass: read the Blueprint

`build/AssetDump/AssetDump.exe <file.uasset> --code` disassembles the cooked bytecode. Find the
asset under the unpacked `chunk0|1|2\...\Plugins\<Plugin>\Content\` (mount points in `CLAUDE.md`).
Most logic is in `ExecuteUbergraph_<Class>`. Event and timeline stubs jump into it at an offset,
so read from that offset. Timeline lengths are in the `*_Template` exports.

These are the patterns that have actually caused bugs in this game, so look for these first. The
doc in brackets is the worked example.

| Pattern | Why it breaks at high FPS | Example |
|---|---|---|
| Fixed step per tick inside a timeline update or Tick (`+0.5` deg, `Counter + 1`) | Timeline update functions run once per tick, so the step is per frame | balloon-camera |
| Effect or notify that lives for one tick | Emits nothing when the tick is 3 ms | charge-dust, druid-energize |
| A phase measured in whole frames | Rounds to a different real-time length | jump-glide (zero-gravity hover) |
| Low acceleration × tiny dt from rest | The requested move rounds to zero, so the character never starts | buzz-charge-run, sheila-buzz-walk, npc-stalls |
| Position far from origin + small per-frame delta | float32 quantization eats the step | sliding-walking, jump-glide (glide distance) |
| Blocked sweep returning zero displacement | Every blocked frame loses all speed, and there are more of them | charge-wall-stall, skelos-badlands |
| `Velocity` derived from a zero-length frame | NaN latches into anim BP variables | gem-thief-anim |
| Spawn velocity / muzzle offsets per frame | Particles spread differently | flame-breath |
| Segments or followers spaced per tick | They bunch up | fire-dragon |

Skip "turn on substepping" ideas. Never shrink `MaxSimulationTimeStep` below a frame: substeps
reproduce the sliding bug at 30 FPS and poison any comparison.

The static pass tells you where to look. It is not a result. Nothing is a finding until it is
measured.

## 2. Measure it with the right tool

| Suspect | Tool | Read |
|---|---|---|
| One character's animations / montages | the `enemy-animtest` skill (`tools/Test-EnemyAnims.ps1`) | `build\animtest\<stamp>_<enemy>\compare.txt` |
| Spyro's own movement (jump, glide, slide, charge, camera) | the probe (`ue4ss/DevMods/SpyroFpsProbe`) with the matching tracker switched on in its `config.lua`; F5/F6/F7/F8 set `t.MaxFPS` 30/60/120/0; quicksave V/B/L/N to repeat from one spot; G glide test. From a script or a Claude session, send these through `tools/Invoke-Probe.ps1` rather than keys: `cap 320`, `quicksave save`/`load`, `key G`, `teleport ... rel`, `state` | tracker log lines in `UE4SS.log`, `trace_*.csv`, `tools/Compare-Segments.ps1` |
| A stretch of real play (a whole level, or a route to one spot) | the `level-replay` skill: record a take once, then `Invoke-Probe.ps1 replay take=<id> cap=<fps>` per cap | `replay_<take>_compare.txt` (`tools/compare_replays.py`) |
| Unknown: "something somewhere" or many levels | `tools/Tour-Unattended.ps1 -Caps 30,30,60,160 [-Levels ...] [-Scripts ...]` (a night for the full route) | `build\tour\<stamp>\compare-autotest.txt` and `compare-anims.txt`, never the log |
| A minigame | the probe's minigame recorder (M take, F1 mark, F2 retry, cap per take) | `minigame_*.csv` through `tools/Compare-Anims.ps1` |
| Nothing above covers it | a new tracker in the probe's `trackers/`, off by default in `config.lua`, documenting its own log lines | |

Before a run:

- Close the game before deploying (`tools/Install-UE4SS.ps1 -ModsOnly [-Probe]`). Deploying into a
  running game, or Ctrl+R, can crash this UE4SS build. Use `tools/Restart-Game.ps1` to get back
  into the level. Run `tools/Check-Lua.ps1` after any Lua edit.
- The scripts take the game window and the framerate cap. Tell the user before starting if they
  might be playing.
- Switch on only the trackers the run needs. The probe costs game-thread time, so check the
  reached FPS in the output (e.g. `avgFps`). A "320 FPS" pass that ran at 200 didn't test 320.
- With the game running, drive the probe through `tools/Invoke-Probe.ps1` (the `cmd.txt` channel; see
  "Command channel" in `docs/probe.md`), not by sending keys. Every probe hotkey is `key <NAME>`.
  `state` reads the level, cap, reached FPS and position, and `eval <lua>` reads anything else. A
  command sent during a restart or a level load waits for Spyro.
- Trigger files written from PowerShell need no BOM:
  `[IO.File]::WriteAllText(path, text, [Text.UTF8Encoding]::new($false))`. With the game running,
  `Invoke-Probe.ps1 trigger <tool> [options]` has the probe write the file instead. Trigger files are
  still what the unattended scripts use: they are written before a restart and survive a crash.
- Scripts are PowerShell. Python is not installed. Time with the engine's dt or world time.
  `os.clock()` is CPU time.

## 3. Decide whether it is real

This replaces any fixed "% difference" rule. A percentage threshold flagged 426 "findings" in the
first trilogy tour; the checks below left 20.

1. **Noise floor.** Run 30 FPS twice. The second pass is how far the stop lands from itself. A
   high-FPS difference smaller than that means nothing.
2. **Two fast caps must agree.** A framerate cause shows at both 60 and 160 (or 320), in the same
   direction and roughly the same size. A stop that just wandered goes somewhere different each
   time. If the direction flips between levels or runs, it's not the framerate.
3. **Above the frame-quantization bar.** Script presses land on frame boundaries, so a few units
   (two 30 FPS frames of walking, about 18 units) is input timing, not physics.
4. **Same punishment in every pass.** If Spyro was hit or knocked back a different number of times
   (count the damage montages), hold the stop back. `Compare-Autotest.ps1` does this.
5. **Same initial conditions.** A stop that starts a fixed number of *frames* after a teleport
   finds an enemy at a different point in its attack cycle at each cap (Cupid). Check that the
   teleport had landed and that montage positions at t=0 match. Also check where each pass
   started: in the montage sweep, root motion over different ground gave a repeatable false 20%.
6. **Repeat it.** Re-run a flagged montage on its own 2–3 times (`-Montage <name>`). A real
   difference repeats with the same sign and size. Particle counts (`fx`) vary between runs at a
   single cap, so only a difference that holds in every run counts.

When you report, say which of these checks the difference passed, with its numbers: floor, each
fast cap, agreement. "Charge drifts further at high FPS" isn't a finding. This is: "LS322/1556
charge: floor 0, 858 at 60, 898 at 160, agreeing within 91, same hit count".

## 4. Fix it

Follow "Hooking a Blueprint function (fix recipe)" in `CLAUDE.md`. Those steps are what a working
fix needs. The gotchas below are the ones that have crashed the game or wrecked frame time:

- `RegisterHook` on a Blueprint function only calls the pre callback, and it runs **after** the
  body. Register the same idempotent callback as pre and post, and correct the result rather
  than the inputs.
- Never poll `StaticFindObject` / `FindAllOf` for something that may not exist (~10 ms per miss).
  Use `lookup.watch` + `lookup.find`, triggered from `NotifyOnNewObject`.
- `IsValid()` every cached object before each touch. `pcall` does not catch the access violation.
- Empty reused struct out-param tables with `util.clearHit` before every call.
- Use `engine.worldDeltaSeconds(actor)` for dt, and leave frames alone unless
  `util.aboveReferenceFps(dt)`.
- Level Blueprint functions are replaced on each level load. Use `lookup.hookLevelFunction`.
- Add a `FIX_*` switch in `config.lua`, wrap hooks in `profiler.wrapHook`, and keep `PROFILE = false`
  in commits.

**Verify by A/B with the switch.** Measure with the fix off and on, at 30 and at a high cap. The
fix passes when high FPS with the fix matches 30 FPS. 30 FPS must stay the same with the fix on.

## 5. Write it up

- Measurements and conclusions go in the matching `docs/findings/*.md` (or a new one), not in
  `CLAUDE.md`. Include dates, caps and FPS reached, and the false leads you ruled out.
- New doc: add a row to the findings table in `CLAUDE.md` with its status
  (`fixed, verified` / `matches 30 FPS` / `measured, not worth fixing` / `open`).
- A new fix: a header in the fix module summarizing the cause, and a line in the mod's player-facing
  `README.txt` once it's verified.
- If the hunt exposed a harness artefact (the tour measuring something that isn't the game), write
  it in `docs/probe.md` and make the comparison script detect it. That's how the noise checks above
  came about.
