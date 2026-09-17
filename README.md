# High FPS Gameplay Fixes for Spyro Reignited Trilogy

Spyro Reignited Trilogy was tuned for 30 FPS. At higher framerates Spyro handles differently, and some jumps and glides become impossible. This mod makes the game play the same at any framerate as it does at 30 FPS.

**What it fixes**

- **Sliding:** above ~80 FPS, Spyro keeps sliding slowly after you let go of the stick.
- **Jump height:** ground, water and charge jumps peak about 5 units lower than at 30 FPS, and glide-end hovers about 6 lower. That's enough to miss ledges and shorten glides. Jumps now reach exactly the same height as at 30 FPS.
- **Speeding up:** Spyro gains speed unevenly (about 650 or 1300 per second instead of 1000, depending on direction).
- **Charge turning:** Spyro's path swings wider in charge turns (12.1–12.5° behind his facing instead of 9.4°).
- **Mouse charge steering:** the same mouse movement turns a charging Spyro far less.
- **Camera during charges:** the camera trails further behind in charge turns (36.5° instead of 33.0°).
- **Camera lock in charges:** if a charge starts with the camera a little to one side and Spyro turns away from it, the camera can get stuck swinging slowly beside him instead of locking on behind him. The game does this at any framerate, but at high framerates a much smaller angle is enough (12° gets stuck at 144 FPS but not at 30). Fixed at every framerate.
- **Charge dust:** the dust cloud behind a charge disappears at 60 FPS and above.
- **Alpine Ridge wizards:** the wizards stop moving their stairs, doors and walkways.
- **Fireworks Factory dragons:** the segments are much too short, making them extremely hard to hit.
- **Flame breath:** long stray flame streaks stick out of Spyro's flame, pointing up or sideways.
- **Freed dragons (Spyro 1):** after you touch a dragon statue, Spyro's walk up to his spot in front of the dragon starts late and crawls at very high framerates (~500 FPS), so he only gets there near the end of the dragon's animation.

`ue4ss/Mods/HighFpsSlidingAndJumpFix/README.txt` and `nexus-description.bbcode` list the recorded before/after numbers for each fix.

At 30 FPS the mod changes nothing, except the camera lock fix, which fixes a bug the game also has at 30 FPS.

## Requirements

- Spyro Reignited Trilogy on **Steam** (the only version tested).
- **UE4SS experimental build**, a free mod loader. Tested with `v3.0.1-1133-gb4cefa18`. The older "stable" UE4SS v3.0.1 release does **not** work with this mod.

## Installation

### 1. Find the game folder

In Steam, right-click **Spyro Reignited Trilogy** → **Manage** → **Browse local files**. This opens the game folder, usually:

```
C:\Program Files (x86)\Steam\steamapps\common\Spyro Reignited Trilogy
```

### 2. Install UE4SS

1. Go to the [UE4SS experimental release](https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/experimental-latest) and download the file named `UE4SS_v3.0.1-....zip`. Don't download the ones starting with `zDEV` or `zCustomGameConfigs`.
2. Open `Spyro Reignited Trilogy\Falcon\Binaries\Win64` (the folder with `Spyro-Win64-Shipping.exe`).
3. Extract the UE4SS zip into that folder. Afterwards it should contain:

```
Win64\
├── dwmapi.dll                  ← must be next to the .exe
├── Spyro-Win64-Shipping.exe
└── ue4ss\
    ├── UE4SS.dll
    ├── UE4SS-settings.ini
    └── Mods\
```

### 3. Install the mod

1. Download `HighFpsGameplayFixes-<version>.zip` from the [Releases page](../../releases/latest). Versions up to 1.2.1 were named `HighFpsSlidingAndJumpFix-<version>.zip`.
2. Extract it into the **game folder** (`Spyro Reignited Trilogy`), not into `Win64`. The zip already contains the `Falcon\Binaries\Win64\...` folders, so the mod lands in the folder below. It keeps the mod's original name, so a new version replaces an older one:

```
Spyro Reignited Trilogy\Falcon\Binaries\Win64\ue4ss\Mods\HighFpsSlidingAndJumpFix\
├── enabled.txt
├── README.txt
└── Scripts\
    └── main.lua
```

If Windows asks whether to merge folders, choose **Yes**.

### 4. Check that it works

Start the game. No window or message appears in game; that's normal. Open this file in Notepad:

```
Spyro Reignited Trilogy\Falcon\Binaries\Win64\ue4ss\UE4SS.log
```

Near the end you should see:

```
[HighFpsSlidingAndJumpFix] v1.4.0 loaded
```

## Troubleshooting

- **There's no `UE4SS.log`:** UE4SS isn't loading. Make sure `dwmapi.dll` is directly in the `Win64` folder, next to `Spyro-Win64-Shipping.exe`. Some antivirus programs quarantine this file; check your antivirus history and restore it if needed.
- **The log exists but has no `[HighFpsSlidingAndJumpFix] ... loaded` line:** check the mod's folder layout matches step 3, including `enabled.txt`.
- **The log shows `EngineTick hook unavailable` or a Lua `error`:** you're probably on the old stable UE4SS. Install the experimental build from step 2.
- **The game crashed after pressing Ctrl+R:** that's UE4SS's mod reload, which can crash this game. Don't use it; restart the game instead.
- **Want the UE4SS log window visible?** Set `ConsoleEnabled = 1` in `Win64\ue4ss\UE4SS-settings.ini`.

## Uninstall

- **Remove this mod:** delete the `Falcon\Binaries\Win64\ue4ss\Mods\HighFpsSlidingAndJumpFix` folder.
- **Remove UE4SS entirely:** also delete `dwmapi.dll` and the `ue4ss` folder from `Falcon\Binaries\Win64`.

## Development

The rest of this repository contains the tools used to find and fix these bugs. `CLAUDE.md` has the research notes.

- `ue4ss/Mods/HighFpsSlidingAndJumpFix`: the mod. `VERSION` in `main.lua` sets the release version; `PROFILE = true` logs its per-frame cost.
- `ue4ss/DevMods/SpyroFpsProbe`: per-frame movement logger used to measure the bugs.
- `tools/`: installer, release packager, asset/Blueprint dumper, trace comparison, crash dump reader.

Install UE4SS and the mods into your game from the repo:

1. Extract a UE4SS experimental release into `tools\bin\ue4ss-dist\` (so `dwmapi.dll` is directly in that folder).
2. If the game isn't in the default Steam folder, set `$env:SPYRO_GAME_DIR` to the game root.
3. Run:

```powershell
.\tools\Install-UE4SS.ps1
```

After editing the mod, run `.\tools\Install-UE4SS.ps1 -ModsOnly` and restart the game. Add `-Probe` to also deploy the movement logger. `-Uninstall` removes UE4SS from the game.

Build the release zip (named from `VERSION` in `main.lua`):

```powershell
.\tools\Package-Release.ps1
```

This writes `build\release\HighFpsGameplayFixes-<version>.zip` for the GitHub release. The mod folder inside stays `HighFpsSlidingAndJumpFix` so updates overwrite older installs.

Build the UE4SS bundle (a separate download: UE4SS itself, repackaged for this game and preset to engine version 4.19):

```powershell
.\tools\Package-UE4SS-Release.ps1
```

This writes `build\release\UE4SS-for-Spyro-<ue4ss version>.zip` from `tools\bin\ue4ss-dist\`, plus a filled-in copy of `nexus-description-ue4ss.bbcode`. UE4SS is MIT licensed, so the zip ships its `LICENSE` (in place and as `LICENSE.txt`) together with `README-ue4ss.txt` (packaged as `README.txt`), which credits the UE4SS team and lists the one change made to the release (the engine version).

## License

[MIT](LICENSE)
