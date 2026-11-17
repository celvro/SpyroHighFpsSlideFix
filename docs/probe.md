# SpyroFpsProbe (dev mod)

## Code layout

`main.lua` holds `sample()` (one row per unpaused frame, handed to every tracker in order), the key binds and the `NotifyOnNewObject` hooks. `lib/row.lua` builds the row, `lib/trace.lua` writes it to `trace_*.csv` (column list there), and `lib/state.lua` holds what trackers share: the previous row, the last 10 rows, and the measurement each tracker has in progress (the CSV's id columns). Each `trackers/*.lua` module documents its own log lines in its header: `movement` (seg/drift/rise), `charge` (charge/turn), `camera` (camlock/camstuck/camtransition/camdump), `supercharge`, `dragons`, `thieves`, `flames` (plus the K experiment), `walkin`, `flight` (Spyro 1 flight levels: per-second speed, MaxFlySpeed ramps, run totals), `hits` (a `ReceiveHit` hook: `hits_*.csv` with every blocking hit during ground charges, and `chargestall` lines when a charge frame loses over half its speed), `buzz` (Spyro 3 boss fight: `buzzrun` lines per moving state of Buzz and Sheila with t50/t90 to MaxWalkSpeed, `buzz_*.csv` per frame per actor including RequestedVelocity, one-off `camdump_*_buzzcmc.txt`/`_sheilacmc.txt` movement component dumps), `stalls` (every NPC/enemy: `stall` lines, `stallsummary` per class, `stalls_*.csv` per movement stretch; see `docs/findings/npc-stalls.md`), `lizard` (Skelos Badlands lava lizards: `lizardstall`/`lizardstep`/`lizardsummary`, `lizard_*.csv` per frame and `lizard_hits_*.csv` from `lib/enemyhits.lua`, the shared hook on BP_Base_Enemy's capsule hit event) (see `docs/findings/skelos-badlands.md`; the steam-vent tracker that lived next to it was removed on 2026-10-06 once the vent measured the same at every framerate), `turtle` (Sunny Beach box turtles: `turtleslide` per charge slide, `turtlestart`/`turtlestall`/`turtlerun` for the walking, `turtle_*.csv` per frame with the character movement component and the projectile movement component side by side plus `turtle_hits_*.csv`, and one-off `turtlecmc`/`turtlepmc` dumps; see `docs/findings/turtle-soup.md`). **J** runs `tools/slide.lua` (starts Spyro's steep-slope slide where he stands for screenshots, press again to end) — **still in progress, not verified in game yet**. The quicksave aid is `tools/quicksave.lua`, with level streaming queries in `lib/levels.lua`. The level tour (**T**, `tools/tour.lua`: every level for 25 s uncapped, for the stall tracker) and the travel test (**Y**, `tools/traveltest.lua`) were removed on 2026-09-22; the world tour (**O**, `tools/worldtour/`) visits every level that has a stop. `config.lua` switches each tracker on or off (see the section below); `lib/profile.lua` times them.

## What the probe costs, and switching it off (config.lua, added 2026-10-10)

The probe samples on the game thread, so every tracker left on is frame time the game doesn't get. At
320 FPS a whole frame is 3.1 ms. The expensive ones are the trackers that walk a list of actors or
write a CSV row per actor per frame (`turtle`, `stalls`, `lizard`, `buzz`, `thieves`, `flames`), the
`trace_*.csv` write (a `string.format` of 60 fields and an `io.write` every frame) and the optional
reflection reads in `lib/row.lua`. **A framerate measured with the probe loaded is not the game's own.**

`Scripts/config.lua` holds a switch per tracker, plus `TRACE` for the per-frame CSV and the `ROW_*`
groups for the camera, stick, charge-tag and dust reads in `lib/row.lua`. Most trackers are off
because their bug is fixed and verified; turn one back on to re-measure it or to pick an
investigation back up. The load line in `UE4SS.log` lists what was on, so a CSV with a blank column
can be traced back to the switches it was recorded with.

A tracker that is off is still loaded, so its constants still read as themselves (`stalls.CLASS`,
`thieves.CLASSES`), but every function on it becomes a no-op: nothing per frame, no log lines, no
CSV. Its `NotifyOnNewObject` registration is skipped when nothing is listening. Two consequences
worth knowing:

- The keys that belong to an off tracker do nothing: F9 and F10 (camera dump, flame rescan), K (the
  flame experiment), T and Y (the gem thief and the NaN sweep).
- `trackers/charge.lua` drives the camera tracker's lock measurements itself, so `camlock` and
  `camstuck` still run while `charge` is on even with `camera` off. The world tour's camera columns
  (`tools/worldtour/samples.lua`) come from `ROW_CAMERA`, not from a tracker — turn it on for a tour.

`PROFILE = true` times each tracker, `row.build` and the trace write into their own buckets with the
engine's clock (`os.clock` is only 1 ms on Windows) and logs a ranked summary every
`PROFILE_INTERVAL` seconds:

```
profile: 2400 frames (avg frame 4.15 ms, 241 FPS), probe avg 0.92 ms/frame (22.2% of frame), max 3.10 ms
profile ms/frame: turtle 0.412, trace 0.180, row 0.153, movement 0.012
```

It costs two clock reads per timed call, so it is a measurement run of its own, not something to
leave on — and it must be `false` in commits.
## Glide test (G, added 2026-09-18)

**G** puts Spyro 600 above the quicksave spot (V), facing the saved way, with zero velocity, and sends `Character.Event.Glide.Start` (`AbilitySystemBlueprintLibrary.SendGameplayEventToActor`) so `GA_Spyro_Glide` starts a glide from speed 0. The glide pushes forward on its own, so dont steer. `tools/glidetest.lua` logs one `glidetest` line per run: time to 50/90/99% of the glide speed, ground distance and drop at 0.25–3 s, and ground distance and time at drops of 50–400. Save the spot facing open air.

## Slide pose (J, added 2026-09-19)

**J** sends `Character.Event.SlideDown.Start` so `GA_Spyro_SlideDown` starts the steep-slope slide (the looping `AM_CPS1999_SlideDownLoop`, dust trail and camera wind lines) wherever Spyro is, for screenshots. Press J again to send `Character.Event.SlideDown.End`. `tools/slide.lua` reads the `Character.MoveState.SlideDown` tag to decide which one to send, and logs `slide` lines, including one if the game ends the slide itself. Not measured yet: whether the game's slope check ends it right away on flat ground.

## Quicksave (V / B / L / N, added 2026-09-17)

Testing aid, in the probe only. One quicksave slot, not one per level. **V** saves Spyro's spot (level, position, facing, control rotation) to `spots.txt` in the deployed probe folder, which survives restarts and `-ModsOnly` redeploys. The position is stored relative to the level's `LevelTransform`, because the same level can stream in at a different offset after a restart (LS204 was at y +300000 in one session and −300000 in the next; teleporting to the old absolute spot dropped Spyro into the void). Older `spots.txt` lines without the origin fields assume the nearest 300000 grid point. **B** goes to it, travelling to its level first if Spyro is elsewhere. **L** reloads the current level's gameplay sublevels, teleporting to the spot afterwards only if the spot belongs to that level. **N** dumps the GlobalTransporter (see below). Velocity and ability state aren't saved, so save while standing. Keys only queue a request; `sample()` hands it to `tools/quicksave.lua` on the next unpaused frame. Free keys only: the game binds every number key, W/A/S/D/E/F/P/Q/X/Z, LeftControl and the arrows (`DefaultInput.ini`), F11 toggles fullscreen and UE4SS uses Ctrl+R.

- Teleport: `K2_TeleportTo`, velocity zeroed, `SetControlRotation`, then `FollowCamera:ResetBehind(true)` (it takes one argument; without a snap the camera flies in). `FollowCameraComponent` also has `Reset`, `SetCameraPitchYaw`, `CenterCameraFromSpec` and `PauseUpdate`.
- **Level streaming (verified 2026-09-17):** every level streams into one shared persistent level, `GlobalPersistentLevel`, as runtime `LevelStreamingKismet` instances, placed by `LevelTransform` (LS104 at (−300000, −300000, 0), LS102 at (0, −300000, 0); the transporter has `LevelOffset` 300000 and `BaseLevelPosition` (−300000, −300000, 0)). Their `PackageName`/`PackageNameToLoad` can be empty, so read the package from `LoadedLevel:GetFullName()`. Sublevels are `LS###_{design,Enemy,Loot,Cinematics,Art01..03,ART_MASTER,Lighting,Fx,SFX,Music,Voice,Transport}`. Entries for levels visited earlier stay in `World.StreamingLevels` unloaded.
  - **Don't use `RestartLevel`** (console): it drops to the title screen.
  - The level Spyro is in is the one whose `LevelTransform` is nearest him. Picking "the first visible LS### sublevel" is wrong: a homeworld keeps neighbouring levels' `LS###_Transport` sublevels loaded and visible, which made the quicksave teleport into another level's coordinates (void, no geometry, wrong music).
- **L reload:** clears `bShouldBeLoaded`/`bShouldBeVisible` on the level's `design`, `Enemy`, `Loot` and `Cinematics` sublevels (re-clearing each frame in case the game's streaming re-enables them), waits for `IsLevelLoaded` false, sets them again, waits for `IsLevelVisible`, then teleports to the spot. Spyro is held in Flying with zero velocity because `LS###_design` holds the floor. Takes 1.0–1.3 s, resets enemies and gems, and leaves the transforms unchanged (checked before and after). Progress the game keeps outside those sublevels is not reset.
- **B across levels:** `GlobalTransporter_C` (instance in `GlobalPersistentLevel`, Blueprint on native `TransportManager`) has the game's own load-a-save event `StartAtLevelCheckpoint(Start Level: DataTableRowHandle, isRestart: bool, transitionType: byte EFalconLoadScreen, checkpoint: String)`. It reads the row (`LevelMapPath` + the `LLxxx` sublevel-name table), builds a `LevelStreamingRecord` with `UnloadCurrentLevels`, and calls native `StartAtLevel`, so lighting, music and game state follow. The probe calls it with the table `/GameplayCommon/LevelMechanics/LevelStreaming/StreamingData/LevelStreams/Spyro1_StreamData`, whose 101 rows are named exactly like the level keys (`LS101`–`LS337`, all three games), then waits for `currentLevel` to match and Spyro to be walking before teleporting.
  - **Travel test, 2026-09-19 (`tools/traveltest.lua`, removed 2026-09-22; one run from LS204):** the probe used to pass `Spyro1_StreamData`, whose rows are `LevelStreamingData`; the transporter reads `MasterLevelData` (`SpyroStreamData`, the table `FalconGameState` uses), so `GetDataTableRowFromName` failed and every travel silently did nothing. Results: (A) transporter + `SpyroStreamData` in the same game streamed LS202 in but left Spyro falling in a black void (timeout); (B) `FalconGameState.BP_LoadIntoLevel(row, portal, screenType)` arrived in LS201 in 7.8 s; (C) transporter into Spyro 3 and (D) `set game index` + transporter into Spyro 1: black screen, timeout; (E) `FalconGameplayStatics` `SetActiveGameIndex` + `SetGameIndex`, then `BP_LoadIntoLevel`, went from Spyro 1 state into LS201 in 7.9 s with game index 1/1; (F) `ReturnToTitle(false)` + `start game(2, slot)` loaded LS301 with index 2/2 but left the title screen drawn over it (the menu normally closes it), and it saves the game. **Probe travel now uses E.** A first visit plays the level's intro cutscene (Spyro 2's new-game intro played in LS201).
  - The other Blueprint entry is `QueueStream(LevelStreamingRecord, TransportType, RecordType)` → `ConvertStreamData` → native latent `QueueTransport`; the record's fields are mangled (`Load_9_…`, `UnloadCurrentLevels_20_…`), so `StartAtLevelCheckpoint` is the easier call.
- Lua trap that cost a test round: `local a, b = x and x:match(...)` truncates to one value, so `b` is always nil.
- `ue4ss/DevMods/SpyroFpsProbe` (deploy with `Install-UE4SS.ps1 -ModsOnly -Probe`): F5/F6/F7/F8 set `t.MaxFPS` to 30/60/120/0. F3 presses Continue on the NPC text box that is up (`lib/dialogue.lua`, through the box's own `OnMouseButtonDownFromGameInstance` with the pad's confirm key). A conversation that puts choices on screen is a second widget, `UI_DialogueQuestions_C`, which Continue does nothing to; that one is answered with its first option (Confirm on `questionlist` child 0 — "Stay here" on a balloonist, the option the game itself focuses), after Marco the Balloonist held the tour in LS101 on 2026-09-27. The scripted tour presses through conversations the same way and never ends a cinematic, changes the input mode or touches the HUD (`lib/igc.lua`, `lib/frontend.lua`: removing the HUD container once hid every text box). After a restart the resume presses Continue on the title and picks the game on the game select, as a player does. `tools/minigame.lua` records a minigame played by hand, because the scripted tour cannot play one: write a level name, `next` or `list` into `minigame.txt` (or press C for the next one) and it travels there, puts you on the recorded spot as the right character with 30000 gems for Moneybags, and hands the controller over without moving you or touching input, so you start the minigame yourself (boarding the Spyro 2 trolley or the shark's boat, or talking to whoever runs it). M then starts and stops a take, F1 marks the moment something went wrong (and logs which widgets are drawn) and F2 puts you back at the start for another go. Set the cap with F5/F4 before each take: rows carry it, and takes are numbered, so the same minigame at 30 and at 320 lines up. Output is `minigame_*.csv` and `minigame_anims_*.csv` in the tour's own column shape, so `tools/Compare-Anims.ps1` reads them, plus `minigame_notes_*.txt`, one line per mark with the take, the time into it, the cap and the montage that was playing. On load it restores `MaxSimulationTimeStep` to 0.05 if an old build changed it. It prints a `seg` summary per airborne segment, a `drift` line for grounded sliding without input, a `rise` line for every zero-gravity rise (kind ground/water/glide-hover/air, time at launch speed, apex from the launch frame), and charge lines. Those are `charge` (per charge), `turn` (grounded full-lock steer ≥ 0.5 s: yaw rates of Spyro/velocity/camera, radius, accel angle, slip, camera lag), and `camlock` (camera closing a ≥ 10° yaw offset after charge start or turn release: t50/t90 and the equivalent exponential speeds k50/k90, to compare against m_ctrInterp 3.5). Charge detection calls `IGetIsCharging` and falls back to MaxWalkSpeed ≥ 450, and optional calls that fail log `... unavailable` once. The `charge` line also has `startSpeed`, `t400` (from the last untagged frame to 400 speed, for starts below 150), `mouseDist` (raw mouse X), `yawPerMouse`, and `dustSpawns`/`dustRate`/`dustDilationMax` (charge dust effect respawns). CSV `mouse_raw` comes from the probe's own hook on `InputAxis_RightStick_X`; `stick_rx` is the stored value, which the mouse fix replaces. `camdump_<time>_<idle|charge|manual>.txt` holds every reflected `FollowCameraComponent` property (recursing into structs and arrays). It is written once while idle, once ≥ 0.75 s into a charge after the camera transition, and on F9. After the charge dump, `camdump diff` log lines list the values that changed. Per-frame CSV goes to `ue4ss\Mods\SpyroFpsProbe\trace_*.csv` in the game dir. `thief` lines (once a second per thief that is chasing or moving) give speed from position and from velocity, MaxWalkSpeed (average and range), % of time at MaxWalkSpeed, `accelObserved` vs MaxAcceleration, distance to Spyro vs CurrentDesiredDistance, DesiredSpeed, ChaseTime, the most common enemy state, and predicted laughs. Per-frame rows go to `thieves_*.csv`. `flame` lines (one per flame breath, from `NotifyOnNewObject` on `ParticleSystemComponent` plus a `FindAllOf` scan at startup, on pawn change and on F10) give the flame particle component's bounds via `KismetSystemLibrary:GetComponentBounds` and its `InstanceParameters`; per-frame rows go to `flames_*.csv`. Thief (`ChaseSpeedManager_C`/`_S3_C`) and dragon lookups use `FindAllOf`, which only runs for 15 lookups, 1 s apart, after `NotifyOnNewObject` reports the class loading or the pawn changes. The dragon lookup used to poll every 60 frames.


## World tour (M / O, added 2026-09-20) — full trilogy run 2026-11-04/05: 1843 stops at 30/30/60/160

A comprehensive comparison run: load each level, stand on a recorded spot, play a preset controller script, and compare where the character and camera end up at each framerate.

The code is in `tools/worldtour/`: `worldtour.lua` starts and stops a run and steps from stop to stop, `plan.lua` picks and orders the stops (and keeps `autotest_progress.txt`), `arrive.lua` gets onto each one (travel, game switch, a conversation pressed through, the teleport), `play.lua` plays its script and handles whatever ends it early, `drive.lua` moves the character, `samples.lua` writes the CSVs and `review.lua` the F3/F4 verdicts. Until 2026-09-22 it was one file, `tools/autotest.lua`; the trigger files, CSVs and log lines still use the autotest name.

- **Input.** `lib/input.lua` calls the character's own Blueprint input events (`InputAxis_LeftStick_X/Y`, `InputAxis_RightStick_X/Y`, `InputAxis_TriggerLeft/Right`, `InputAction_FaceBottom/FaceLeft/FaceRight` (jump, charge, flame, as DefaultInput.ini binds them), the shoulders, the triggers, the stick clicks) on its `FalconCharacterInputComponent` subclass, found by `FindAllOf` on the native base class and matched to the pawn by outer, so it works for Spyro, Sgt. Byrd, Sheila, Bentley and Agent 9 alike. Driving those events (rather than `AddMovementInput`) keeps the charge steering, jump hold and glide push in the test. Held axes are re-sent every frame, as the engine does; buttons only on change.
- **Scripts.** `tools/worldtour/scripts.lua` — a script is phases of `dur` seconds with `axes`, `hold` (buttons down) and `tap` (`{ button, period, width }`, for pressing through dialogue). Presets: `walk`, `walkDiagonal`, `walkTurn`, `startStop`, `jump`, `hop`, `runJump`, `doubleJump`, `glide`, `charge`, `chargeTurn`, `chargeJump`, `flame`, `camSpin`, `camCenter`, `enterTalk`, `talk`, `play`, `idle`. Every script starts and ends standing still so the passes line up.
- **Stops.** `tools/scan.lua` — **H** records a stop in front of every kind of character in the level at once: 400 units in front of each, facing it, with the `walk` script, one per class, skipping the player and anything further than 30000 units away (a level streams its neighbours in too). The level tour (**T**, removed 2026-09-22) ran this on arriving in each level, which is how the whole route file was built; to scan a level again, go there and press **H**, and to scan every level again, use the scan sweep below. `tools/routes.lua` — **M** records where you stand (level, position, facing, control rotation, all relative to the level's `LevelTransform`) into `routes.txt` in the deployed probe folder, with the `walk` script; edit that file to set the script and a note. For a minigame, record the stop in front of whoever starts it (Hunter for the skateboard) and give it `enterTalk`, which walks in and then taps through the dialogue.
- **The run.** **O** (or an `autotest.txt` trigger file, options `restart`, `caps=30,144`, `level=LS102`, `script=jump`) plays every stop at 30, then 60, 144 and 320 FPS — one framerate after another, since one process can only run at one framerate. Each stop travels to its level (`tools/quicksave.lua`, method E), teleports onto the spot, settles for 1 s, then plays the script while writing a row every 0.1 s of game time to `autotest_<stamp>.csv` (`cap,level,stop,script,note,t,x,y,z,yaw,speed,mode,camYaw,camPitch,camDist,camHeight`, position relative to the stop). Progress goes to `autotest_progress.txt` after every stop, so a crash or a restart carries on.
- **Swapping games, fixed 2026-11-04 (`lib/gameswap.lua`).** `switchGame` used to call the game state's `"start game"(index, slot)`, which **does nothing from inside a loaded level**: a tour in LS211 with Spyro 1 stops ahead of it sat there for the whole `SWITCH_TIMEOUT` and gave up on the game. It now leaves the level the way the pause menu's Quit to Title does — `UI_Pause`'s ubergraph at 4793 makes one call, `Interface(FalconGameStateOnlineInterface).ReturnToTitle(false)` — and then presses Continue and the game button through `lib/frontend.lua`, the same screens `lib/resume.lua` drives after a restart. **Measured at 3 s**, against a restart's 16–27 s. Most of a swap has no pawn, so `gameswap.update()` runs from `main.lua` before the pawn checks, like `resume.update()`.
- **Giving up on a level or a game used to take the game down with it.** After the failed switch the tour set `skipGame` and retired the remaining stops a frame apiece, calling `setFpsCap` for each — an `ExecuteInGameThread` running a console command, hundreds a second at 320 FPS, 2296 of them in that run, and the game died of an access violation inside `UE4SS.dll`. `nextStop` now retires skipped stops in one pass and re-caps only when the cap or the level changes: a swap test that used to fill the log with `t.MaxFPS` lines now logs exactly one.
- **The crash that stopped every run was `lib/igc.lua` asking freed actors whether they were playing, fixed and verified 2026-11-04.** A one-stop tour of LS201 took `UE4SS.dll` down within one to five steps — an access violation at a different offset each time (`0x2A1477`, `0x223B6D`, `0x28A37A`), reading `0xFFFFFFFFFFFFFFFF` or a garbage pointer. Bisecting said it was neither the game swap (it crashed the same way started already in Spyro 2) nor the probe's sampling (the same with `trackers on: none`), and the suspects that were left — the input events, `anim.hold`, the sample CSVs — were all innocent.
  - **Read the dump instead of bisecting further.** `build\DumpInfo\DumpInfo.exe <dmp> 60 | tools\Resolve-Ue4ssStack.ps1` against the local build's `UE4SS.map` named both faults in one go, and they are the two calls `lib/igc.lua` makes: one is `LuaType::UObjectBase<UObject>::setup_member_functions`'s second lambda, i.e. **`GetFName`**, reached through `get_userdata`; the other is `UObjectBase::prepare_to_handle(Get)` → `handle_unreal_property_value` → `GetFunctionByNameInChain` → `TFieldIterator<UFunction>::IterateToNext`, i.e. **a property read whose class chain is garbage**. That is `derivesFromBase`'s `object:GetClass():GetFName()` and `isActive`'s `object.CurrentlyActiveIGC`.
  - **Cause: a list of actors kept for seconds is a list of actors that can be freed under it.** `igc.lua` sweeps `FindAllOf("Actor")` once and keeps the cinematics for `CACHE_SECONDS`, then asks all of them `CurrentlyActiveIGC` **every frame**. Teleporting onto a stop streams a sublevel out: in the measured run the sweep found 111 cinematics out of 2091 actors and **21 of them were freed 1.7 s later** (1911 actors), while the list still held Lua wrappers around their pointers. Asking a freed one anything is an access violation inside UE4SS, not a Lua error, so the `pcall` around every one of those reads caught nothing.
  - **Fix.** Every actor taken out of the list is checked with `IsValid` again before it is touched, dead entries are dropped on the way out (and logged once per sweep: `igc: N cinematic(s) were freed since the sweep`), and the cinematic's kind is worked out once at sweep time instead of by a `GetClass` per actor per frame — so the guarded loop is cheaper than the unguarded one was. UE4SS's `IsValid` is a real liveness test for a `UObject` wrapper (non-null, in the map of objects Lua has wrapped, which UE4SS's own delete listener erases from on destruction, and not unreachable) and it never dereferences the pointer, so it is safe to ask about a wrapper that has gone dead.
  - **Verified in game, 2026-11-04.** The repro that died on step 2 now plays all 5 of its steps; all 10 steps of LS201 (including the `enterPlay` conversation with Elora) play through; and a `caps=30 script=walk` run went LS101 → LS110 unattended, 62 stops over seven minutes with a game swap and seven level loads, no errors and no crash. The tour is still unproven past that, but it no longer takes the game down.
- **Running it unattended (`tools/Tour-Unattended.ps1`, added 2026-11-04).** A full route is 1843 stops and each cap multiplies that, so a real run is a night's work. The driver drops the `autotest.txt` trigger, follows the log, and on a crash or a stall restarts the game and re-drops the trigger **without** `restart` so `autotest_progress.txt` carries on. It also collects what would otherwise be lost: UE4SS truncates its log every launch, so each launch's copy is kept, and the tour's CSVs are stamped per launch, so they are concatenated into one `autotest.csv` and one `autotest_anims.csv` (each comparison takes a single file). Both comparisons then run into `build\tour\<stamp>\compare-*.txt`, worst stop first — **that is what to read, not the log**. Default caps are `30,30,60,160`: the second 30 is the noise floor, the per-stop difference from itself, without which a 60 or 160 FPS number cannot be called a finding.
- **The progress file now says which plan it belongs to.** `autotest_progress.txt` holds an index into the plan the run's *options* built, so resuming a `caps=30,60` run with `caps=30` landed in the middle of a different level. It carries an options signature (caps, level, script, review) and a mismatch starts the route over with a log line saying so — the same guard `tools/scansweep.lua` keeps, and the driver above depends on it, since it re-drops its trigger after every crash.
- **Nothing else may be travelling Spyro at the same time.** The crash above happened during a scan sweep, with the two fighting over where he was. The sweep now refuses to start while a tour runs and stops if one starts (`main.lua` passes `worldtour.running()` into `scansweep.update`); the tour has no such guard yet.
- **Both comparisons mixed the lead stops up until 2026-11-04.** A lead stop plays four scripts (flame, charge, hop, glide) under **one stop id**, and every join key left `script` out, so a pass was compared against whichever of the four was written last. `Compare-Anims.ps1` was worse: its dedup, which exists to drop a stop's abandoned first attempt, keyed on `(cap, stop, t, who)` and so threw three of the four scripts away as duplicates — **1437 of 4632 rows** of the 2026-11-04 LS101→LS110 run, 31% of it, reported as "abandoned attempts". `script` is in every key now.
- **Samples taken before the teleport landed are the loudest thing in the report, and they are not
  repairable (2026-11-05).** `play.settle` waited `SETTLE` = 1 s after asking for the teleport and then
  took the stop's origin. The teleport does not always take effect in that second: over the trilogy run
  **349 of 3733 runs (9%), across 182 stops**, spent their first second still standing where the last
  stop left them, 3000-odd units away, with the camera not yet placed anywhere near him (`camDist` in the
  hundreds of thousands against about 150 in gameplay), and snapped onto the spot afterwards. Every
  sample of such a run is offset by the distance between the two places, and the script's input was
  driven at the old one, so there is nothing in it to salvage.
  - **It reads as a framerate difference**, because how many frames the teleport takes depends on the
    framerate: 11% of the 30 FPS runs against 7% of the 160 FPS ones. It filled the top of the first
    report — **17 of the 21 stops in the headline table** — and the single loudest "finding" of the run
    (LS211/687, floor 4.4 units, both fast passes 3200 away, agreeing to within 24) was nothing but this.
  - `play.settle` now refuses to finish until he is within `PLACED_DISTANCE` of `run.spot`, and gives up
    on the stop after `SETTLE_MAX`. `Compare-Autotest.ps1` throws such runs away by their `camDist` and
    says how many, so the data already on disk is usable without a second night.
- **Nothing under two frames of walking means anything (2026-11-05).** The script presses and releases
  the stick on a frame boundary, so the same walk ends up to a frame further on at 30 FPS than at 160
  with no bug involved. Walking measured **269 units/s**, so a 30 FPS frame is **9 units** — and 44 of
  the run's 68 cross-checked findings sat between 10 and 50 units, **clustered tightly around 16**, which
  is two frames. That is one artefact, not 44 bugs. `Compare-Autotest.ps1` measures the speed from the
  run itself and puts the bar at two frames of it.
- **A stop where Spyro is hit a different number of times is not measuring movement (2026-11-06).** The
  hit knocks him back and cancels whatever he was doing, so the passes are in different states from then
  on and the distance between them is the hit. It passes every other test, because it lines up with the
  framerate for a reason that is not physics: the stop starts a fixed number of **frames** after the
  teleport, so the enemy is further into its attack cycle at 30 FPS than at 160, and whether its next
  attack connects falls on one side of that or the other. Both 30 FPS passes then agree with each other,
  both fast passes agree with each other, and the cross-check is satisfied.
  - `BP_CES1060_Cupid_C` is the case that showed it. At LS126/361 Spyro is hit twice at 30 FPS and once
    at 60 and 160; the second arrow lands during the run-up, before the charge reaches its 458.5 units/s,
    and pins him for 1.3 s of a 3 s script. 54 units at 30 FPS against 810 at speed — a 750-unit finding
    that is one arrow. At LS127/369 the same enemy goes the other way (no hits at 30 FPS, seven at 60 and
    160), and **that is the tell: a framerate bug does not change sides.**
  - `lib/invuln.lua` cannot remove the confound — it keeps him alive, and its own header records that he
    still takes hits and knockback (`GE_Invincibility` was tried in 2026-09 and stopped neither). So
    `Compare-Autotest.ps1` counts the damage montages per pass from the animation CSV beside it (`-Anims`,
    or guessed from the position CSV's name) and holds those stops back: **25 of the 67 it would otherwise
    report, 9 of them over 200 units.** See `docs/findings/tour-2026-11.md`.
- **A stop's own noise floor is the only thing that makes the numbers mean anything (2026-11-04).** Run
  the baseline framerate twice (`caps=30,30,60,160`) and the second pass is how far a stop lands from
  *itself* — same script, same framerate, so whatever it covers is the stop failing to repeat. Measured
  over LS101+LS102, 30 stops: **median 1.6 units, 95th percentile 775, worst 2436.** That tail is not
  framerate; it is charges and walk-ins compounding a small difference in facing over four seconds.
  - **One floor for the whole run is the wrong instrument**, because the stops do not share one. A charge
    in LS101 wandered 2436 units at the same framerate while a walk in LS102 repeated to within 182, so a
    run-wide 95th percentile of 775 called the first normal and the second quiet — both wrong, in
    opposite directions. `Compare-Autotest.ps1` grades each stop against its own floor and ranks by the
    ratio: on that data 29 "drifts over 10 units" become **6 findings**, the LS101 charge dropping out
    because at 60 FPS it moved *less* than its own floor.
  - **A floor of zero means one of two opposite things**: a stop that repeats perfectly, or a stop where
    nothing happened in either pass. So each stop also carries how far the baseline pass itself went, and
    one whose baseline barely moved is listed apart — "measured nothing ... so the stop never played".
    Without that, "the game took the input away" ranks at the top of the findings table, which is where
    it first appeared. The bar is 10 units on purpose: a standstill is essentially zero, while a hop's
    whole travel is about 40, and a bar of 50 hid every jump-height difference there is. A flame does not
    move him at all and is measured by `Compare-Anims.ps1` instead.
- **"The game has the camera" is how a stop knows it is not being played (2026-11-04).** A gameplay camera
  sits about 150 units behind him; a cinematic one is thousands. LS101 measured **2948 for every stop
  after Marco the Balloonist** — the tour had ridden a balloon transporter, and `igc.lua` never saw it
  (its own comment says the transporters are not looked for). Two whole passes of the level were written
  down as standstills at 25 s a stop, and the first pass was the only real data. `play.lua` now ends a
  stop that cannot move while `camDist` is over 600 and escalates straight to `arrive.lua`'s reload;
  that branch used to *reset* the lock timer for lead stops and play the script out, which is exactly
  what filled the CSV. The tour needs `ROW_CAMERA` on for this (`camDist` is NaN without it and every
  NaN comparison in Lua is false, so the detector would just never fire) — `Tour-Unattended.ps1`
  refuses to start otherwise.
- **A level that keeps the input is given up on, not played.** `arrive.lua` used to come out of its last
  reload saying "the stops that cannot move here are the spots" and carry on. That is right for a stop
  teleported against a wall and wrong for a level holding the input; the remaining stops are retired in
  one pass now (`worldtour.lua`'s `givenUp`) and the log names the level so it can be revisited.
- **The fast passes agreeing with each other is the test; the floor alone is not (2026-11-05).** Most
  stops repeat *exactly*: over the trilogy run the **median floor was 0**. Dividing by it makes every
  drift past the tolerance a finding at an enormous ratio — **426 of 962 pairs**, which is not a list
  anybody works through. What separates a framerate difference from a stop that merely wandered is that
  **60 and 160 are wrong in the same way**: a cause in the framerate shows at both, while a charge
  compounding a small difference in facing sends them somewhere unrelated each time. So a finding needs
  every fast pass past the stop's floor, the baseline pass to have gone somewhere, and the fast passes to
  land within half their own drift of each other. On the same data that is **37 cross-checked findings**,
  one screen, and the run's loudest entry is not among them.
  - A stop played at only **one** framerate above the baseline has nothing to agree with, so its spread
    is 0 for free. Those are listed apart, as weaker. It is not a rare case: a crash costs a level its
    later passes, and that is most of what games 2 and 3 lost (game 1 finished all four passes on ~460
    stops; game 2 had 227 stops at 30 FPS but 87 at 160, game 3 535 against 168).
- **Comparing.** `tools/Compare-Autotest.ps1` joins the passes on (stop, script, t) and reports, per stop and framerate, the largest and final distance from the 30 FPS pass and the largest camera yaw/pitch difference, worst first.
- **Restarting from outside the game.** `tools/Restart-Game.ps1` closes the game, arms `resume.go` and starts it again. `lib/resume.lua` notes the level, game index and save slot to `resume.txt` every 5 s (the game itself only records the loaded level at an autosave or a menu quit, so Alt+F4 or a kill loses it); with `resume.go` set it waits out the title screen, calls `"start game"(game, slot)` and travels back to the noted level.

## Level replay (Home / End, added 2026-11-15)

`tools/replay.lua`. Records every input of a level played by hand and plays the same inputs back at
another framerate, free-run (nothing corrects the course), writing a trace per run to compare
against the recording. The piece the world tour cannot do: a whole level of real play, not eight
seconds of preset script on a stop.

- **End** drives the take picker: pressed with nothing running it opens an on-screen list of the
  takes recorded for the current level, newest first; **Up/Down** move the selection; **End** again
  plays the selected take (the newest if unmoved). While a replay runs End aborts it. The overlay
  shows `[REC]` while recording and `[PLAY]` (take, cap, phase, progress) while a replay runs, so the
  state is visible in game. The arrows are game-bound too, so use them only with the picker open and
  Spyro standing still. Every selection and status line is also logged, so the picker works from the
  UE4SS console as well.
- **The overlay is a UMG widget (tools/overlay.lua), not PrintString.** The game is a Shipping build,
  where KismetSystemLibrary:PrintString and the on-screen debug text are compiled out (a call there
  logged `PrintString expected 6 parameters, received 7` and drew nothing). So the overlay builds a
  UserWidget by hand -- a CanvasPanel root, a dark auto-sizing Border, one TextBlock with the engine
  Roboto font -- and adds it to the viewport. It is rebuilt on each hot reload (fresh Lua state).
- **Replaying the charge turn needs a stored-stick hook, not the axis event.** The charge reads the
  component's stored InputAxisLeftStickX, which the engine resets from hardware (0) every input tick,
  before the charge movement runs -- so writing the property from the end-of-frame sample lost the
  race and the replayed charge steered straight (stored stick read 0 in all 282 charging frames of
  the first LS102 replay). tools/replay.lua hooks InputAxis_LeftStick_X/Y (as fixes/charge.lua does
  for RightStick_X) and, while a replay drives, overwrites the stored value with the take's -- which
  lands in time for the charge to read it. Verified turning on LS102, 2026-11-15.
- **KNOWN ISSUE (open, 2026-11-15): 30 FPS movement is not yet reproduced exactly.** A 30 FPS take
  replayed at 30 FPS still drifts from the recording -- on LS102 the walking heading was ~3-13 deg off
  in the first seconds before converging (the charge now turns, but the ground path is not identical).
  So divergence in the first ~2 s is partly harness noise, not a framerate bug, and the 30->30 pair is
  not yet a clean baseline. Candidates to chase, next session: the left stick is camera-relative via the
  control rotation, which is not seeded identically at replay start (the settle->play handoff,
  FollowCamera:ResetBehind, and the SetControlRotation restore); sub-frame input timing at the row
  boundaries (inputs are stepped by game time, not frame-aligned to the recording); and the very first
  input frame. Fix this before reading the opening seconds of any cross-FPS replay as a bug.
  - **2026-11-15, found by reading the code, NOT yet verified in game: replayed input was one frame late
    and its timing jittered.** A recorded row is read at the end of the frame that already used it; the
    replay sends at the end of a frame, so the next frame uses it. It also chose rows with
    `t <= elapsed`, where `t` is rounded to 5 places and `elapsed` is a running sum of `dt`, so at a
    fixed 1/30 s about half the rows (0.06667 <= 0.066666 is false) landed a second frame late. It now
    sends the first row with `t >= elapsed + dt/2`. **To check:** record at 30, replay at 30, run
    `compare_replays.py`: Spyro's yaw should stay within 2 deg from t=0. `compare_replays.py` now also
    reports camera yaw (first >2 deg off, max, and the first 3 s every 0.5 s). If the camera yaw is off
    from the start while the input timing is right, the control-rotation seeding is the next suspect; if
    it is not, the stick path is.
  - **2026-11-15, measured, fix written but not yet deployed or re-run: the replay threw the recorded camera heading
    away.** Take `LS102_20261115_161245` (stand, then hold W for 3 s, 5.6 s long) replays with the **same speed on
    every frame** as the recording (33, 67, 100, ... 268), so the input timing fix above is right. The only difference
    is a constant 2.7 deg: the recording had the camera at 40.8 deg with Spyro facing 43.5 (the take header's `ctrl`
    yaw is that camera heading), and `place()` called `SetControlRotation(ctrl)` and then `FollowCamera:ResetBehind(true)`,
    which snapped it to 43.5. Walking is camera-relative, so the path was 2.7 deg off: 38 units after 4 s. `place()` now
    snaps first and sets the control rotation after, and the settle phase re-applies it every frame. **To check:** the
    first row of a run's `cam_yaw` must equal the ref's (40.8 here). Takes recorded with the camera exactly behind Spyro
    (LS102_20261115_155817 and _160013, where ctrl yaw = facing) were not affected by this; their remaining early yaw
    difference (7.1 deg at 1.0 s, repeatable) happens where the stick ramps from keyboard keys and is still open.
  - **2026-11-15, verified in game: camera restore and raw stick capture.** `place()` now sets the camera with
    `FollowCamera:SetCameraPitchYaw(pitch, yaw)` (exists; the log shows `GetCameraYaw 43.49 -> 40.81`) after
    `ResetBehind(true)`. Result on `LS102_20261115_161245` (walk forward): max position gap 38 -> 0.6 units, camera
    yaw 0.0 deg off. A stick take also records the **raw value passed to `InputAxis_LeftStick_X/Y`** (`rlx`, `rly`
    columns; older takes lack them and replay from the stored values) because that is what the walking uses; the
    stored axis can be a smoothed ramp. On `LS102_20261115_170419` (keys: A, W, A, W; 14.2 s) the first 51 frames,
    a strafe with the camera auto-rotating, match the recording to 0.0 units frame for frame, and every key
    **press** is consumed on the right frame. **Not fixed:** a key **release** lands a frame early or late (f61:
    recording decelerates on the release frame, replay one frame later; f334 the other way), so the runs part ways
    after 10.9 s (100 units at 12 s). Automated key presses give flat -1/1 with no ramp, so the 7 deg opening error
    on `_160013` (recorded from your own device, stored ramp -0.14, -0.46, -0.78, -1.0) is not yet re-tested: record a
    take with your normal controls and replay it. The reset key above is verified (overlay `[RESET]`, level
    reloaded, Spyro on the take start).
  - **Camera (mouse look) is recorded and replayed (2026-11-16, verified).** Mouse look never reaches the
    axes a take records (the charge-steering stored value is a separate path), so a camera-only take
    replayed with the camera frozen. Takes now carry the PlayerCameraManager rotation per frame (`cpitch`,
    `cyaw` input columns); the replay sets `FollowCamera:SetCameraPitchYaw` and the control rotation on the
    frame each row's sticks go out, and logs `camera: driving the recorded camera` (old takes: `no camera
    data`). Verified on `LS102_20261116_014821` (camera-only, mouse): all 151 frames match the recording
    exactly, index for index. **compare_replays.py artifact:** at a discrete camera jump its t-join can land
    the two traces on opposite sides of the jump and report a one-sample ~100 deg camera diff -- check the
    frame-indexed values before believing a single-sample camera spike. (Fixed 2026-11-16: angles are
    interpolated now, see below.)
  - **The left stick is now sent exactly as the engine sends it (2026-11-16), and 30->30 replays match
    frame for frame.** This replaces the "half-frame filter" (the average of this row's Y and the last
    row's), which was tested and found right only for keys on the forward axis.
    - **How Spyro's walking consumes the stick** (`CharacterInputComponent_Spyro`, `AssetDump --code`). On
      the ground, `InputAxis_LeftStick_X` and `_Y` each store their axis (`InputAxisLeftStickX/Y`) and call
      `RequestGroundMovement()`. That function (Ubergraph offset 31522) adds one vector built from both
      stored axes: `AddMovementInput(Normal(fwd*sign(Y) + right*sign(X)), |(X, Y)|)`, using the control
      yaw, and skipped when both axes are <= 0.1. Above 0.75 x MaxWalkSpeed, moving forward, it calls
      `MoveAlongActorForwardVector(X, Y, ...)` instead. In the air the events call
      `MoveAlongControlRotationRight/Forward` (`AddMovementInput(right, X)` / `(fwd, Y)`). The component
      tick adds stick movement only while climbing.
    - **So a recorded frame consumes |(x_k, y_(k-1))| + |(x_k, y_k)|**, because the engine fires X before
      Y. That is a W press 1.0 (0 + 1), a W release 1.0 (1 + 0), an A press 2.0 at once, and an A release
      0. All six LS102 takes with a `last` column show exactly this, including `LS102_20261116_223337`,
      recorded with A before W.
    - **What the replay did instead.** Lua fired the events in `pairs()` order (Y first), and
      `input.apply` then left the stored axes set. So a Lua Y call added 2v and a Lua X call 1v (`pend`),
      and the next frame the engine's own zero-valued X event added |(0, stored Y)| again. The result was
      `last` X 1.0 and Y 3.0 against the recording's 2.0. With keys that is invisible (the CMC clamps the
      input to length 1), but a partly tilted gamepad stick would accelerate differently. The half-frame
      filter got W right by luck and put every A press and release 1.0 off (`122108` #176: speed 141 vs
      268).
    - **Now:** `input.sendLeftStick` sets stored Y to the previous frame's Y, fires X, fires Y, and zeroes
      both stored axes so the engine's zero events add nothing. `tools/replay.lua` uses it on every frame,
      charging or not (a stick event adds nothing during a charge).
    - **The stored stick is restored on every frame**, by the replay's stick hook, after the engine's
      **Y** event only, to both axes. The charge steers by the stored stick in its tick. That hook used
      to run only while charging, and after each axis's own event. Charging-only meant the first charge
      frame read 0, and the turn started a frame late (gamepad take `LS102_20261116_230304` f34: yaw
      -11.21 vs the recording's -8.46). Per-axis meant X was restored before the Y body ran, which added
      |(x, 0)| of extra input every frame.
    - **Camera, two steps around the sticks.** Each frame the replay (1) sets the camera of the frame that
      just ended, which is the camera the recording had when the next frame began and the one the sticks
      are turned by, then (2) fires the sticks, then (3) sets the next frame's camera, **unless the game
      turned the camera itself** during the frame that just ended. That is measured as `GetCameraYaw`
      against the yaw last set; a charge press counts from its first frame. The reason: after an outside
      `SetCameraPitchYaw` the walking camera stays put (its auto-rotation does not run), so step 3 supplies
      the recorded turn. A charge's native centering does still step it, so with step 3 it counted that
      step twice (+4.7 deg on `230304`'s first charge frame, and the charge steers by the control
      rotation, so Spyro's yaw drifted to a 574-unit split). Both earlier orders were wrong for one case:
      - camera (next frame) before the sticks turned every stick by the next frame's camera (`122108`
        f145: `vy` 0.017 vs 0.000);
      - the ended frame's camera alone made the walking camera lag a frame.
    - **Takes now store sticks at full float precision** (`%.9g`, was 4 decimals) and the camera to
      1e-5 deg. The gamepad take's 0.12156862 was stored as 0.1216, which shows as `last` 0.2432 vs 0.2431,
      and the charge steers by the stored stick. Takes recorded before 2026-11-16 23:19 have the rounding.
    - **Result, 30->30, frame-indexed:**
      - `LS102_20261116_122108` (W, jump, A; 7.3 s): every frame identical, `last` included (was 9.8 units
        off).
      - `LS102_20261115_170419` (A, W, A, W with an A release and a W press on the same frame; 14.2 s; no
        camera data, so the camera ran free): 0.032 units and 0.02 deg max (was 100 units off).
      - `LS102_20261116_223337` (A, W, A; 9.7 s): `last` identical on every frame. It ends 0.95 units off
        because of frame pacing (below).
      - `LS102_20261116_230304`, **a gamepad take** (analog walking at partial tilt, charges, jumps;
        21.3 s): the analog walking is exact (`last` within 1e-4, the take's rounding), Spyro's yaw within
        0.03 deg and the camera within 0.013 deg for the whole take, except one 0.5 deg blip at f448-451.
        Position: one float32 step at f64 (in a charge), 0.5 units by 6.2 s, 3.3 max. That is the
        4-decimal stick rounding and frame pacing, both below anything a framerate bug does.
      - `LS102_20261116_014821` (camera only, mouse): still exact.
    - **Remaining noise floor: frame pacing.** At the 30 cap, 1-2% of frames run up to 0.25% long
      (0.03334-0.03341 s), at random, in recordings and replays alike. On a frame where Spyro accelerates,
      that changes speed by up to 0.08: `223337` f126 recorded 0.03341 s, giving 66.74 vs 66.67. That is
      one float32 step of position (1/32 unit this far from the origin), which a wall contact at 4.7 s
      turned into 0.95 units. Far below any framerate bug. Forcing a fixed frame time while recording and
      replaying would remove it if it ever matters.
    - **Camera during a jump:** the recorded `cam_yaw` (the camera manager's view) can sit up to 1 deg off
      for a few airborne frames (`122108` f100-104), while the control rotation the movement uses is
      driven exactly. That is harmless unless a stick is held in the air; watch it if an air-steering
      take diverges.
    - **Start placement now has to land within 5 units** (`PLACE_TOLERANCE`; it accepted 300). After the
      gamepad run ended across the level, `122108` started 156 units off its spot and replayed shifted.
    - **compare_replays.py now interpolates yaw and camera yaw** as it does positions. Taking them from the
      row at or before t flagged 14-21 deg "differences" during turns on runs that matched to 0.02 deg,
      because a replay's timestamps run a few 1e-5 s off the recording's.
  - **PageUp resets the level** (added 2026-11-15): reloads the gameplay sublevels and stands Spyro
    on the start of the selected (else newest) take, then stops, so a take can be recorded or replayed again from a fresh
    level. It aborts a replay or a recording first.
- **Capturing the stick needs the stored axis, not just the axis event.** Spyro's charge steering
  reads the component's `InputAxisLeftStickX` property (not the movement input vector), and the mouse
  charge steering fix reads `InputAxisRightStickX` (`docs/findings/charge-turn-camera.md`). `lib/input.lua`
  fired only the axis *events*, which drive walking through `AddMovementInput` but never set those
  properties, so a replayed charge turn steered straight and its yaw froze (LS102, 2026-11-15:
  recorded yaw swept -98 to +90, the 30 FPS replay sat at -93.3 for the whole charge). `input.apply`
  now writes the stored axis properties as well, which is also what the recording reads back.
- **Home** starts and stops recording. Start standing on the ground where the run should begin;
  the start transform, control rotation and the level's placement go into the take's header. Avoid
  dying in a take: the respawn teleport is recorded as if it were play.
- **End** replays the newest take recorded for the current level at the current F5-F8 cap (no cap
  pressed this session: the take's own), and aborts when pressed again. The replay reloads the
  level's gameplay sublevels first (the quicksave L machinery, without its spot teleport), places
  Spyro on the take's start, settles for a second, then drives `lib/input.lua` by game time. Text
  boxes and cutscenes are pressed through (`lib/igc.lua`), and a paused prompt is answered the way
  the tour answers it (`main.lua`).
- Axes are read each frame from the character's input component; buttons are captured by hooking
  their input events the way `lib/mouse.lua` hooks the mouse axis. FaceTop is neither captured nor
  replayed (`lib/input.lua`'s reason). If charge's native event can't be hooked, charge is recorded
  from the charging tag instead and the log says so.
- Files, flat in the mod folder: `replay_<level>_<stamp>_inputs.csv` (the take),
  `..._ref.csv` (the trace recorded with it), `..._run<cap>_<t>.csv` (one per replay), and
  `replay_takes.txt` (the index End reads; last line per level wins). Positions in the traces are
  level-origin-relative, so takes survive the level streaming in at a different LevelTransform.
- Compare with `python3 tools/compare_replays.py --dir <mod folder> --take <level>_<stamp>`
  (python3: the Cowork VM, not the game PC). It writes `replay_<take>_compare.txt`: first
  divergence time, max drift, jump durations and rises while the runs were still aligned, and the
  movement-mode / montage / charging mismatch timelines. **The first divergence is the finding;
  everything after it is drift** — the left stick is camera-relative, so once a jump lands short
  the two runs part ways for good. For a bug late in a level, record a second, shorter take that
  goes straight to it; takes per level accumulate and End plays the newest.
- A 30 FPS take replayed at 30 FPS is the fidelity check, not a bug hunt: if that pair diverges
  early, the capture or the start state is the problem, and runs at other caps prove nothing until
  it is fixed.

## Scan sweep (scansweep.txt, added 2026-11-04)

`tools/scansweep.lua` builds the route file without playing through the games: it travels to every level in the stream data table and runs the scan above in each one, so a tour has stops to play. It replaces the level tour (`tools/tour.lua`, **T**, removed 2026-09-22) that built the first route file, and keeps the two things that one learned.

- **No key.** Every letter is bound (`main.lua`), and a sweep runs for hours, so it starts from a trigger file — which is also how a script starts one. Drop `scansweep.txt` in the deployed probe folder; an empty `scansweep.stop` ends a run that is going.
- **Options** in the trigger file, space separated or one per line: `restart`, `game=2`, `level=LS205` (comma list), `new` (skip levels that already have stops), `all`, `settle=8`, `range=60000`, `switch`.
- **Write the trigger file without a byte order mark.** PowerShell's `Set-Content -Encoding utf8`, `>` and `Out-File` all write one in 5.1, and those three bytes stick to the first option, which is then silently dropped — a `game=2` run swept all three games' level lists on 2026-11-04 before this was understood. Use `[IO.File]::WriteAllText(path, text, [Text.UTF8Encoding]::new($false))` or `-Encoding ascii`. The sweep strips a BOM now (`lib/util.lua`'s `stripBom`); the other trigger readers in `tools/` do not yet, so the same trap is waiting in the tour, the spawn test and the montage sweep.
- **Flight levels and speedways are skipped** (LS105, LS111, LS117, LS123, LS129, LS209, LS220, LS221, LS228, LS307, LS316, LS325, LS334), the old tour's list: Spyro never walks in them, so a travel there never counts as arrived and costs the whole 90 s timeout, and a crash ends on a Retry/Quit screen that nothing in the probe can answer. They have no walking characters to scan either. `all` takes them anyway, and a `level=` list always includes what it names.
- **Each level is scanned from its own entry checkpoint**, standing still: Spyro is travelled, never teleported. So it picks up the characters loaded within `scan.lua`'s `RANGE` (30000) of there, and misses the far side of a big level. `range=` raises it; levels sit on a 300000 grid (`LEVEL_OFFSET`), so anything under about 150000 is still this level, and past that a stop would be recorded against a neighbour the tour will not have streamed in.
- **A first visit plays the level's intro cutscene**, which is pressed through before the scan (`lib/igc.lua`), as the tour does. A prompt that pauses the world is answered too, from `main.lua`: a paused world never reaches the stop file.
- **Resuming.** `scansweep_progress.txt` holds the next level and the options it was swept with, written after each level, so `tools/Restart-Game.ps1` after a crash picks the run up — drop the trigger file in again without `restart`. The index counts the levels that run covered, not the whole table, so a resume with different filters starts over instead of landing somewhere arbitrary. `scansweep_<stamp>.txt` is one line per level: characters found, stops written, or why it was skipped.
- **One run covers one game.** Nothing in a running level moves Spyro into another one. `quicksave.startGame` (the game state's `"start game"(index, slot)`, what `tools/worldtour/arrive.lua` switches games with) **does nothing when it is called from inside a level**: measured 2026-11-04, a `game=2` sweep standing in LS135 called it, sat in LS135 for the whole 180 s timeout and skipped all 25 Spyro 2 levels. What actually gets into another game is the menu the title screen offers — `lib/resume.lua` drives it (Continue, then the game select in `lib/frontend.lua`) and only falls back to that bare call when the game select never appears. So the other games are swept by restarting into them, which takes about 16 s:

  ```
  # with the game closed, because the probe rewrites resume.txt every 5 s while it runs
  Set-Content "$ProbeDir\resume.txt" 'LS201 1 0'      # level, game index (0/1/2), save slot
  .\tools\Restart-Game.ps1
  # then drop a scansweep.txt holding: restart game=2
  ```

  A sweep that meets another game's levels now skips them at once with that instruction, instead of spending 180 s finding out. `switch` in the trigger file tries the call anyway, for anyone who wants to dig into why it is a no-op. The world tour used to make the same call and had the same problem; it now swaps games through the title screen instead (`lib/gameswap.lua`), which is what a sweep would need to do to cross games.
- **Tested without the game.** `tools/tests/scansweep_test.lua` drives the state machine against stubbed modules (`lua tools\tests\scansweep_test.lua`): every level in order, each option, a travel that cannot start, one that never arrives, a game that cannot be reached, a cutscene that will not end, the stop file and the resume. It is the one probe tool that can be tested this way — it reaches the game only through the modules it requires, so it needs no UE4SS globals.

### Running it unattended (tools/Sweep-AllGames.ps1, added 2026-11-04)

One game per run and a game that falls over every so often are both things a script can deal with, and this one does: per game it closes the game, points `resume.txt` at that game's first level, starts it with `Restart-Game.ps1`, drops the trigger and follows `UE4SS.log`. A finished sweep moves on; a dead game or one that has not finished a level in `-StallMinutes` is restarted and the trigger dropped again **without** `restart`, so `scansweep_progress.txt` picks the run up at the level it had reached. Stops are pulled into the repo after every game, so a run abandoned half way still leaves everything it recorded.

```powershell
.\tools\Sweep-AllGames.ps1                                   # all three games
.\tools\Sweep-AllGames.ps1 -Games 2,3 -Range 120000
.\tools\Sweep-AllGames.ps1 -Games 1 -Levels LS104,LS106      # top one up, or try the driver out
```

`-MaxRestarts` (6) gives up on a game and moves to the next; an empty `sweepall.stop` in the probe folder ends the whole thing after the current game. Verified 2026-11-04 by killing the game two levels into a six-level run: the driver noticed in 10 s, restarted, and the resumed sweep reported `starting at 3 (LS110)` and finished the remaining four.

Two things it has to do that are easy to get wrong, both commented in the script: `Restart-Game.ps1` reports with `Write-Host`, so capturing its output and matching on it finds nothing however well the restart went (ask the log instead — UE4SS starts it over on every launch), and the trigger file has to be written without a BOM.

### First sweep: the whole trilogy (2026-11-04)

**1843 stops over 85 levels**, in about 45 minutes of game time including the restarts, one game per run:

| Run | Levels | Stops | Notes |
|---|---|---|---|
| `game=1` from LS102 | 30 of 30 | 464 | 8 min, nothing skipped, about 13 s a level |
| `game=2` from LS201 | 25 of 25 | 610 | crashed after LS208, resumed from the progress file |
| `game=3` from LS301 | 33 of 33 | 769 | crashed in LS336 at level 32; LS336 and LS337 then swept singly |

Stops are `walk` 723, `flame` 397, `charge` 397, `enterPlay` 326 — the enemies get all three, NPCs get the walk-in and the conversation. Per level they run from 0 (LS318, LS327, LS336: nothing within range that was not already covered) to 40 (LS207), tracking how many kinds of character stand near each checkpoint.

**UE4SS gets unstable over a long sweep.** Both crashes were access violations inside `UE4SS.dll` (dumps read with `build/DumpInfo/DumpInfo.exe`), at different offsets, several minutes and dozens of level travels into a run. Neither reproduced on its own: LS336 killed the Spyro 3 run while pressing through what the probe counted as 86 cinematics (85 `BP_Ladybug_Spawnpoint_C`), and then scanned clean in a fresh session with 1 character and no cutscene at all. So it is accumulation, not a bad level, and the progress file plus `tools/Restart-Game.ps1` is the answer — it carried both runs to completion. An unattended sweep of all three games wants a driver that restarts on a crash and re-drops the trigger.

The first run also showed the level table could not be read (`quicksave.levelNames` returned nothing, so the sweep used `levels.fixedNames()`), and the fixed list turned out to be right for all three games: every level in it travelled and scanned. Worth fixing anyway — `GetDataTableRowNames` returns through an out-param whose field name the reader may be guessing wrong (`out.OutRowNames or out.RowNames`), and it fails silently because the `pcall` succeeds and the list is merely empty.



### Keeping the stops (added 2026-11-04)

`routes.txt` lives in the deployed probe folder because that is where the game writes it, and for a while it lived nowhere else: a reinstall or a new machine lost every recorded stop, which is what happened to the route the level tour built. Now `ue4ss/DevMods/SpyroFpsProbe/routes.txt` is tracked as a seed, `Install-UE4SS.ps1` only copies it in when the probe folder has none (`$SeedOnly`, never an overwrite), and `tools/Sync-Routes.ps1` moves stops between the two:

- `.\tools\Sync-Routes.ps1` — deployed → repo, to be committed. Run it after a sweep.
- `.\tools\Sync-Routes.ps1 -Push` — repo → deployed, for a machine with no stops yet.
- Either direction refuses to overwrite a file with more stops than the source (`-Force` overrides), and keeps what it replaced as `routes.backup.txt`. Comment and blank lines are not counted, so the all-comments seed never looks like a route worth keeping.

## Montage sweep (I, added 2026-09-20)

Every animation of every kind of character in the level, played one at a time at 30 FPS and then at 320, without waiting for the gameplay that would normally start it. `tools/animtest.lua`, started with **I** or an `animtest.txt` trigger file (`here`, `level=LS102`, `caps=30,320`, `class=`, `montage=`, `restart`, `nosamples`, `all`); an empty `animtest.stop` file stops a run that is going.

- **Finding the animations.** `lib/anim.lua` walks every loaded `AnimMontage` once per level and groups them by their `Skeleton`, which is what decides whether a montage can play on a character. Each montage goes to the character whose own plugin folder it comes from (`/CES1035_GreenDruid/Animations/Montages/...` → `BP_CES1035_GreenDruid_C`), and one no character here claims goes to the first character that can play it. One character per class, plus the player.
- **Both caps in one level visit**, so the same montages are loaded for both and each level is travelled to once. A montage already measured at a cap in an earlier level is skipped (`animtest_done.txt`), which is what keeps a whole-game run to hours: the rhynocs share most of their animations.
- **Per montage:** the character is put back on the spot and facing it had when the level's montages were listed (a montage with root motion leaves it somewhere else, and the next one played from there can meet a wall), then `Montage_Play` from a standstill, then per frame the montage position, the character's position, whether root motion is driving it, and the particle and audio components its notifies make. Row per montage per cap in `animtest_<stamp>.csv`, sample rows in `animtest_samples_<stamp>.csv`. `result` is `played` (it ran to its blend out), `looped` (its last section ran back to the start, so the duration is one pass), `cut short` (the character's own state machine played something over it), `stuck` (the position never moved) or `refused`.
- **Things that had to be held still for the measurement to mean anything** (all restored afterwards, `lib/anim.lua`): `MeshComponentUpdateFlag` and `bEnableUpdateRateOptimizations` (a character that isn't being looked at ticks its animation at a reduced rate), `bPauseAnims`, `bNoSkeletonUpdate`, `GlobalAnimRateScale`, the mesh's component tick and `CustomTimeDilation` — a character the game has no use for yet (the Town Square thief) sits at montage position 0 for ever otherwise. The character's AI keeps walking it about even with the actor's tick off, so only frames where root motion is driving it count towards the displacement and it is put back on every other frame (`drift` is how far it had to be pulled back).
- **One character on its own (`spawn=`, added 2026-11-14).** `animtest.txt` with `spawn=Cowlek` (a class from `tools/spawnlist.lua` by name or unique fragment, or a full class path) measures just that character in the test room, `tools/testroom.lua`: the game ships no empty map, so the room is an 8000 x 8000 floor made from the engine's cube (`/Engine/BasicShapes/Cube`, one `StaticMeshActor`) at the first height from 8000 above Spyro where line traces over its footprint find 2000 units of clear air. It keeps Spyro's X and Y, so the position grid is the level's own. Spyro is teleported onto it, the character is spawned in the middle 600 units in front of him, and every montage loaded for its skeleton is played from that spot at each cap. Such a run ignores and does not touch `animtest_done.txt` or the sweep's progress file, and when it ends (done, stopped or an error) it destroys the character and the floor and puts Spyro back. `tools/Test-EnemyAnims.ps1 -Enemy Cowlek` does all of it from outside the game, including starting the game, and writes `build\animtest\<stamp>_<enemy>\compare.txt`.
- **Comparing.** `tools/Compare-Animtest.ps1` joins the caps on the montage's asset path and flags duration, root-motion displacement, notify counts and result mismatches, worst first.

## Animation sampling in the scripted tour (added 2026-09-20)

A **review** run (`review.txt` in the probe folder, or `review` in `autotest.txt`) is the scripted tour for somebody watching: one walk-in stop per spot, at 30 FPS, no lead scripts, crossing into the next game through the game state's `start game`. F3 marks a stop as fine, F4 as wrong and holds the tour on it until F3; each verdict goes to `review_<stamp>.txt` with the target's distance, its angle off Spyro's facing and whether a conversation was open. Conversation stops steer at the character and walk until they touch it or the conversation opens, and Zoe, the save fairies and Moneybags are walked into too (Continue is pressed while their prompt pauses the world). Cutscenes get the skip button: the cutscene actor's own `SkipCutscene` input event, for `Spyro_IGC_Sequence` cutscenes while `CurrentlyActiveIGC` Spyro 1 dragons (`Collectable_Dragon`, which checks its own `CutsceneActive`/`Bypass Available`) and Spyro 3 movies (`BP_SP3_CinematicActor`, between `Started` and `Finished`). Only fodder is left out.

The scripted tour (**O**) also writes `autotest_anims_<stamp>.csv`: two rows per sample, for the played character and the character the stop was recorded in front of, with the montage, how far into it, its section, the Falcon enemy state and where each has moved to. That covers the animations the sweep can't reach on its own — state-machine locomotion, dialogue and the minigames. `tools/Compare-Anims.ps1` joins the passes and reports how often each character was in a different animation than at 30 FPS. `tools/scan.lua` now records a stop per class *and script*: `walk`, `flame` and `charge` for enemies (CES/CBS), `walk` and `enterPlay` for NPCs and fauna (CNS/CFS) — `enterPlay` walks in, taps through the dialogue and then holds forward and jumps, which is how a minigame's own animations are reached. Reaching the character no longer stops the script's buttons, only its walking, so the tapping carries on.

Sparx is kept full whenever the probe is loaded (`KEEP_SPARX_FULL` in `main.lua`, `lib/invuln.lua`: the game's own `GE_BasicHeal` applied once per missing point every 2 s), not just while a test tool runs, so a run is never cut short by a death and a level reload. Spyro still takes hits and knockback. A spawn test that is already going can be stopped from outside the game with an empty `spawntest.stop` file in the probe folder (the start trigger, `spawntest.txt`, is only read between runs).

## Gem thief and non-finite speed (Y, added 2026-09-27)

- `trackers/gemthief.lua` watches the Artisans gem thief (`BP_CES1012_GemThief`), whose flee animation
  breaks because his anim Blueprint's `Speed` goes NaN (`docs/findings/gem-thief-anim.md`). **On by
  default** (Y turns it off and on with the sweep), fed the level's characters by the shared
  `PhasmidCharacter` notification rather than polling `FindAllOf`. It
  logs `gemthief` once a second and on every state change (state, movement mode, velocity, the ABP `Speed`,
  the blendspace X, the ABP's last DeltaTime and `lib/anim.diagnose`'s mesh flags), `gemthief poisoned` on
  the finite → non-finite transition with the previous frame's values, `gemthief nan` /
  `gemthief moving-idle` while the pose is wrong, and `gemthief healed` when `HEAL` writes the live speed
  back over a NaN, and `gemthief verdict … HELD/BROKE/INCONCLUSIVE` `VERDICT_WINDOW` seconds later, which
  is how the fix is checked: HELD means he ran with nothing non-finite and the blendspace X keeping up.
- **T** writes the NaN into his anim Blueprint by hand and holds the heal back 5 s (`gemthief poison-test`),
  because the real poisoning needs a world that has been alive for hours — see
  `docs/findings/gem-thief-anim.md`. The pose should break for those 5 s and then come back.
- `trackers/nanspeed.lua` is the same check over every `PhasmidCharacter`: `Velocity`, the anim
  Blueprint's `Speed`, and the DeltaTime it last saw. **Y toggles it**, and it is off until then. Round
  robin, `SCAN_PER_FRAME` actors a frame, each re-read every `SCAN_INTERVAL`, and a newly constructed
  actor is left alone for `GRACE` seconds. Lines: `nanspeed <class> <name> <fields> mode=… vel=…`
  (first sighting per class, then at most one per class per `LOG_INTERVAL`), `recovered`, `healed`, and
  `nanspeed summary` per class every minute and on a pawn change.
- **The startup crashes during this investigation were not the probe** (2026-09-27 and 2026-10-05):
  `0xC0000005` at `Spyro-Win64-Shipping.exe+0x1891327` with `SecondsSinceStart=0`, i.e. before any tick,
  level or pawn, so no tracker had run. It survived disabling the probe and then the fix mod, and stopped
  when two unrelated pak mods (`SpyroFontMod_P.pak`, `SpyroHudDigits_P.pak`) were taken out of
  `Content/Paks/~mods`. The faulting loop reads an `FName` pair out of a stale pointer during engine
  init, which fits a mounted pak the game is iterating. Two suspicions along the way were wrong and are
  recorded so they are not re-litigated: a duplicate `NotifyOnNewObject` for
  `/Script/Phasmid.PhasmidCharacter`, and `trackers/gemthief.lua` polling `FindAllOf` every five seconds.
  The polling was still worth removing on its own merits (CLAUDE.md), and Y stays as a way to silence the
  level-wide sweep, but neither caused a crash.
