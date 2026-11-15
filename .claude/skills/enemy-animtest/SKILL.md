---
name: enemy-animtest
description: Put Spyro in the probe's blank test room, spawn one enemy (or NPC) there and compare every one of its animations at 30 and 320 FPS. Use when asked to test, check or compare a character's animations across framerates, to re-measure a montage the tour or the montage sweep flagged, or to "spawn X and run its animations".
argument-hint: <enemy name or class path> [montage filter]
---

# Enemy animation test in the blank room

One command does the whole thing. It needs the game installed and the probe (`ue4ss/DevMods/SpyroFpsProbe`); it starts the game itself.

```powershell
.\tools\Test-EnemyAnims.ps1 -Enemy <name>            # 30 then 320 FPS
.\tools\Test-EnemyAnims.ps1 -Enemy <name> -Montage Attack -Caps 30,320,160 -Level LS101
```

Run it in the background with a long timeout (a character with 40 montages takes about 3 minutes; starting the game adds 2). It takes the game window and the framerate cap while it runs, so say so before starting if the user may be playing.

What it does, in order:

1. **Game and scripts.** If the game is not running it deploys the probe and starts the game back into the level noted in the probe's `resume.txt` (`tools/Restart-Game.ps1`). If the game *is* running with probe scripts older than the repo it stops with an error: deploying into a running game can crash it. Pass `-Restart` only when the user is fine with the game being closed.
2. **Blank test area.** `tools/testroom.lua` spawns an 8000 x 8000 floor (the engine cube, scaled) in clear sky above where Spyro stands, at his own X and Y, and teleports him onto it. The game ships no empty map, so this is the blank area: no slopes, walls, water, triggers or other characters.
3. **Spawn.** The enemy is spawned in the middle of the floor, 600 units in front of Spyro, facing him, with its AI controller.
4. **Animations.** `tools/animtest.lua` (`spawn=` option) plays every montage loaded for the enemy's skeleton at each cap in turn, each from the same spot, with the enemy's AI ticks off and its mesh forced to tick every frame. Per montage and cap it records duration, root-motion distance, and the particle and audio components its notifies made.
5. **Clean up.** The enemy and the floor are destroyed and Spyro goes back where he was.
6. **Compare.** This run's rows go to `build\animtest\<stamp>_<enemy>\animtest.csv`, and `Compare-Animtest.ps1` writes `compare.txt` next to it.

## Naming the enemy

- A class in `ue4ss/DevMods/SpyroFpsProbe/Scripts/tools/spawnlist.lua` (185 chase/flee characters), by class name (`BP_CES1015_Ram_C`, `CES1015_Ram`) or by any fragment that matches exactly one entry (`Cowlek`). An ambiguous fragment is refused and the log lists the candidates. Grep the list first.
- Anything else by full class path: `/<Plugin>/<path under Content>/<Asset>.<Asset>_C`. Find the Blueprint under the unpacked `chunk*\...\Plugins\<Plugin>\Content\` (see CLAUDE.md for the mount points); `chunk1\Plugins\Characters\CES1035_GreenDruid\Content\Blueprints\BP_CES1035_GreenDruid.uasset` is `/CES1035_GreenDruid/Blueprints/BP_CES1035_GreenDruid.BP_CES1035_GreenDruid_C`.
- Three classes crash the game when spawned out of their setup (`SKIP` in `tools/spawntest.lua`: both skate-race crabs and `BP_CES3361_HoverCannonRhynoc_C`). Do not spawn those; measure them in their own level with `animtest.txt` holding `here class=<name>`.

## Reading the result

Read `compare.txt`, not the log. Each row is one montage at a non-baseline cap against the 30 FPS pass; `Flags` is empty when they agree.

- `duration`: one pass took more than 0.05 s longer or shorter. `move`: root motion differs by more than 2 units. `fx` / `audio`: the notifies made a different number of components. `result`: it played at one cap and stuck, looped or was cut short at the other.
- **A flag means "measure it again", not "a bug".** Re-run just that montage (`-Montage <name>`), two or three times. A real difference repeats with the same sign and size; both false positives so far (`docs/findings/animations.md`) did not survive that.
- **Particle (`fx`) counts are unsteady even at one framerate.** The Cowlek's montages made 1 to 4 components at the same cap from one run to the next (2026-11-14), so an `fx` flag from one run means nothing. Run the test three times (it takes about 20 s once the game is up) and count a difference only when it holds in every run, in the same direction.
- `cut short` at both caps is the enemy's own state machine playing over the montage, not a framerate effect. `sub-frame loop` is a loop shorter than one 30 FPS frame and is not timed.
- Check `avgFps` in `animtest.csv` for the 320 rows: if the game did not reach about 300 the pass did not test what it claims. The probe's own trackers and `TRACE` in its `config.lua` cost frame time.
- On a skeleton shared with other characters (most rhynocs) the enemy is also given the shared montages that happen to be loaded; the `path` column says whose folder each one comes from.
- Only montages are played. What the enemy does in its AnimGraph (locomotion blends) and anything only real gameplay starts is the world tour's job (`tools/Tour-Unattended.ps1`).

If the run fails, the script says why from the log: `spawn=...` (name not resolved), `could not spawn` (class did not load), `the test room's floor did not hold Spyro`, `0 montages` (nothing loaded for that skeleton), or the game went away (read the newest crash dump with `build/DumpInfo/DumpInfo.exe`).

## Afterwards

Put what was measured in `docs/findings/animations.md` (the enemy, the date, montage count, and any flag that survived a re-run with its numbers). A difference that repeats is a new finding: follow CLAUDE.md's fix recipe from there.
