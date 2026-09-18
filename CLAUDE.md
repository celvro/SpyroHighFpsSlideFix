# SpyroFpsFixes

Mods for **Spyro Reignited Trilogy** (PC/Steam), built on **Unreal Engine 4.19**. Internal project name is `Falcon`. The shipped mod is a UE4SS Lua mod fixing high-framerate gameplay bugs.

**Target behaviour: every framerate must match 30 FPS** (the console tuning). Some glide distances are impossible otherwise, so a fix that makes 30 FPS behave like high FPS is wrong.

## Findings docs (read the relevant one before working on a fix)

Investigation logs live in `docs/`; each fix module in `ue4ss/Mods/HighFpsSlidingAndJumpFix/Scripts/fixes/` is also headed by a summary of its cause. **Add new measurements and conclusions to the matching doc (or a new one listed here), not to this file.**

| Doc | Topic | Status |
|---|---|---|
| `docs/findings/jump-glide.md` | Jump/hover height (zero-gravity phase rounds to frames), glide distance (position rounding), glide start wait, framerate config | fixed, verified |
| `docs/findings/sliding-walking.md` | Braking slide, acceleration lanes, stuck from standstill (float32 position quantization far from origin) | fixed, verified |
| `docs/findings/charge-turn-camera.md` | Charge slip, mouse charge steering, camera centering, centering switch, stuck charge camera (native disassembly) | fixed, verified |
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
| `docs/ue4ss.md` | UE4SS install details, profiling history, Lua GC experiments | reference |
| `docs/tools.md` | Full packaging/Vortex/tool notes | reference |
| `docs/probe.md` | Probe mod: log lines, CSV columns, hotkeys, quicksave, level streaming | reference |

## Game install

- Game root: `C:\Program Files (x86)\Steam\steamapps\common\Spyro Reignited Trilogy`
- Executable: `Falcon\Binaries\Win64\Spyro-Win64-Shipping.exe` (launched through `Spyro.exe`)
- Paks: `Falcon\Content\Paks\pakchunk{0,1,2}-WindowsNoEditor.pak` (version 4, unencrypted index). Mod paks go in `Falcon\Content\Paks\~mods\` as `*_P.pak`.
- User config (overrides pak config): `%LOCALAPPDATA%\Falcon\Saved\Config\WindowsNoEditor\`
- UE4SS log: `Falcon\Binaries\Win64\ue4ss\UE4SS.log`. Crash dumps: `%LOCALAPPDATA%\Falcon\Saved\Crashes\*\UE4Minidump.dmp` (read with `build/DumpInfo/DumpInfo.exe <dmp>`).

## Unpacked reference content (read-only, never modify)

Unpacked into `Falcon\Content\Paks\chunk0|chunk1|chunk2`, each relative to its pak's mount point:

| Folder | Mount point        | Top-level dirs         |
|--------|--------------------|------------------------|
| chunk0 | `../../../`        | `Engine/`, `Falcon/`   |
| chunk1 | `../../../Falcon/` | `Content/`, `Plugins/` |
| chunk2 | `../../../Falcon/` | `Content/`, `Plugins/` |

So `chunk1\Plugins\Levels\...` is the game path `Falcon/Plugins/Levels/...`. Project config is in `chunk0\Falcon\Config\`. Game content is split into plugins under `Falcon/Plugins/` (`Characters`, `Levels`, `GameplayCommon`, …). Audio is Wwise.

## Rules and gotchas

- **Never poll `StaticFindObject` for something that may not exist**: a miss scans the whole object array (~10 ms). Trigger lookups from `NotifyOnNewObject` instead.
- `RegisterHook` on a **Blueprint** function (this UE4SS build) calls only the pre callback, and it runs **after** the function body; post never fires. Register the same idempotent callback as pre and post.
- UE4SS Lua is 5.4 (no `math.pow`/`math.frexp`). Per-frame errors log once (`errorLogged`), so check `UE4SS.log` for `error:` lines before trusting a test.
- Lua trap: `local a, b = x and x:match(...)` truncates to one value.
- Hot reload (Ctrl+R) occasionally crashes this UE4SS build; restart the game instead if it does.
- Never shrink `MaxSimulationTimeStep` below a frame for experiments (substeps reproduce the sliding bug at 30 FPS).
- Hotkeys: never F11 (game fullscreen toggle) or Ctrl+R (UE4SS). The game binds every number key, W/A/S/D/E/F/P/Q/X/Z, LeftControl and the arrows. The player has no numpad.
- Don't use the `RestartLevel` console command (drops to the title screen).
- `PROFILE` in `Scripts/config.lua` must be `false` in commits.
- The mod folder and `[HighFpsSlidingAndJumpFix]` log prefix keep the old name on purpose: renaming would leave older installs loaded alongside and apply every fix twice.
- Disassembly: the exe's `.text` is SteamStub-encrypted on disk. `tools/Read-GameVtables.ps1 -OutExe` writes a copy with the decrypted `.text` from the running game, then use `dumpbin /DISASM /RANGE:...` (VS 2022). Native reflection names are plain strings in the exe; `tools/Find-PropertyParams.ps1` finds property offsets.

## Repo layout

- `ue4ss/Mods/HighFpsSlidingAndJumpFix` — the shipped mod, published as "High FPS Gameplay Fixes" (`VERSION` in `main.lua`; player-facing `README.txt` in the mod folder). `Scripts/`: `config.lua` (every `FIX_*` and profiling toggle), `lib/` (log, cached engine handles, lookup/hook bookkeeping, UE 4.19 movement math), `fixes/` (one module per fix), `profiler.lua`, `main.lua` (the tick). A fix module returns `{ name, enabled, update(ctx) [, reset()] [, disable(ctx, err)] }`; `main.lua` builds `ctx` once per frame, runs fixes in order, and on error calls `disable` and drops that fix.
- `ue4ss/DevMods/SpyroFpsProbe` — per-frame logger for investigating framerate bugs (see `docs/probe.md`). `Scripts/`: `lib/` (log, the per-frame row, the trace CSV, object dumps, level streaming queries), `trackers/` (one module per measurement, each documenting its log lines), `tools/quicksave.lua` (V/B/L/N), `main.lua` (`sample()`, keys, notifications). Shared frame state (previous row, ids of the measurements in progress) is in `lib/state.lua`; everything else is local to its tracker.
- `tools/Install-UE4SS.ps1 [-ModsOnly] [-Probe] [-Uninstall]` — installs UE4SS (staged in `tools/bin/ue4ss-dist/`, gitignored) and the Lua mods. Use `-ModsOnly` after editing Lua.
- `tools/Package-Release.ps1` — release zip `build/release/HighFpsGameplayFixes-<VERSION>.zip`, game-root layout, with `vortex_override_instructions.json` (`setmodtype dinput`) so Vortex deploys to the game dir. Needs a UE4SS experimental build (`LoopInGameThreadAfterFrames`).
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
- No pak build pipeline (restore `tools/Build-Mod.ps1` + repak from commit 50c1467 if an asset or config pak is ever needed). Edit `.uasset`/`.uexp` with UAssetGUI or FModel set to UE4.19; ship the matching `.uexp`/`.ubulk`.
