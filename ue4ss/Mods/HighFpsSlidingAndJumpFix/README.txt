High FPS Gameplay Fixes
=======================

Spyro Reignited Trilogy was made for 30 FPS. At higher framerates Spyro jumps lower, slides around,
charges and steers differently, and some things in the levels stop working. This mod makes the game
play the same at any framerate as it does at 30 FPS.

The mod changes nothing at 30 FPS.

Fixes (numbers were recorded in game at 30 FPS and at 144 FPS, before and after the fix)
- Sliding: above ~80 FPS Spyro keeps sliding slowly after you let go of the stick.
    Before: slides for seconds, or until something stops him.  After: stops in 0.1-0.2 seconds, as at 30 FPS.
- Jump height: jumps and glide-end hovers don't go as high, so some ledges and glides are out of reach.
    Full jump:    30 FPS 84.6   |  144 FPS before 79.7   |  after 84.7
    Charge jump:  30 FPS 74.5   |  144 FPS before 68.7-70.4  |  after 74.6
    Glide hover:  30 FPS 48.9   |  144 FPS before 42.5   |  after 49.0
- Speeding up: Spyro gains speed unevenly, faster in some directions and slower in others.
    Speed gained per second:  30 FPS 1000  |  144 FPS before about 650 or 1300  |  after 1000
    Charge from a standstill to speed 400:  30 FPS 0.40 s  |  144 FPS after 0.40 s
- Charge turning: Spyro's path swings wider in a charge turn than at 30 FPS.
    How far his path lags behind where he faces:  30 FPS 9.4 deg  |  144 FPS before 12.1-12.5 deg  |  after 9.4-9.5 deg
- Mouse charge steering: moving the mouse at the same speed turns a charging Spyro much less.
    Mouse moved about 50 units per second:  30 FPS 181 deg/s  |  144 FPS before about 42 deg/s (calculated)  |  after 180 deg/s
- Camera during charges: the camera falls further behind Spyro in charge turns.
    Camera angle behind Spyro in a full turn:  30 FPS 33.0 deg  |  144 FPS before 36.5 deg  |  after 33.0 deg
- Charge dust: the dust cloud behind a charge doesn't appear at all at 60 FPS or more.
    Dust bursts per second:  30 FPS 30  |  144 FPS before 0  |  after 29-31
- Wizards (Alpine Ridge): the wizards stop moving their stairs, doors and walkways, after one spell at most.
    Spells that moved something:  30 FPS all  |  144 FPS before at most the first, then only the odd lucky one  |  after all (78 of 78)
- Fire dragons (Fireworks Factory): the dragons' body sections bunch up behind the head, which makes them
  much harder to hit.
    Average gap between body sections:  30 FPS 58-64  |  144 FPS before 13  |  after 58-60

Requirements
- UE4SS experimental build (https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/experimental-latest).
  Tested with v3.0.1-1133-gb4cefa18. The stable v3.0.1 release is too old and will not run this mod.

Install
1. Install UE4SS into  Spyro Reignited Trilogy\Falcon\Binaries\Win64
2. Extract this zip into the game folder  Spyro Reignited Trilogy\
   The mod ends up in  Falcon\Binaries\Win64\ue4ss\Mods\HighFpsSlidingAndJumpFix
   (the folder keeps the mod's original name, so a new version replaces an older one)
3. Start the game. Falcon\Binaries\Win64\ue4ss\UE4SS.log should contain "[HighFpsSlidingAndJumpFix] v... loaded".

Notes
- Restart the game after changing mods. UE4SS hot reload (Ctrl+R) can crash this game.
- Short hops: tapping jump is matched to 30 FPS too, so a short hop can stay in the air up to 1/30 s longer.
- After a charge turn the camera swings back behind Spyro 5-8% faster than at 30 FPS
  (it matches 30 FPS exactly while turning).
- Swimming and flying speed-up are not adjusted.
- The wizard fix also applies to the same wizard spell in the other Magic Crafters levels, but was only
  tested in Alpine Ridge.

Uninstall
- Delete the Falcon\Binaries\Win64\ue4ss\Mods\HighFpsSlidingAndJumpFix folder.
