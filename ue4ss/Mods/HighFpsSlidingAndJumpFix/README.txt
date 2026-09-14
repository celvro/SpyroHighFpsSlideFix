High FPS Sliding and Jump Fix
=============================

Makes Spyro Reignited Trilogy play the same above 30 FPS as it does at 30 FPS (the console tuning).

Fixes
- Sliding: above ~80 FPS Spyro keeps sliding slowly after you let go of the stick.
- Jump height: jumps (ground, water, charge) reach ~5 units lower at high framerates, which makes some
  jumps and glides impossible. Jumps now rise exactly as they do at 30 FPS.

The mod changes nothing at 30 FPS.

Requirements
- UE4SS experimental build (https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/experimental-latest).
  Tested with v3.0.1-1133-gb4cefa18. The stable v3.0.1 release is too old and will not run this mod.

Install
1. Install UE4SS into  Spyro Reignited Trilogy\Falcon\Binaries\Win64
2. Extract this zip into the game folder  Spyro Reignited Trilogy\
   The mod ends up in  Falcon\Binaries\Win64\ue4ss\Mods\HighFpsSlidingAndJumpFix
3. Start the game. Falcon\Binaries\Win64\ue4ss\UE4SS.log should contain "[HighFpsSlidingAndJumpFix] v... loaded".

Notes
- Restart the game after changing mods. UE4SS hot reload (Ctrl+R) can crash this game.

Uninstall
- Delete the Falcon\Binaries\Win64\ue4ss\Mods\HighFpsSlidingAndJumpFix folder.
