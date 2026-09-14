# SpyroFpsFixes

Mods for Spyro Reignited Trilogy (Unreal Engine 4.19).

## Framerate fixes (UE4SS)

`ue4ss\Mods\SpyroFpsFixes` fixes two bugs that appear when the game runs above 30 FPS:

- **Sliding:** above ~80 FPS Spyro keeps sliding slowly after stopping. Braking is lost to float rounding far from the world origin.
- **Jump height:** jumps (ground, water, charge) peak ~5 units lower than at 30 FPS because the no-gravity window is rounded to frame boundaries. Jumps now rise exactly as they do at 30 FPS.

Install:

1. Extract a [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS/releases) release (tested with experimental `v3.0.1-1133-gb4cefa18`) into `tools\bin\ue4ss-dist\`, so that `dwmapi.dll` sits directly in that folder.
2. Run:

```powershell
.\tools\Install-UE4SS.ps1
```

After editing a Lua mod, run `.\tools\Install-UE4SS.ps1 -ModsOnly` and restart the game. Hot reload (Ctrl+R) is disabled because it can crash the game. To also deploy the movement logger used for investigating these bugs, add `-Probe`. `-Uninstall` removes UE4SS from the game.

To build the release zip for Nexus Mods (version taken from `VERSION` in `main.lua`):

```powershell
.\tools\Package-Release.ps1
```

This writes `build\release\SpyroFpsFixes-<version>.zip`, which players extract into the game folder. UE4SS is not included and has to be installed separately (an experimental build is required).

## Pak mods

### Setup

1. Download [repak](https://github.com/trumank/repak/releases) and put `repak.exe` in `tools\bin\` (or on PATH).
2. If the game is not in the default Steam folder, set `$env:SPYRO_GAME_DIR` to the game root.

### Making a pak mod

Put files in `mods\<ModName>\` using the same paths they have in the game, starting from `Falcon\` or `Engine\`:

```
mods\FpsFixes\Falcon\Config\DefaultEngine.ini
```

Build and install:

```powershell
.\tools\Build-Mod.ps1 -Name FpsFixes -Install
```

This creates `build\FpsFixes_P.pak` and copies it to `Falcon\Content\Paks\~mods\`.

Uninstall:

```powershell
.\tools\Uninstall-Mod.ps1 -Name FpsFixes
```
