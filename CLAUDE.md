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
  - Fix in `SpyroFpsFixes`: track the zero-gravity rise and, when the engine restores gravity, compute the 30 FPS rise: timeout → (ceil(H·30) + lag)/30, release → ceil((rise − dt/2)·30)/30. Keep `GravityScale = 0` until then, then fold the sub-frame leftover into Z velocity (vz'² = vz² + 2·g·vz·leftover) so the apex matches exactly. A replay over recorded traces showed no extension at 30 FPS and +3 frames for 144 FPS full holds. **Verified in game (2026-09-13 21:23):** full-hold standing jump apex was +84.68 at 144 FPS with the fix (×3), +84.64 at 30 FPS, and +79.74 at 144 FPS without it. Charge jump apex was +74.58 at 144 FPS with the fix vs +74.50 at 30 FPS, and 68.7–70.4 without it. The fix made no changes at 30 FPS.
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
- Fix: `ue4ss/Mods/SpyroFpsFixes` (always on, no toggle). While walking with zero acceleration, it tracks the unquantized braked velocity using the engine formula. It writes that value back when the engine's value differs only by quantization, and never when a real collision changed it.

## UE4SS (runtime Lua modding)

- UE4SS experimental build `v3.0.1-1133-gb4cefa18` is staged in `tools/bin/ue4ss-dist/` (gitignored). `tools/Install-UE4SS.ps1` installs it (`dwmapi.dll` + `ue4ss/` in `Falcon\Binaries\Win64`) and deploys `ue4ss/Mods/*` (player-facing fixes) with `enabled.txt`. `ue4ss/DevMods/*` (the probe) is deployed only with `-Probe`; without it, a previously deployed probe has its `enabled.txt` removed (its traces stay in the game dir). Use `-ModsOnly` after editing Lua, and `-Uninstall` to remove everything. The installer sets engine version 4.19, turns on the external console, and **disables hot reload**. Ctrl+R crashed this UE4SS build twice: an access violation writing 0x24 in ntdll+0xFA7D, called from UE4SS.dll's engine-tick hook right after mods reinstall. Restart the game to pick up Lua changes. Crash dumps land in `%LOCALAPPDATA%\Falcon\Saved\Crashes\*\UE4Minidump.dmp`; read them with `build/DumpInfo/DumpInfo.exe <dmp>` (source in `tools/DumpInfo`), which prints the exception and module-relative stack values.
- Profiling: set `PROFILE = true` in `SpyroFpsFixes/Scripts/main.lua`. Every 10 s it logs `profile: N frames (avg frame X ms), fixes avg Y ms (Z% of frame), max, clock overhead` to `UE4SS.log`. Timing uses `GameplayStatics:GetAccurateRealTime`: UE4SS fills plain out-params into the passed table under the parameter name, e.g. `seconds.Seconds`, and `os.clock` only has 1 ms resolution. This excludes UE4SS's own hook overhead; measure that externally by comparing frame times with and without `dwmapi.dll`.
- UE4SS Lua is 5.4, so `math.frexp`, `math.pow` and friends don't exist. A Lua error inside a per-frame loop only logs once (the mods guard with `errorLogged`), so check `UE4SS.log` for `error:` lines before trusting a test.
- Probe `drift` lines of ~0.15–0.2 s are normal stops: braking from full speed takes ~0.17 s. Multi-second drifts are the bug.
- The first AOB scan fails because the exe is still unpacking; the second pass succeeds (EngineTick hook found). Log: `Falcon\Binaries\Win64\ue4ss\UE4SS.log`.
- `ue4ss/DevMods/SpyroFpsProbe` (deploy with `Install-UE4SS.ps1 -ModsOnly -Probe`): F5/F6/F7/F8 set `t.MaxFPS` to 30/60/120/0. On load it restores `MaxSimulationTimeStep` to 0.05 if an old build changed it. It prints a `seg` summary per airborne segment and a `drift` line for grounded sliding without input. Per-frame CSV goes to `ue4ss\Mods\SpyroFpsProbe\trace_*.csv` in the game dir.

## Repo layout

- `mods/<ModName>/` — files laid out as they appear under the game root (mount point `../../../`), e.g. `mods/FpsFixes/Falcon/Config/DefaultEngine.ini`. Start from a copy of the retail file in `chunk0`/`chunk1`/`chunk2`, converting the path for chunk1/chunk2 by prefixing `Falcon/`.
- `tools/Config.ps1` — shared paths and pak settings
- `tools/Build-Mod.ps1 -Name <ModName> [-Install]` — packs into `build/<ModName>_P.pak` and optionally copies it to `~mods`
- `tools/Uninstall-Mod.ps1 -Name <ModName>` — removes the installed pak
- `ue4ss/Mods/SpyroFpsFixes` — the shipped fixes (braking slide + jump height), a UE4SS Lua mod (`VERSION` constant in `main.lua`; player-facing `README.txt` ships in the mod folder)
- `tools/Package-Release.ps1` — builds the Nexus zip `build/release/SpyroFpsFixes-<VERSION>.zip`, laid out relative to the game root (`Falcon/Binaries/Win64/ue4ss/Mods/SpyroFpsFixes/` + `enabled.txt`, forward-slash entries, UE4SS not included). Needs a UE4SS experimental build: `LoopInGameThreadAfterFrames` was added Dec 2025 and isn't in stable v3.0.1.
- `ue4ss/DevMods/SpyroFpsProbe` — per-frame movement logger for investigating framerate bugs
- `tools/Install-UE4SS.ps1 [-ModsOnly] [-Probe] [-Uninstall]` — installs UE4SS and the Lua mods
- `tools/Compare-Segments.ps1 -Trace <csv> -Segments <ids>` — side-by-side stats for probe airborne segments
- `tools/DumpInfo/` — minidump reader for game crash dumps (build: `dotnet build tools/DumpInfo -c Release -o build/DumpInfo`)
- `tools/AssetDump/` — C# (.NET 9) reader for cooked UE 4.19 `.uasset`/`.uexp`. It prints imports, exports, tagged properties (including DataTable rows) and, with `--code`, disassembled Blueprint bytecode. Build: `dotnet build tools/AssetDump -c Release -o build/AssetDump`. Run: `build/AssetDump/AssetDump.exe <file.uasset> [--export <name>] [--no-props] [--code] [--hex]`. Cooked function exports have no object-GUID flag, and `UStruct::Children` is serialized as an array.
- `build/` — generated output (gitignored)

## Tooling

- Scripts are PowerShell. Python is not installed (the `python` on PATH is only the Microsoft Store stub).
- Packing needs [repak](https://github.com/trumank/repak) in `tools/bin/repak.exe` or on PATH. Pack with `--version V4 --mount-point ../../../`.
- Editing `.uasset`/`.uexp`: use UAssetGUI or FModel with the engine version set to **UE4.19**. Changed assets must stay in the cooked format; replacing a `.uasset` also means shipping its matching `.uexp` (and `.ubulk` if one exists).
