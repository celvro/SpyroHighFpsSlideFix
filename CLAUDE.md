# SpyroFpsFixes

Mods for **Spyro Reignited Trilogy** (PC/Steam), built on **Unreal Engine 4.19**. Internal project name is `Falcon`.

## Game install

- Game root: `C:\Program Files (x86)\Steam\steamapps\common\Spyro Reignited Trilogy`
- Executable: `Falcon\Binaries\Win64\Spyro-Win64-Shipping.exe` (launched through `Spyro.exe`)
- Paks: `Falcon\Content\Paks\pakchunk{0,1,2}-WindowsNoEditor.pak`
  - Pak **version 4**, **unencrypted** index
- Mod paks go in `Falcon\Content\Paks\~mods\` and are named `*_P.pak` so they take priority over retail paks
- User config (overrides pak config): `%LOCALAPPDATA%\Falcon\Saved\Config\WindowsNoEditor\` (`Engine.ini`, `GameUserSettings.ini`, …)

## Unpacked reference content (read-only)

Unpacked into `Falcon\Content\Paks\chunk0|chunk1|chunk2`. Each folder is relative to its pak's mount point, so paths differ:

| Folder | Mount point        | Top-level dirs      | Files  |
|--------|--------------------|---------------------|--------|
| chunk0 | `../../../`        | `Engine/`, `Falcon/` | 58,539 |
| chunk1 | `../../../Falcon/` | `Content/`, `Plugins/` | 99,043 |
| chunk2 | `../../../Falcon/` | `Content/`, `Plugins/` | 31,623 |

So `chunk1\Plugins\Levels\...` is the game path `Falcon/Plugins/Levels/...`. Never modify these folders.

Notable locations:
- Project config: `chunk0\Falcon\Config\` (`DefaultEngine.ini`, `DefaultGame.ini`, `DefaultInput.ini`, `DefaultDeviceProfiles.ini`, `Windows\WindowsEngine.ini`, `ConsoleVariables.ini`)
- Game content is split into plugins under `Falcon/Plugins/` (`Characters`, `Levels` e.g. `LS101_ArtisansHome`, `GameplayCommon`, `UserInterface`, `Sound`, …)
- Audio is Wwise (`.bnk`/`.wem`)

## Framerate-related findings

- `Falcon/Config/ConsoleVariables.ini` has `[Startup] t.MaxFPS=30`
- `DefaultEngine.ini`: `bUseFixedFrameRate=True`, `FixedFrameRate=30`, `bSmoothFrameRate=False`, `SmoothedFrameRateRange` 22–62
- `Windows/WindowsEngine.ini` overrides this for PC: `bUseFixedFrameRate=False`, `FixedFrameRate=60`, `bSmoothFrameRate=True`
- `DefaultGameUserSettings.ini`: `FrameRateLimit=0`, `bUseVSync=False`

## Jump / glide framerate bug research

Symptom: Spyro reaches ledges at 30 FPS that he can't reach at 60+ (jump height and/or glide distance).

- Movement component is native `PhasmidCharacterMovementComponent` (`/Script/Phasmid`, in the exe). Spyro's blueprint (`CPS1999_Spyro/Content/Blueprints/BP_CPS1999_Playable`) doesn't override `MaxSimulationTimeStep`, so it's the engine default 0.05 and there's no substepping at 30 or 60 FPS.
- Movement values come from gameplay attributes initialized by `CharacterCommon/Content/Data/SpyroCharacterInitialDataTable` (Spyro row: `JumpZVelocity=209`, `JumpMaxHoldTime=0.233`, `GravityScale=0.77`, `GlideDescentMultiplier=-0.31`, `AirControl=1`). World gravity is -980.
- `GA_Spyro_Jump` (Blueprint): `SetupJumpEffects` applies `GE_SpyroJumpNoGravity` (GravityScale overridden to 0 for a duration equal to the `JumpMaxHoldTime` attribute) and copies `JumpMaxHoldTime` to the Character. It then runs the native `PhasmidTask_JumpWithConfirm` and calls `Character.Jump()`. Releasing the button (`OnJumpStop`) removes the no-gravity effect and calls `StopJumping` (skipped while `Character.Enable.NoJumpStop` is set).
- `GA_Spyro_Glide` only sets an initial glide velocity. Glide motion itself is native.
- Neither ability has per-tick Blueprint logic, so the framerate dependence is most likely in native movement code. The no-gravity effect's expiry is also rounded to a frame boundary.
- **Probe heights before 2026-09-13 21:10 are biased.** Old `seg` apex/landDz/horiz values were measured from the first *airborne* frame, which already rose one frame (6.97 units at 30 FPS, 1.45 at 144). That hid the jump bug. Probe and `tools/Compare-Segments.ps1` now measure from the last grounded frame.
- **Confirmed jump height bug.** Every GE_SpyroJumpNoGravity jump (ground, water, charge) peaks higher at 30 FPS. Full-hold ground or water jump: +84.64 at 30 FPS vs +79.74 at 144. Trace `build/probe/water.csv`.
  - Mechanism, from per-frame traces: with the button held to timeout, gravity stays off for ceil(H/dt) frames plus usually 1 frame of lag. That's 8 frames (0.2667 s, 55.73 units) at 30 FPS and 35 frames (0.2431 s, 50.80 units) at 144. Apex = zero-gravity rise + 209²/(2·754.6) = 28.94; that sum matches the measured apex exactly. A few jumps show 0 lag frames (7 frames at 30, 34 at 144).
  - Early release: gravity stays off exactly for the held frames (no extra frame), so the release rounds up to the frame grid.
  - Fix in `HighFpsSlidingAndJumpFix`: track the zero-gravity rise and, when the engine restores gravity, compute the 30 FPS rise: timeout → (ceil(H·30) + lag)/30, release → ceil((rise − dt/2)·30)/30. Keep `GravityScale = 0` until then, then fold the sub-frame leftover into Z velocity (vz'² = vz² + 2·g·vz·leftover) so the apex matches exactly. A replay over recorded traces showed no extension at 30 FPS and +3 frames for 144 FPS full holds. **Verified in game (2026-09-13 21:23):** full-hold standing jump apex was +84.68 at 144 FPS with the fix (×3), +84.64 at 30 FPS, and +79.74 at 144 FPS without it. Charge jump apex was +74.58 at 144 FPS with the fix vs +74.50 at 30 FPS, and 68.7–70.4 without it. The fix made no changes at 30 FPS.
- Glides: in straight-glide tests the glide phase itself (speed 367.8, descent −114) is identical at 30 and 144 FPS. Glide distance differences come from takeoff height (the jump bug above) and glide start timing. Canyon long-glide comparisons using the old biased probe numbers were inconclusive.
- Untested: hover at the end of a glide (`OnHoverFromGlide` applies GE_SpyroJumpNoGravity too, so the fix should cover it) and landing on ledge edges (the Steam "slips off" report may be the slide bug).
- The probe treats swimming as airborne, because surface swimming uses MovementMode Flying (5) like gliding. Water jumps therefore don't get their own `seg` lines; find them in the CSV as mode 5 → 3 with vz > 0.
- Never shrink `MaxSimulationTimeStep` below a frame for experiments. Substeps reproduce the high-FPS sliding bug even at 30 FPS, and the braking fix doesn't account for substeps.

**Target behaviour: every framerate must match 30 FPS** (the console tuning). Some glide distances are impossible otherwise, so a fix that makes 30 FPS behave like high FPS is wrong.

## High-framerate sliding bug

Above ~80 FPS, Spyro keeps sliding at a constant low speed after a short step. The cause was confirmed with probe traces (steady 144 FPS vs 60 FPS):

- Levels sit far from the origin (e.g. x≈-301,800, y≈-299,500), where float32 positions have 1/32 unit spacing.
- UE 4.19 `PhysWalking` resets `Velocity = (location change) / dt` after every move, so velocity is quantized to multiples of (1/32)/dt: 4.5 at 144 FPS, 1.875 at 60.
- Braking is stock `ApplyVelocityBraking`, fitted from traces as friction 16.0 and deceleration 100 (speed drop per second = 16·speed + 100). At high FPS one frame's braking is less than half a quantization step, so the rounded move restores the old speed, e.g. stuck at (−9, −9) forever. At 60 FPS braking always exceeds half a step, so he stops in 9 frames. The threshold is where deceleration < (1/32)/(2·dt²), about 80 FPS at this spacing.
- Frame pacing is not the cause: frame times were a steady 6.9–7.4 ms. The "uncapped + VSync" workaround just holds a 60 Hz display at 60 FPS.
- Fix: `ue4ss/Mods/HighFpsSlidingAndJumpFix` (always on, no toggle). While walking with zero acceleration, it tracks the unquantized braked velocity using the engine formula. It writes that value back when the engine's value differs only by quantization, and never when a real collision changed it.

## Charge dust bug (found 2026-09-14 from assets; second fix verified in game 2026-09-14 20:25)

Reported: the dust behind a ground charge only shows at 30 FPS, and none appears at 60+.

- `BP_CPS1999_Playable` `ReceiveTick` → `Charge_Update` → `Charge_UpdateGroundEffects(IGetIsCharging)` runs **every frame**.
  - If IsCharging and `MovementModeCur == 1` and not `Character.MoveState.SuperCharging`: it deactivates `Charge_GroundEffects` (if valid) and `SpawnEmitterAttached`s a new effect into it. That's `PS_VFX_Spyro_Charge_DustTrail`, or `PS_VFX_Spyro_Splash_CleanWater_Shallow_Charge` when the floor PhysMat SurfaceType is 9.
  - Otherwise it only deactivates it. There is no gate, so each effect emits during exactly one tick.
- `PS_VFX_Spyro_Charge_DustTrail` emitters that matter: `Dust_L_Initial` and `Dust_R_Initial` (spawn rate curve 60 → 20 over t 0–1, duration 0.75, lifetime 0.3–0.5).
  - `Dust_*_Loop` (rate 100–130) have EmitterDelay 0.5, so they never start under per-frame respawn. The mesh emitters are disabled.
  - A fresh effect spawns floor(R·dt) particles per emitter in its only tick: (60 − 40·dt)·dt = 1.956 → 1 per side at 30 FPS, 0.989 → 0 at 60, 0.41 → 0 at 144.
  - Traced 30 FPS frame times are 33.3 ms in 37,675 of 37,853 frames (only 21 frames long enough for 2 particles), so 30 FPS is effectively 1 puff per side per frame.
- Other dust uses are fine: `GA_Spyro_SlideDown` and `GA_Spyro_Damage_SlideBack` spawn the dust trail once. `CheckGroundForDustEffect` (hover ground dust) spawns once and then moves the effect.
- **First fix failed (tested 2026-09-14 12:48–12:50).** It hooked `Charge_UpdateGroundEffects` pre and post, hid respawns from the Blueprint until 1/30 s had passed (`Charge_GroundEffects = nil`, `MovementModeCur = 0`) and dilated each new effect.
  - The hook registered and logged no errors, but no dust appeared at 144 FPS.
  - Probe at 144 FPS: `dustRate` 143.5–144/s and `dustDilationMax` 1.00, so it never hid a respawn or dilated an effect. At 30 FPS: 30.0/s.
  - Cause, confirmed by the second fix's debug counts: with this UE4SS build, only the "pre" callback of a Blueprint function hook runs, and it runs **after** the function body. The post callback never fires. That was true for both `Charge_UpdateGroundEffects` (called from Blueprint bytecode) and `ReceiveTick` (called through ProcessEvent). So the first fix's "pre" saw the new effect as already present and never tracked it.
- **Second fix** (`FIX_CHARGE_DUST`), which doesn't depend on callback order or hiding anything:
  - Hook: one callback, registered as both pre and post, on `Charge_UpdateGroundEffects`. The test build also hooked `ReceiveTick`, but `Charge_UpdateGroundEffects` always handled the effect first, so that hook was removed.
  - Which effect it acts on: only an effect whose address differs from both its address at frame start (read in the EngineTick loop) and the last effect it handled. That means an effect the Blueprint spawned this frame, seen by a callback that ran after the Blueprint body.
  - Time scale:
    - Above 30 FPS, the first effect of a charge, and then one every 1/30 s, gets `CustomTimeDilation` (1/30)/dt, so its only tick emits like a 30 FPS frame.
    - The effects in between get 1e-3, so they emit nothing. 0 is avoided in case the engine divides by the scaled dt.
    - The first callback of the next frame resets them to 1. The EngineTick loop also resets them if callbacks stop.
  - The Blueprint still respawns every frame, as in the unmodified game.
  - Probe `charge` lines report `dustSpawns`, `dustRate` (≈ FPS either way), `dustEmitRate` (effects with dilation ≥ 0.5 per grounded second: ≈ FPS unfixed, ≈ 30 fixed) and `dustDilationMax` (≈ 4.8 at 144 when fixed).
  - **Verified 2026-09-14 20:25–20:30** (trace `trace_20260914_202538.csv` in the game dir):
    - The dust shows at 144 FPS. `CustomTimeDilation` does scale the particle tick.
    - All 35 charges were at 144 FPS: `dustRate` 142.6–144/s, `dustEmitRate` 27.4–32.4/s (29.3–30.7 for charges > 1 s), `dustDilationMax` 4.80. No errors in `UE4SS.log`.
    - A temporary debug build counted callbacks: 144 `pre` calls/s per hook, 0 post calls, and every `pre` call already saw the new effect while charging. That debug logging was then removed.
    - Charges with `dustSpawns=0` were fully airborne (charge jumps, mode 3, MaxWalkSpeed 358) or swimming (mode 5). The Blueprint spawns ground dust only while walking.
    - 30 FPS with this build was not part of that session's log. The fix does nothing when dt ≥ 1/30.

## UE4SS (runtime Lua modding)

- UE4SS experimental build `v3.0.1-1133-gb4cefa18` is staged in `tools/bin/ue4ss-dist/` (gitignored). `tools/Install-UE4SS.ps1` installs it (`dwmapi.dll` + `ue4ss/` in `Falcon\Binaries\Win64`) and deploys `ue4ss/Mods/*` (player-facing fixes) with `enabled.txt`. `ue4ss/DevMods/*` (the probe) is deployed only with `-Probe`; without it, a previously deployed probe has its `enabled.txt` removed (its traces stay in the game dir). Use `-ModsOnly` after editing Lua, and `-Uninstall` to remove everything. The installer sets engine version 4.19, turns on the external console, and **disables hot reload**. Ctrl+R crashed this UE4SS build twice: an access violation writing 0x24 in ntdll+0xFA7D, called from UE4SS.dll's engine-tick hook right after mods reinstall. Restart the game to pick up Lua changes. Crash dumps land in `%LOCALAPPDATA%\Falcon\Saved\Crashes\*\UE4Minidump.dmp`; read them with `build/DumpInfo/DumpInfo.exe <dmp>` (source in `tools/DumpInfo`), which prints the exception and module-relative stack values.
- Profiling: set `PROFILE = true` in `HighFpsSlidingAndJumpFix/Scripts/main.lua`. Every 10 s it logs `profile: N frames (avg frame X ms), fixes avg Y ms (Z% of frame), max, clock overhead` to `UE4SS.log`. Timing uses `GameplayStatics:GetAccurateRealTime`: UE4SS fills plain out-params into the passed table under the parameter name, e.g. `seconds.Seconds`, and `os.clock` only has 1 ms resolution. This excludes UE4SS's own hook overhead; measure that externally by comparing frame times with and without `dwmapi.dll`.
- Profile baseline (v1.0.0, 144 FPS VSync, 2026-09-13): fixes avg 0.13–0.20 ms/frame (1.9–2.8% of 6.95 ms), max 0.8–2.7 ms per 10 s window, clock overhead 0.009 ms. Suspected cause: `UEHelpers.GetPlayerController()` runs `FindAllOf("PlayerController")` on every call, creating per-frame garbage. The mod now caches the controller and gameplay statics, and reads mode and velocity once per frame. After caching: running/jumping windows 0.017–0.059 ms avg, but standing still 0.107–0.113 ms, because the braking path still called GetCurrentAcceleration/IsPlayingRootMotion/K2_GetActorLocation at zero velocity. It now exits early at zero velocity. **Result (22:15 session):** 0.019–0.026 ms avg in every window, including standing still (~0.35% of a 144 FPS frame). Max per window 0.5–2.1 ms even at idle, when the tick does almost nothing, so the spikes aren't the fix logic. Jumps still +84.68. Jump apex (+84.68) and stops (≤0.17 s) were unchanged by the caching refactor. Max per window stays 0.2–3 ms, likely Lua GC or thread preemption inside the timed region.
- `GetAccurateRealTime` out-params: the first profiling attempt found `PartialSeconds` missing from its own table, so `accurateSeconds` accepts either field from either table and logs both tables if one is still missing.
- `RegisterHook` on a **Blueprint** function in this build calls only the first (pre) callback, and it runs **after** the function body; the post callback never fires (measured on `BP_CPS1999_Playable_C:Charge_UpdateGroundEffects` and `:ReceiveTick`, 2026-09-14). A hook can't act before a Blueprint function runs or change its inputs. Register the same callback as pre and post, and make it idempotent.
- UE4SS Lua is 5.4, so `math.frexp`, `math.pow` and friends don't exist. A Lua error inside a per-frame loop only logs once (the mods guard with `errorLogged`), so check `UE4SS.log` for `error:` lines before trusting a test.
- Probe `drift` lines of ~0.15–0.2 s are normal stops: braking from full speed takes ~0.17 s. Multi-second drifts are the bug.
- The first AOB scan fails because the exe is still unpacking; the second pass succeeds (EngineTick hook found). Log: `Falcon\Binaries\Win64\ue4ss\UE4SS.log`.
- `ue4ss/DevMods/SpyroFpsProbe` (deploy with `Install-UE4SS.ps1 -ModsOnly -Probe`): F5/F6/F7/F8 set `t.MaxFPS` to 30/60/120/0. On load it restores `MaxSimulationTimeStep` to 0.05 if an old build changed it. It prints a `seg` summary per airborne segment and a `drift` line for grounded sliding without input. Per-frame CSV goes to `ue4ss\Mods\SpyroFpsProbe\trace_*.csv` in the game dir.

## Repo layout

- `tools/Config.ps1` — shared paths (`$GameDir`, overridable with `$env:SPYRO_GAME_DIR`; `$RepoRoot`; `$BuildDir`)
- `ue4ss/Mods/HighFpsSlidingAndJumpFix` — the shipped fixes (released: braking slide + jump height; unreleased: charge dust), a UE4SS Lua mod published as "High FPS Sliding and Jump Fix" (`VERSION` constant in `main.lua`; player-facing `README.txt` ships in the mod folder)
- `tools/Package-Release.ps1` — builds the Nexus zip `build/release/HighFpsSlidingAndJumpFix-<VERSION>.zip`, laid out relative to the game root (`Falcon/Binaries/Win64/ue4ss/Mods/HighFpsSlidingAndJumpFix/` + `enabled.txt`, forward-slash entries, UE4SS not included). Needs a UE4SS experimental build: `LoopInGameThreadAfterFrames` was added Dec 2025 and isn't in stable v3.0.1.
- `ue4ss/DevMods/SpyroFpsProbe` — per-frame movement logger for investigating framerate bugs
- `tools/Install-UE4SS.ps1 [-ModsOnly] [-Probe] [-Uninstall]` — installs UE4SS and the Lua mods
- `tools/Compare-Segments.ps1 -Trace <csv> -Segments <ids>` — side-by-side stats for probe airborne segments
- `tools/DumpInfo/` — minidump reader for game crash dumps (build: `dotnet build tools/DumpInfo -c Release -o build/DumpInfo`)
- `tools/AssetDump/` — C# (.NET 9) reader for cooked UE 4.19 `.uasset`/`.uexp`. It prints imports, exports, tagged properties (including DataTable rows) and, with `--code`, disassembled Blueprint bytecode. Build: `dotnet build tools/AssetDump -c Release -o build/AssetDump`. Run: `build/AssetDump/AssetDump.exe <file.uasset> [--export <name>] [--no-props] [--code] [--hex]`. Cooked function exports have no object-GUID flag, and `UStruct::Children` is serialized as an array.
- `build/` — generated output (gitignored)

## Tooling

- Scripts are PowerShell. Python is not installed (the `python` on PATH is only the Microsoft Store stub).
- There is no pak build pipeline. The unused one (`tools/Build-Mod.ps1` with `mods/<ModName>/`, packing with [repak](https://github.com/trumank/repak) `--version V4 --mount-point ../../../`) was removed; restore it from commit 50c1467 if a fix ever needs an asset or config pak.
- Editing `.uasset`/`.uexp`: use UAssetGUI or FModel with the engine version set to **UE4.19**. Changed assets must stay in the cooked format; replacing a `.uasset` also means shipping its matching `.uexp` (and `.ubulk` if one exists).
