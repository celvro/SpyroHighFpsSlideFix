# SpyroFpsFixes

Mods for **Spyro Reignited Trilogy** (PC/Steam), built on **Unreal Engine 4.19**. Internal project name is `Falcon`. The shipped mod is a UE4SS Lua mod fixing high-framerate gameplay bugs.

**Target behaviour: every framerate must match 30 FPS** (the console tuning). Some glide distances are impossible otherwise, so a fix that makes 30 FPS behave like high FPS is wrong.

## Findings docs (read the relevant one before working on a fix)

Investigation logs live in `docs/`; each fix module in `ue4ss/Mods/HighFpsSlidingAndJumpFix/Scripts/fixes/` is also headed by a summary of its cause. **Add new measurements and conclusions to the matching doc (or a new one listed here), not to this file.**

| Doc | Topic | Status |
|---|---|---|
| `docs/findings/jump-glide.md` | Jump/hover height (zero-gravity phase rounds to frames), glide distance (position rounding), glide start wait, framerate config | fixed, verified |
| `docs/findings/sliding-walking.md` | Braking slide, acceleration lanes, stuck from standstill (float32 position quantization far from origin); walking off from rest turns differently above 30 FPS (8-way snap below 75% walk speed, decided per frame) | fixed, verified; turn snap measured 2026-11-16, not fixed |
| `docs/findings/charge-turn-camera.md` | Charge slip, mouse charge steering, camera centering, centering switch, stuck charge camera (native disassembly) | slip/steering/centering fixed, verified; `FIX_STUCK_CAMERA` **re-verified by A/B 2026-10-11** (`camrepro`, R): at a 33 deg start the gap runs to ~83 deg without it at both 30 and 315 FPS, and the camera catches up with it. **Still open**: a charge restarted within ~0.5 s of stopping and steered by mouse at ~210 deg/s, harsher than the tool's 130.8 |
| `docs/findings/super-charge.md` | Super charge stages, ramp, jump assist | matches 30 FPS |
| `docs/findings/charge-dust.md` | Charge dust (one-tick effects emit nothing at high FPS) | fixed, verified |
| `docs/findings/druid-energize.md` | Alpine Ridge green druid notify missed | fixed, verified |
| `docs/findings/fire-dragon.md` | Fireworks Factory dragon segments bunch up | fixed, verified |
| `docs/findings/thief-chase.md` | Gnorc thief chase speed | measured, not worth fixing |
| `docs/findings/flight.md` | Spyro 1 flight level speed (MaxFlySpeed follows pitch) | matches 30 FPS |
| `docs/findings/freed-dragon-walkin.md` | Walk-in after freeing a dragon (path following vs walking fix) | fixed, verified |
| `docs/findings/frame-spikes.md` | Hitches from `StaticFindObject` misses | fixed, verified |
| `docs/findings/charge-wall-stall.md` | Charge stalls against walls at high FPS (zero-displacement blocked frames) | fixed, verified |
| `docs/findings/flame-breath.md` | Stray flame lines (`hard_flames_velocity_muzzle`) | fixed (velocity scaling) |
| `docs/findings/balloon-camera.md` | Camera whirls around the balloonist's balloon (0.5 deg per tick timeline) | fixed, verified |
| `docs/findings/buzz-charge-run.md` | Spyro 3 boss Buzz runs in place (car movement from rest rounds to zero), slides after rolls | fixed, verified |
| `docs/findings/sheila-buzz-walk.md` | Sheila stalls and crawls around Buzz's arena (requested moves from rest round to zero) | fixed, verified |
| `docs/findings/skelos-badlands.md` | Skelos Badlands orb mission: lava lizard stuck at two steps (blocked sweeps in Phasmid custom mode), steam vent gust | fixed, verified; vent matches 30 FPS |
| `docs/findings/turtle-soup.md` | Sunny Beach turtle soup: box turtle walking (SeekPlayer, MaxWalkSpeed 80) and the charge slide (a projectile movement component, not the CMC) | matches 30 FPS at 220–270; untested above |
| `docs/findings/npc-stalls.md` | Every NPC/enemy checked for the same stall from rest (static survey, probe stall tracker and level tour) | stalls confirmed (low-acceleration walkers), not fixed in general; Zephyr's Sergeant Tub fixed and verified 2026-11-18 (`fixes/npcwalk.lua`, class list); Stone Hill rams fixed and verified 2026-11-19 (same module, measured with `tools/Compare-ReplayActors.ps1`); Gulp (Spyro 2 boss) fixed and verified 2026-11-19 (same module; its "blocked" test now judges against 30 FPS acceleration); Zephyr cowleks checked 2026-11-19, no stall |
| `docs/findings/bamboo-barrels.md` | Bamboo Terrace rolling boulders and barrels spin 10 deg per tick (`fixes/barrelspin.lua`); far actors tick every 0.1 s, which hides it | fixed, verified |
| `docs/findings/frozen-altars-lasers.md` | Frozen Altars roof lasers hit once per tick, enemies count hits (`fixes/rooflaser.lua`: 1/30 s tick interval for lasers and targets) | fixed, verified (one run) |
| `docs/findings/s3-reports-2026-11.md` | Not reproduced unattended: Sunrise Spring head-bash rock and egg (rock/egg cannot be reset), Lost Fleet skateboard wipeouts (native crash test) and Hunter sliding | open |
| `docs/findings/gem-thief-anim.md` | Artisans gem thief runs in his idle pose (NaN `Velocity` when a flee starts from rest latches the anim Blueprint `Speed`) | fixed, verified (the real poisoning only reproduced by hand) |
| `docs/findings/animations.md` | Every character's animations at 30 vs 320 FPS: the montage sweep (duration, root motion, notify effects) and the scripted tour's animation sampling, including minigames | tooling built, first level measured |
| `docs/ue4ss.md` | UE4SS install details, profiling history, Lua GC experiments | reference |
| `docs/tools.md` | Full packaging/Vortex/tool notes | reference |
| `docs/findings/tour-2026-11.md` | First full trilogy tour (1843 stops at 30/30/60/160): 20 cross-checked findings, 13 of them a charge; Cupid shown to be an arrow rather than the framerate, and the three harness artefacts the run exposed | measured, charge cluster open |
| `docs/probe.md` | Probe mod: log lines, CSV columns, hotkeys, quicksave, level streaming, the `cmd.txt` command channel | reference |
| `docs/findings/frame-rate-ceiling.md` | Uncapped FPS and what the mods cost: PresentMon method (`tools/Measure-FrameTime.ps1`), probe 0.8 → ~0.15 ms (cached PlayerController), fix mod 0.22 ms Zephyr / 0.40–0.45 ms Stone Hill (mostly `npcwalk`, now 0.19–0.20 ms), UE4SS out-param registry leak, 320 FPS driver cap | measured 2026-11-19; probe and npcwalk idle cost fixed |

## Game install

- Game root: `C:\Program Files (x86)\Steam\steamapps\common\Spyro Reignited Trilogy`
- Executable: `Falcon\Binaries\Win64\Spyro-Win64-Shipping.exe` (launched through `Spyro.exe`)
- Paks: `Falcon\Content\Paks\pakchunk{0,1,2}-WindowsNoEditor.pak` (version 4, unencrypted index). Mod paks go in `Falcon\Content\Paks\~mods\` as `*_P.pak`.
- User config (overrides pak config): `%LOCALAPPDATA%\Falcon\Saved\Config\WindowsNoEditor\`
- UE4SS log: `Falcon\Binaries\Win64\ue4ss\UE4SS.log`. Crash dumps: `%LOCALAPPDATA%\Falcon\Saved\Crashes\*\UE4Minidump.dmp` (read with `build/DumpInfo/DumpInfo.exe <dmp>`, and pipe that through `tools/Resolve-Ue4ssStack.ps1` to turn `UE4SS.dll+0x...` into function names — it needs the local build's `UE4SS.map`, and it is how the world tour's crash was found in one go instead of bisected). A **hang** writes no crash dump: take one of the frozen process with `dbghelp`'s `MiniDumpWriteDump` (type `0x1000`; `comsvcs.dll MiniDump` writes a file only admins can read) and read it with `DumpInfo <dmp> --threads` (`docs/probe.md`, "Touching a text box during a replay").

## Unpacked reference content (read-only, never modify)

Unpacked into `Falcon\Content\Paks\chunk0|chunk1|chunk2`, each relative to its pak's mount point:

| Folder | Mount point        | Top-level dirs         |
|--------|--------------------|------------------------|
| chunk0 | `../../../`        | `Engine/`, `Falcon/`   |
| chunk1 | `../../../Falcon/` | `Content/`, `Plugins/` |
| chunk2 | `../../../Falcon/` | `Content/`, `Plugins/` |

So `chunk1\Plugins\Levels\...` is the game path `Falcon/Plugins/Levels/...`. Project config is in `chunk0\Falcon\Config\`. Game content is split into plugins under `Falcon/Plugins/` (`Characters`, `Levels`, `GameplayCommon`, …). Audio is Wwise.

## Rules and gotchas

- **Never poll `StaticFindObject` for something that may not exist**: a miss scans the whole object array (~10 ms). Trigger lookups from `NotifyOnNewObject` instead. `FindAllOf` costs the same walk, so a lookup that falls through to one every frame is the same bug wearing a different name: `lib/input.lua`'s `input.clear` dropped its cached component, and the tour's death and verify phases call that every frame, so a death spent a whole object-array walk and a log line per frame (measured at 30 a second in LS109, 2026-11-04). Cache the hit, key it on something that cannot be reused under you, and put a cooldown on the miss.
- `RegisterHook` on a **Blueprint** function (this UE4SS build) calls only the pre callback, and it runs **after** the function body; post never fires. Register the same idempotent callback as pre and post.
- **A struct out-param table comes back filled, so empty it before every call**: pass it through `util.clearHit` (both mods' `lib/util.lua`). UE4SS copies a struct out-param back into the very table it was handed, so a table reused at module level holds all of `FHitResult`'s fields from the second call on, and feeding its three `TWeakObjectPtr` members (`PhysMaterial`, `Actor`, `Component`) back in logs `[push_weakobjectproperty] Operation::Set is not supported` three times per call — 0.122 ms each, file plus console, on the game thread, even though nothing reads the out-param. An empty table is skipped field by field. Omitting the param throws (the supplied count must match the UFunction's) and so does `nil` (a struct out-param needs a table on the stack). See `docs/findings/jump-glide.md`.
- **An object kept from one frame to the next must be `IsValid`-checked again before every touch, and `pcall` is no protection.** A Lua wrapper holds a raw `UObject*`; once the game frees the object (a sublevel streaming out is enough — a teleport across a level freed 21 of 111 cached actors in 1.7 s), asking it anything is an access violation inside `UE4SS.dll`, which takes the game down rather than raising a Lua error, so a `pcall` around the call catches nothing. `obj:IsValid()` is the real test — non-null, in the map of objects Lua has wrapped (UE4SS's delete listener erases from it on destruction), and not unreachable — and it never dereferences the pointer, so it is safe to ask about a wrapper that has gone dead. It cannot see a *reused* address, so a cache keyed on an address can still hand back the wrong object. This cost the world tour every unattended run until 2026-11-04 (`docs/probe.md`).
- UE4SS Lua is 5.4 (no `math.pow`/`math.frexp`). Per-frame errors log once (`errorLogged`), so check `UE4SS.log` for `error:` lines before trusting a test.
- **A trigger file written from PowerShell starts with a BOM, and that silently eats its first option.** `Set-Content -Encoding utf8`, `>` and `Out-File` all write `EF BB BF` in Windows PowerShell 5.1. Those bytes stick to the first word, so `game=2` stops matching `^(%w+)=(.*)$` and is stored as a flag instead — a sweep asked for `game=2` swept all three games' level lists on 2026-11-04 and nothing in the log said why. Write them with `[IO.File]::WriteAllText(path, text, [Text.UTF8Encoding]::new($false))` or `-Encoding ascii`. On the Lua side `lib/util.lua`'s `stripBom` handles it; `tools/scansweep.lua` and `tools/animtest.lua` use it, and the other trigger readers (`dumpstate`, `minigame`, `scan`, `spawntest`, `worldtour`) still do not. Easiest: `tools/Invoke-Probe.ps1 trigger <tool> [options]` has the probe write the file itself.
- Lua trap: `local a, b = x and x:match(...)` truncates to one value.
- Hot reload (Ctrl+R) occasionally crashes this UE4SS build; restart the game instead if it does. UE4SS also watches the deployed `Scripts/` folder, so `Install-UE4SS.ps1 -ModsOnly` **while the game runs** triggers the same reload and can crash it the same way (an access violation inside `UE4SS.dll`, nothing in `UE4SS.log` after the `Auto-reloading Lua mod` line). Close the game before deploying.
- Never shrink `MaxSimulationTimeStep` below a frame for experiments (substeps reproduce the sliding bug at 30 FPS).
- Hotkeys: never F11 (game fullscreen toggle) or Ctrl+R (UE4SS). The game binds every number key, W/A/S/D/E/F/P/Q/X/Z, LeftControl and the arrows. The player has no numpad.
- Don't use the `RestartLevel` console command (drops to the title screen).
- `PROFILE` in either mod's `Scripts/config.lua` must be `false` in commits.
- **The probe costs frame time on the game thread.** Its trackers are switched in `ue4ss/DevMods/SpyroFpsProbe/Scripts/config.lua`; only the ones a run needs should be on, and a framerate measured with the probe loaded is not the game's own. `PROFILE` there times each tracker separately.
- The mod folder and `[HighFpsSlidingAndJumpFix]` log prefix keep the old name on purpose: renaming would leave older installs loaded alongside and apply every fix twice.
- Disassembly: the exe's `.text` is SteamStub-encrypted on disk. `tools/Read-GameVtables.ps1 -OutExe` writes a copy with the decrypted `.text` from the running game, then use `dumpbin /DISASM /RANGE:...` (VS 2022). Native reflection names are plain strings in the exe; `tools/Find-PropertyParams.ps1` finds property offsets.

## Hooking a Blueprint function (fix recipe)

Examples: `fixes/balloon.lua` and `fixes/dragon.lua` (level Blueprints), `fixes/dust.lua` (Spyro's Blueprint), `fixes/buzz.lua` (an enemy's ReceiveTick, per actor).

1. **Find the code**: `build/AssetDump/AssetDump.exe <file.uasset> --code`. Most Blueprint logic is in `ExecuteUbergraph_<Class>`. Event and timeline stubs just jump into it, e.g. `Timeline_0__UpdateFunc` → `ExecuteUbergraph_X(7650)`, so read from that offset. Timeline lengths are in the `*_Template` exports. Timeline update functions run once per tick, so any fixed step inside one is per frame.
2. **Function path**: `/<Plugin>/<path under Content>/<Asset>.<Asset>_C:<Function>`, where the plugin is the folder under `Falcon/Plugins/`. Example: `chunk0\Falcon\Plugins\GameplayCommon\Content\LevelMechanics\...\BalloonTransporter.uasset` → `/GameplayCommon/LevelMechanics/.../BalloonTransporter.BalloonTransporter_C:Timeline_0__UpdateFunc`.
3. **Look it up without polling**: at load, call `lookup.watch("/Script/Engine.BlueprintGeneratedClass", "<Asset>_C", state)`, where `state` has `retryIn = 0, lookups = 1`. Then in `update()` call `lookup.find(state, path)`, which only spends lookups granted when the class is created.
4. **Register the hook**:
   - **Classes that stay loaded** (the player Blueprint): use `lookup.registerBlueprintHook(state, path, cb, cb, name)` once.
   - **Level Blueprints** (and characters that load with a level, like bosses): the function object is replaced every time the level loads, so compare `fn:GetAddress()` against the last hooked address and call `RegisterHook` again when it changes. `RegisterHook` can fail while the level is still loading (`UFunction::Func 0x0`), so keep `lookups >= 1` and retry, and give up after `lookup.MAX_FAILURES`. `lookup.hookLevelFunction(target, cb, name)` does all of this (used by `fixes/buzz.lua` and `fixes/sheila.lua`).
   - Put fixes that only hook or patch level content in `levelFixes` in `main.lua`: they run without a pawn. Fixes that act on Spyro go in `pawnFixes`.
5. **Callback**: `context:get()` is `self`, and parameters are read with `param:get()`. The callback runs after the body (see Rules), so correct the result rather than the inputs. Wrap it in a guarded function: on the first error, `pcall` the body, set `fix.failed`, undo engine changes and log it once. Make it idempotent: act once per call, e.g. keyed on `engine.frame` plus the actor address. Wrap it in `profiler.wrapHook(name, cb)`: hooks run outside the timed tick, so that is the only way `PROFILE` measures them.
6. **Inside the callback**:
   - For dt, use `engine.worldDeltaSeconds(actor)` (times the actor's `CustomTimeDilation` if the Blueprint's timing uses it), not `engine.dt`, which is from the tick.
   - Leave frames alone unless `util.aboveReferenceFps(dt)`.
   - Pass out-params (e.g. `SweepHitResult`) and struct arguments as tables reused at module level, so the hook doesn't allocate every frame. **Empty a reused struct out-param table before every call** (`util.clearHit`, in both mods' `lib/util.lua`) — see the rule below.
   - To move a component, call its `K2_Set*`/`K2_Add*` function. Writing `RelativeRotation`/`RelativeLocation` directly doesn't update the transform.
7. **Wire it up**: add a `FIX_*` switch to `config.lua`, the module to `main.lua`, a findings doc plus a row in the table above, and a `README.txt` line once it's verified.

## Repo layout

- `ue4ss/Mods/HighFpsSlidingAndJumpFix` — the shipped mod, published as "High FPS Gameplay Fixes" (`VERSION` in `main.lua`; player-facing `README.txt` in the mod folder). `Scripts/`: `config.lua` (every `FIX_*` and profiling toggle), `lib/` (log, cached engine handles, lookup/hook bookkeeping, UE 4.19 movement math), `fixes/` (one module per fix), `profiler.lua`, `main.lua` (the tick). A fix module returns `{ name, enabled, update(ctx) [, reset()] [, disable(ctx, err)] }`; `main.lua` builds `ctx` once per frame, runs fixes in order, and on error calls `disable` and drops that fix.
- `ue4ss/DevMods/SpyroFpsProbe` — per-frame logger for investigating framerate bugs (see `docs/probe.md`). `Scripts/`: `config.lua` (a switch per tracker, the trace CSV and the optional row reads, plus profiling), `lib/` (log, the per-frame row, the trace CSV, object dumps, level streaming queries, the per-tracker profiler), `trackers/` (one module per measurement, each documenting its log lines), `tools/quicksave.lua` (V/B/L/N), `tools/scansweep.lua` (a `scansweep.txt` trigger file: travels every level and scans it, building `routes.txt` for the world tour), `main.lua` (`sample()`, keys, notifications). Shared frame state (previous row, ids of the measurements in progress) is in `lib/state.lua`; everything else is local to its tracker. A tracker that `config.lua` turns off keeps its constants but every function on it becomes a no-op, so it costs nothing per frame.
- `tools/Install-UE4SS.ps1 [-ModsOnly] [-Probe] [-Uninstall]` — installs UE4SS (staged in `tools/bin/ue4ss-dist/`, gitignored) and the Lua mods. Use `-ModsOnly` after editing Lua. Files in its `$SeedOnly` list (`routes.txt`) are only copied when the deployed mod has none, never overwritten: the game writes to them.
- `tools/Sweep-AllGames.ps1 [-Games 1,2,3] [-Levels ...] [-Range ...] [-Resume]` — runs the scan sweep over all three games unattended: a game per run (the cross-game switch is a no-op), restarting the game and resuming from `scansweep_progress.txt` when it crashes or stalls, and pulling the stops into the repo after each game. `sweepall.stop` in the probe folder ends it.
- `tools/Tour-Unattended.ps1 [-Caps 30,30,60,160] [-Levels ...] [-Scripts ...] [-Resume]` — runs the world tour to the end unattended: restarts the game and resumes from `autotest_progress.txt` on a crash or a stall, saves each launch's `UE4SS.log` (it is truncated per launch, and the trackers' lines are nowhere else), concatenates the per-launch CSVs into one, and runs both comparisons into `build\tour\<stamp>\`. **Read `compare-autotest.txt` and `compare-anims.txt`, not the log.** `tourall.stop` in the probe folder ends it. It refuses to start while the probe's per-frame trace CSV is on, which would write tens of GB over a night.
- `tools/Test-EnemyAnims.ps1 -Enemy <name or class path> [-Montage ...] [-Caps 30,320] [-Level ...] [-Restart]` — one character's animations at 30 and 320 FPS, away from any level: the probe builds a flat floor in the sky (`tools/testroom.lua`), puts Spyro on it, spawns the character and plays every montage it has (`animtest.txt` with `spawn=`). Starts the game if it is not running, and writes `build\animtest\<stamp>_<enemy>\compare.txt`. The `enemy-animtest` skill (`.claude/skills/`) is the how-to.
- `tools/Invoke-Probe.ps1 <command> [-Timeout s] [-Async]` — drives the running probe through `cmd.txt` and prints its answer from `cmd_result.txt` (`lib/cmd.lua`; exit 0 ok, 1 error, 2 no answer). `state`, `cap 320`, `travel LS103`, `replay take=<id> cap=320` (waits for the run to end), `key <any probe hotkey>`, `trigger <tool> ...`, `eval <lua>`; `help` lists them. **Prefer it to sending keys through computer use.** See "Command channel" in `docs/probe.md`.
- `tools/Compare-ReplayActors.ps1 -Take <id> [-Class <text>] [-All]` — every character (not Spyro) between the recording of a level replay take and its runs (`-All`: every run, one column each), from the `_actors.csv` the recording and each replay write (`lib/actortrace.lua`, config `REPLAY_ACTORS`): per class and per character the largest position gap, and for each move from a standstill the time to 50/90% of its top speed and the distance in its first 0.5 s. **Use it instead of reading per-frame data.** Reference: the recording (newest 30 FPS run for takes before 2026-11-19); `-Reference`/`-Run` also take two recordings (one per framerate, for characters that wander at random). The `npc-accel-check` skill is the how-to.
- `tools/Sync-Routes.ps1 [-Pull] [-Push] [-Force]` — moves the world tour's stops between the deployed probe folder and the tracked seed `ue4ss/DevMods/SpyroFpsProbe/routes.txt`. `-Pull` (the default) brings recorded stops into the repo to be committed; run it after a scan sweep. **The stops exist nowhere else** — the route the level tour built in 2026-09 was lost because the file was only ever in the game folder.
- `tools/Package-Release.ps1` — release zip `build/release/HighFpsGameplayFixes-<VERSION>.zip`, game-root layout, with `vortex_override_instructions.json` (`setmodtype dinput`) so Vortex deploys to the game dir. Any file a tagged release shipped that the current version dropped is written into the zip as a one-line comment, since extracting over an old install can't delete files. Needs a UE4SS experimental build (`LoopInGameThreadAfterFrames`).
- `tools/Package-UE4SS-Release.ps1` — `build/release/UE4SS-for-Spyro-<version>.zip` (only change: engine version 4.19 in the packaged settings). UE4SS is MIT: never strip its `LICENSE`/`LICENSE.txt`/`README.txt` credits.
- `tools/Config.ps1` (shared paths, `$env:SPYRO_GAME_DIR` override), `tools/Zip.ps1` (`New-ZipFromEntries`)
- `tools/Save-GameSnapshot.ps1` / `tools/Restore-GameSnapshot.ps1` — named copies of `FalconSave.106.sav` in `build/saves/` (progress only, not position; restore refuses while the game runs)
- `tools/Compare-Segments.ps1` — probe airborne segment stats
- `tools/Find-PropertyParams.ps1`, `tools/Read-GameVtables.ps1`, `tools/Find-ExeReferences.ps1` — exe reverse-engineering helpers; `tools/Capture-FlameParticles.ps1` — read-only particle sampler
- `tools/DumpInfo/` — minidump reader (`dotnet build tools/DumpInfo -c Release -o build/DumpInfo`)
- `tools/AssetDump/` — cooked UE 4.19 `.uasset` reader (`dotnet build tools/AssetDump -c Release -o build/AssetDump`; `AssetDump.exe <file.uasset> [--export <name>] [--no-props] [--code] [--hex]`; `--code` disassembles Blueprint bytecode)
- `build/` — generated output (gitignored)

## Tooling

- Scripts are PowerShell. Python is not installed (the `python` on PATH is the Store stub).
- Lua 5.4 interpreter (matches UE4SS): `winget install --id DEVCOM.Lua --exact`, installed to `%LOCALAPPDATA%\Programs\Lua\bin` (`lua`, `luac`, `luarocks`). `tools/Check-Lua.ps1 [-Path ...]` byte-compiles every `.lua` in both mods with `luac -p` and reports each parse error — run it after editing Lua, before reinstalling, to catch typos and 5.3-isms without a game restart. It cannot run the scripts: they need UE4SS globals.
- `tools/tests/` — the Lua that *can* run outside the game, because it reaches it only through modules that can be stubbed. `lua tools\tests\scansweep_test.lua` drives the scan sweep's state machine (every level, each option, travel and game-switch failures, the stop file, the resume) and exits non-zero on a failure. `lua tools\tests\igc_test.lua` does the same for `lib/igc.lua`'s freed-actor guard: its fake actors record any access made after they were freed, which is the crash that cost the world tour every run (run against the pre-fix file it reports six failures, all `GetClass` on a freed actor). `lua tools\tests\leftstick_test.lua` checks `input.sendLeftStick` (the level replay's left stick) against a model of Spyro's ground-movement Blueprint: every frame of a replayed key or analog sequence must consume the same input as the recording. `lua tools\tests\cmd_test.lua` drives the command channel (`lib/cmd.lua`): parsing, keys, commands waiting for Spyro, and the started/done commands. Add a test here for any tool whose logic is separable from the engine.
- No pak build pipeline (restore `tools/Build-Mod.ps1` + repak from commit 50c1467 if an asset or config pak is ever needed). Edit `.uasset`/`.uexp` with UAssetGUI or FModel set to UE4.19; ship the matching `.uexp`/`.ubulk`.
