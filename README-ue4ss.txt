UE4SS for Spyro Reignited Trilogy
=================================

UE4SS is a free mod loader for Unreal Engine games. It is what runs Lua mods such as
High FPS Gameplay Fixes. On its own it changes nothing about the game.

This download is the official UE4SS build, repackaged so it extracts straight into the
Spyro Reignited Trilogy folder and is already set to the game's engine version. It is here
so you don't have to pick the right file out of the UE4SS release page.

UE4SS is not my work. It is made by the UE4SS team (Narknon and contributors) and released
under the MIT License. The full licence text is in LICENSE.txt in this zip and in
ue4ss\LICENSE after install. Source: https://github.com/UE4SS-RE/RE-UE4SS

Included build: UE4SS {{UE4SS_VERSION}} (experimental)
Downloaded from https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/experimental-latest

What is different from the official zip
- UE4SS-settings.ini has the engine version set to 4.19, the version Spyro Reignited Trilogy
  uses. Without it UE4SS has to work the version out by itself, which can fail.
- Nothing else is changed. The files are the ones UE4SS released, and the UE4SS mods that come
  with it (console, Blueprint mod loader and so on) are untouched.

Install
1. In Steam, right-click Spyro Reignited Trilogy -> Manage -> Browse local files. Usually:
     C:\Program Files (x86)\Steam\steamapps\common\Spyro Reignited Trilogy
2. Extract this zip into that game folder (not into Win64). The zip already contains the right
   folders, so afterwards you have:
     Spyro Reignited Trilogy\Falcon\Binaries\Win64\dwmapi.dll   (next to Spyro-Win64-Shipping.exe)
     Spyro Reignited Trilogy\Falcon\Binaries\Win64\ue4ss\
   If Windows asks whether to merge folders, choose Yes.
3. Linux, Steam Deck and Proton only: add  WINEDLLOVERRIDES="dwmapi.dll=n,b"  to the game's
   Steam launch options.
4. Start the game. Nothing appears on screen; that is normal. Check that this file now exists:
     Spyro Reignited Trilogy\Falcon\Binaries\Win64\ue4ss\UE4SS.log

Installing mods
- Lua mods: each one is a folder under  Falcon\Binaries\Win64\ue4ss\Mods\  containing
  Scripts\main.lua and an empty file named enabled.txt. Most mod zips already have that layout,
  so you extract them into the game folder like this one.
- Restart the game after adding or changing mods. UE4SS's hot reload (Ctrl+R) can crash Spyro.
- More on UE4SS itself: https://docs.ue4ss.com

Troubleshooting
- No UE4SS.log appears: dwmapi.dll has to sit directly next to Spyro-Win64-Shipping.exe, not in
  the ue4ss folder. Some antivirus programs quarantine it, so check your antivirus history and
  restore it if needed.
- Want to see the UE4SS log window while you play? Set  ConsoleEnabled = 1  in
  Falcon\Binaries\Win64\ue4ss\UE4SS-settings.ini
- A mod says it needs a newer UE4SS than the stable v3.0.1 release: this is that newer build.

Uninstall
- Delete  dwmapi.dll  and the  ue4ss  folder from  Falcon\Binaries\Win64
  (UE4SS.log lives in the ue4ss folder and goes with it).

Credits and licence
- UE4SS: the UE4SS team, https://github.com/UE4SS-RE/RE-UE4SS - MIT License,
  Copyright (c) 2022 Narknon. See LICENSE.txt.
- This repackaging: celvro. Packaging scripts and notes:
  https://github.com/celvro/SpyroHighFpsSlideFix
