# Frame-rate ceiling: what the mods cost (2026-11-19)

Uncapped replays reached only ~196–265 FPS (Stone Hill ~250–265, Zephyr ~200–220) with both mods and the
probe's trace on. Question: how much of that is the two Lua mods?

**Answer: the probe was the big one, ~0.8 ms of CPU a frame, and it is now ~0.1–0.2 ms.** Most of it was
`UEHelpers.GetPlayerController()` (an object-array walk) called twice a frame. The fix mod costs 0.22 ms a frame
in Zephyr and 0.40–0.45 ms in Stone Hill, most of that the new NPC walk fix (`fixes/npcwalk.lua`). UE4SS's own
global hooks cost nothing measurable. The GPU is never the limit (busy ~1.7–2.1 ms a frame). Frames also stop
at a 320 FPS cap (3.125 ms) outside the game, so "320+" is not reachable on this machine whatever the mods do.

## How it was measured

- **Frame times come from PresentMon 2.2.0**, the copy installed with CapFrameX
  (`C:\Program Files (x86)\CapFrameX\PresentMon\PresentMon-2.2.0-x64.exe`). It needs no admin because the user is
  in *Performance Log Users*. Command: `--process_name Spyro-Win64-Shipping.exe --timed 6 --terminate_after_timed
  --no_console_stats --output_file x.csv`. Columns used: `FrameTime`, `CPUBusy`, `CPUWait`, `GPUBusy`.
  `tools/Measure-FrameTime.ps1` wraps it.
- **Spyro stood still at the level start**, where `Restart-Game.ps1`, `travel` and `swap` put him (Zephyr rel
  -2931,-2790; Stone Hill rel -1598,2184). The camera was left alone.
- **The probe was switched on and off at runtime, with no restart.** An `eval` replaces the global `pcall` with a
  wrapper. When `_G.PERF.off` is set and the wrapper is handed main.lua's `sample` (found as the main.lua function
  with a `setFpsCap` upvalue), it runs only `cmd.update`, so the command channel still works. The probe's hooks
  and `NotifyOnNewObject` callbacks stay registered. Each pair of rows below alternated on/off in 6–8 s windows,
  4 rounds per configuration.
- **Turning the fix mod off meant restarting the game**, with its `enabled.txt` renamed while the game was closed.
- **Same-session on/off differences are reliable to ~0.05 ms.** Comparisons across restarts are only good to
  about ±0.2 ms.
- **The game window was in the background** (the Claude app had focus) for every measurement.

## Results (averages over 3–4 windows; "CPU" = PresentMon CPUBusy)

| Session | Level | Probe | Fix mod | FPS | Frame ms | CPU ms |
|---|---|---|---|---|---|---|
| S1 old probe, fresh | Zephyr LS213 | on | on | 248 | 4.04 | 3.91 |
| | | sample off | on | 283 | 3.53 | 3.07 |
| S1 old probe, after swap | Stone Hill LS102 | on | on | 282 | 3.54 | 3.17 |
| | | sample off | on | 315 (cap) | 3.17 | 2.37 |
| S2 new probe, fresh | Stone Hill LS102 | on | on | 316 (cap) | 3.17 | 2.25 |
| | | sample off | on | 319 (cap) | 3.13 | 2.14 |
| S2 new probe, after swap | Zephyr LS213 | on | on | 282 | 3.55 | 3.12 |
| | | sample off | on | 299 | 3.35 | 2.88 |
| S3 new probe, fresh | Zephyr LS213 | on | **off** | 305 | 3.28 | 2.84 |
| | | sample off | **off** | 313 | 3.19 | 2.79 |
| S5 new probe, UE4SS `HookAActorTick`/`HookUObjectProcessEvent` = 0 | Stone Hill LS102 | on | on | 316 (cap) | 3.17 | 2.32 |
| | | sample off | on | 319 (cap) | 3.13 | 2.22 |

- **Probe cost, measured on vs off in the same session**: 0.85 ms CPU in Zephyr and 0.80 ms in Stone Hill with the
  old probe. With the new probe it is 0.11 ms in Stone Hill, 0.24 ms in Zephyr after a game swap, and 0.06 ms in
  Zephyr fresh. In Zephyr that is 248 → 282–305 FPS, and Stone Hill now sits on the cap with the probe on.
- **What is left with the probe sample and the fix mod both off**: 2.8 ms CPU in Zephyr, about 350 FPS before the
  cap. That is the game itself, plus UE4SS, plus one Lua callback a frame.
- **The 320 cap is outside the game.** Frames bunch at exactly 3.125 ms (the monitor is 320 Hz) and `CPUWait` rises
  as they do. The game presents with SyncInterval 0 and tearing allowed (Hardware: Independent Flip), so the cap
  is the driver's: G-SYNC with V-Sync, or a Max Frame Rate setting. `t.MaxFPS 0` cannot get past it.
- **Not measured: the game without UE4SS.** Getting from the title screen into a level needs the probe's resume.
  But turning off UE4SS's two engine-wide hooks did nothing (S5 vs S2: 2.22 vs 2.14 ms, within noise), so UE4SS
  alone is not the ceiling.
- **The replays' 196–265 FPS included more than these idle numbers.** A replay moves through the level, writes
  `REPLAY_ACTORS` rows (0.11 ms in Stone Hill, `docs/probe.md`), sends real keys, and had the old probe's 0.8 ms on
  top.

## Inside the probe (old code, Zephyr, runtime timers)

The timers were installed with `eval`: each per-frame function was wrapped with a `GetAccurateRealTime` clock
costing 3.3 µs per read, and that clock cost was subtracted from each figure. The whole `sample()` came to
≈0.68 ms net:

| Item | ms/frame |
|---|---|
| `UEHelpers.GetPlayerController()` ×2.1 (main.lua `sample`, `lib/resume.lua`, cmd polls) — `FindAllOf("PlayerController")`, 0.075 ms each | 0.25 |
| `row.build` (ROW_CAMERA 0.04, ROW_STICKS 0.011, ROW_CHARGE_TAG 0.015, the rest unconditional) | 0.19–0.22 |
| `trace.writeRow` (TRACE) | 0.034 |
| `tools/replay.lua` `update` while idle | 0.025 |
| `cmd.update` | 0.02 |
| `minigame.update` (a failed `fopen` of `minigame.txt` every frame, 11 µs) | 0.01 |
| every tracker and tool `update` together | < 0.03 |

The rest of the 0.8 ms measured on vs off is outside `sample()`: garbage collection of the ~17 KB a frame the
probe allocates (~4.6 MB/s at 270 FPS), and UE4SS's per-frame callback.

**Fixed (deployed, measured above as S2/S3):**
- `lib/controller.lua` (new) keeps the PlayerController while `IsValid()` holds and searches again at most every
  0.25 s when there is none, the way the fix mod's `engine.getPlayerController` does. `main.lua` `sample` and
  `lib/resume.lua` use it. The resume still gets back from the title screen (12 s and 40 s in this session's
  restarts).
- `tools/minigame.lua` looks for its trigger file every 10 frames instead of every frame.
- `lib/row.lua` reuses one `IGetIsCharging` out table instead of making a new one every frame (see the leak below).
- Not changed: `lib/cmd.lua`'s `context()` still calls `UEHelpers.GetPlayerController()`, but only every 10th frame
  (POLL_FRAMES) or when a command is queued, ≈0.008 ms/frame.

## Inside the fix mod (`PROFILE` + `GC_PROFILE`, standing still)

| Level | fixes avg | share of frame | allocation | of which NPC walk fix | worst frame in a 10 s window |
|---|---|---|---|---|---|
| Zephyr LS213 (Sergeant Tub) | 0.22–0.23 ms | 6.3–6.8% | 4.39 KB/frame | 2.24 | 22.6 ms (a collection freeing 16.2 MB) |
| Stone Hill LS102 (8 rams) | 0.40–0.45 ms | 12.1–13.6% | 14.8 KB/frame | 12.6 | 81.9 ms (a collection landed inside) |

The rest is camera centering switch 0.78, walking 0.64 and the tick's own reads 0.73 KB/frame, the same as in
2026-09 (`docs/ue4ss.md`). "fixes avg" includes the collector's incremental steps, which run inside whatever
code allocates. So the more garbage a fix makes, the more of the collector's time it is charged with.

**`fixes/npcwalk.lua` costs ~38 µs plus ~1.6 KB of garbage per walker per frame, even while the walker stands
still.** For every walker, every frame, `correct()` reads `actor.CharacterMovement` and calls
`IsComponentTickEnabled`, `IsPlayingRootMotion`, `GetWorldDeltaSeconds` (twice when tracked),
`K2_GetActorLocation`, `RequestedVelocity`, `Velocity` and `GetCurrentAcceleration`. Only then does it return on
"standing still". The garbage is enough for a collection every few seconds at 300 FPS, and each collection is a
20–80 ms hitch. Players get that too, not just the probe.

Per-call prices in this UE4SS build (probe `eval`, 5000–20000 calls each): `IsValid` 0.2 µs, primitive property
read 0.4, object property read 1.0, struct property read (`Velocity`, `RequestedVelocity`) 0.8,
`cmc.Acceleration` read 2.0, `GetWorldDeltaSeconds` 2.0, `IsComponentTickEnabled` 5.6, `GetCurrentAcceleration`
6.0, `IsPlayingRootMotion` 9.0, `K2_GetActorLocation` 11.8. A UFunction call is 5–12 µs, a property read about
1 µs.

**Fixed (2026-11-19).** `fixes/npcwalk.lua` now:
- Checks an idle walker (not tracked, not stepping, not blocked) with property reads only: `Velocity`, then
  `RequestedVelocity`, then `Acceleration`, and returns before the UFunction calls when it is standing still.
- Looks at an idle walker again only every 1/120 s (a quarter of a 30 FPS frame, so a move start is still seen
  inside the 30 FPS frame it falls in; frames of 1/120 s or longer look every frame). Each struct read is a new
  Lua table of ~260 B, so the fast path alone still left 8 idle rams at 6.2 KB/frame.
- Reads the frame's world delta once, from the player controller.
- Keeps each walker's `CharacterMovement` once it has existed for 0.5 s and the component has a movement mode.

Two of those broke Sergeant Tub on the way (he never left the cannon after a probe reset), and both are
written up in the code:
- **Sharing the first walker's world delta.** The streamed-out Tub stayed valid for a while with a world delta
  of 0, so the new Tub's idle wait never counted down.
- **Keeping the component from the first frame.** The reloaded Tub's component was replaced after he was
  registered, and the kept one stayed valid at mode 0 with no velocity.

Measured in Stone Hill (8 idle rams, ~320 FPS, `PROFILE` + `GC_PROFILE`): fixes avg **0.40–0.45 → 0.19–0.20
ms**, allocation **14.8 → 4.4 KB/frame**, of which the NPC walk fix **12.6 → 2.25**. The fix mod's 4.4 KB is
the same as Zephyr's before this fix existed. Behaviour unchanged:
- Rams: t90 0.32 s in 4 uncapped runs of `LS102_20261116_233040`, against 0.33 at 30 FPS.
- Tub: walks off from a probe reset and stops at (−3661 to −3662, 1482) in 3 runs, against 30 FPS's
  (−3665, 1480).

**The suggestion this followed (written before the fix):**
- Check an idle walker first, using property reads only (`Velocity`, `RequestedVelocity`, and the `Acceleration`
  property, which holds what `GetCurrentAcceleration` returns). Do that for walkers that are not tracked, not
  stepping and not blocked, and skip the calls when it is idle. This should bring an idle ram down to about 5 µs
  and well under 1 KB.
- Keep each walker's `CharacterMovement` (as `engine.characterMovement` does for the pawn).
- Read `GetWorldDeltaSeconds` once per frame for all of them: it is the same world.
- That would save about 0.3 ms a frame in Stone Hill, and most of the fix mod's garbage.

## UE4SS leaks a registry reference for every out-param table

In the deployed UE4SS (v3.0.1-1133, built 2026-09-20), every UFunction call that is passed a table for an out
param `luaL_ref`s the table and never releases it. Measured with `#debug.getregistry()` over 1000 calls:

- `GetAccurateRealTime(ctx, {}, {})`: +2000 entries.
- `IGetIsCharging({})`: +1000, and the same with a reused table.
- `cmc.Velocity` and `K2_GetActorLocation()`: +0.

Upstream fixed this in `5e627997b` (2026-10-09, `LuaUObject.cpp`, `luaL_unref` after the out-params are copied
back). The user's clone `~/code/RE-UE4SS` already has that commit, so the v4 upgrade planned in `docs/ue4ss.md`
brings the fix.

What it costs until then:
- **A reused out table leaks only a registry slot.** A fresh table every call leaks the table as well. The probe's
  `row.build` made a fresh one every frame, which is now fixed.
- **The registry is one table, and the collector marks it in one step.** A registry of millions of entries makes
  every collection cycle slower. The runtime timers above read `GetAccurateRealTime` ~60 times a frame and drove
  the probe's registry to 3.26 M entries in a few minutes; a full collect then took 131 ms with 130 MB live, and
  only a restart clears that.
- **Both mods' `PROFILE` read the clock with two out tables.** So a long profiling session slowly gets slower;
  keep profiling runs short.
- **The fix mod's own out-param calls are rare**: `spyro.isCharging` only while charging; the balloon, dragon and
  glide `SweepHitResult`s only on corrected frames.

## Other things checked

- **UE4SS's default mods** (BPModLoaderMod, ConsoleEnablerMod, CheatManagerEnablerMod, ConsoleCommandsMod,
  BPML_GenericFunctions, Keybinds, enabled in `ue4ss/Mods/mods.txt`) do no per-frame work. They only register
  hooks for level loads, `ClientRestart` and console commands.
- **`StaticFindObject` misses**: none per frame in either mod. The probe's `FindAllOf` calls outside the two
  `GetPlayerController` calls run once per run or per level (`actortrace.open`, `invuln` once per pawn,
  `playerready`/`actorstart` at resets).
