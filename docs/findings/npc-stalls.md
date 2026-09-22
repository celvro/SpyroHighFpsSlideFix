# NPC and enemy stalls from rest (all characters)

Question (2026-09-19): do other characters have the rounding bug that stopped Spyro (`sliding-walking.md`), Buzz (`buzz-charge-run.md`) and Sheila (`sheila-buzz-walk.md`) from moving?

## Mechanism and threshold

- Every level streams onto the 300,000 grid (`docs/probe.md`), so at least one horizontal axis of every level is on the 1/32 position grid. Z and an axis at 0 have fine spacing.
- In Walking, NavWalking, Flying and Swimming, UE 4.19 resets `Velocity = displacement / dt` after the move, unless anim root motion drives it. A character that builds speed from rest through acceleration moves `MaxAcceleration·dt²·|heading component|` on its first frame. When that's under half a step (1/64) on both axes, the move rounds to 0 and velocity resets to 0 every frame. After a hitch it moves one step per frame and locks near (1/32)/dt (Buzz crawled at ~16/s), because each frame's gain a·dt² still rounds away.
- It stalls from rest above **fps ≈ √(64·a) with an axis-aligned heading and ≈ √(45·a) on a diagonal**:

| MaxAcceleration | stalls above |
|---|---|
| 25 | 34–40 FPS |
| 100 | 67–80 |
| 400–512 | 134–181 |
| 650–800 | 171–226 |
| 1000–1200 | 212–277 |
| 2048 (default) | 304–362 |
| 3000–5000 | 367–566 |

- Exempt: velocity set directly (`bRequestedMoveUseAcceleration` false, only `BP_CES1062_HauntedTinSoldier`), anim root motion, car movement once Buzz's fix covers it, and possibly Phasmid custom movement (mode 6, the thieves' flee), which is untested.

## Static survey (2026-09-19)

Every asset that references a `CharacterMovementComponent` was dumped with AssetDump (1,367 files, 1,141 Blueprint classes), and each class was resolved through its parent chain. For each class the survey takes the movement component overrides and the `FalconEnemyStateComponent` states' `EFalconMovementMode`. Result: `build/npc_movement_survey.csv`, gitignored. Regenerate it by dumping and resolving again (the script was a one-off).

- 735 classes derive from `PhasmidCharacter` (NPCs and enemies). 594 have at least one state that moves them (TraverseWaypointsOnce 398, SeekPlayer 154, TraverseWaypointsLooped 112, Wander 78, FleeFromPlayer 52, ReturnToOrigin(WithoutFacing) 70, ReverseTraverseWaypoints(Looped) 22). The rest only FacePlayer/None.
- Of the 594, 550 keep the default MaxAcceleration 2048: from rest they stall only above ~300–360 FPS, which is the uncapped range. Land modes: NavWalking 265, unset (native default) 241, Flying 57, Walking 24.
- 1 of 556 anim Blueprints sets `RootMotionFromEverything` and 1 `IgnoreRootMotion`; the rest use the default `RootMotionFromMontagesOnly`. So locomotion is physics-driven, and only montages (attacks, special moves) carry root motion.
- Low MaxAcceleration, stalling at lower framerates if they accelerate from rest:
  - 25: `BP_LS207_Fish_C` (Aquaria Towers, Wander).
  - 100: `BP_CFS3339_DivingDuck(_Swimmer)_C` (Flee, Wander, waypoints).
  - 400: `BP_CES3023_Octopus_C`, `BP_CES3024_SwimmingRhynoc(_Tube)_C` (Flying, waypoints).
  - 500: `BP_CBS2002_Gulp_C` (boss, Walking, SeekPlayer), `CNS2133B_MrBones_C`.
  - 512: `BP_CES1015_Ram_C`, `BP_CES2047_YoungEarthshaper_C`, `BP_CES2019_WaterWorker_B_C`.
  - 650: Hunter NPCs `BP_CNS3706_Hunter*`, `BP_CNS3707_HunterSkater*` (waypoints).
  - 680: Coward Rhynocs, Rhynoc Spearmen, Hockey Rhynoc.
  - 780–900: `BP_CES3035_CatHockeyRhynoc_C`, `BP_CBS1000_Toasty_C` (boss, 800), `BP_CES3062_CatWitch_C`.
  - 1000–1200: Goon, Flying Gecko, Mosquito, sheep fodder (1200, Flee/Wander).
  - `BP_207Seahorse_C` has 0.
- Unknown from assets: how the native Falcon state modes move a character. Sheila's SeekPlayer requests a velocity through `RequestedVelocity`, accelerating at MaxAcceleration, so it's affected. TraverseWaypoints (Phasmid spline movement, `DefaultSplineTraversalMode`), Wander, Flee and ReturnToOrigin haven't been observed at high FPS. The thief was measured at 144 FPS only, where 2048 is safe.

## Runtime check (probe `trackers/stalls.lua`, `tools/tour.lua`, removed 2026-09-22)

- The tracker watches every `PhasmidCharacter` except the player's pawn. A stretch runs while it wants to move, meaning nonzero input acceleration or a nonzero `RequestedVelocity` that changed since the last frame, in Walking/NavWalking/Swimming/Flying/Custom. For each stretch it writes framerate, first move, t50 against the mode's max speed, still frames and MaxAcceleration to `stalls_<stamp>.csv`. It logs `stall` lines for stretches that didn't move for 0.05 s (and 5 frames), or that reached 50% of max speed later than 2× what their acceleration allows plus 0.1 s. It logs `stallsummary` per class on each level change.
- **T** tours every level (LS101…LS337) uncapped, 25 s each, starting at the current one. It skips the flight levels and speedways (105, 111, 117, 123, 129, 209, 220, 221, 228, 307, 316, 325, 334): Spyro never walks there, and a crash stops on a Retry/Quit screen. Spyro stands at the level start, so this catches patrols and wanderers. Seek/Flee characters need normal play near them, uncapped, with the same tracker running.
- Custom mode (6, Phasmid spline and flee traversal) counts as wanting to move for its whole duration, since it may not use `Acceleration`/`RequestedVelocity`. A mode-6 stretch flagged "stalled" could be a real stall or just an idle custom mode, so check those by hand.

- **U** (`tools/spawntest.lua`) spawns each of the 185 chase/flee types (`tools/spawnlist.lua`, generated from the survey, bosses last) 450 in front of Spyro, one at a time, uncapped. It watches each for 8 s and logs a `spawntest` verdict per type: stalled / moved / idle / failed. The verdict comes from per-state time spent wanting to move and time standing still meanwhile. Rows go to `spawntest_<stamp>.csv`. Progress is kept in `spawntest_progress.txt`, and a type that crashed the game is skipped on the next run. Before each spawn, the spawn test puts Spyro back where the run started, facing the same way (knockback and respawns move him). `BP_CES3361_HoverCannonRhynoc_C` crashed on spawn with an access violation (14:34), a different failure from the class-load aborts. During the spawn test and the tour, `lib/invuln.lua` tops Sparx up to full every 2 s (the game's `GE_BasicHeal`, once per missing point of `HealthCurrent` vs `HealthMax`). He still takes hits and knockback. Dropped approaches: `GE_Invincibility` (`DamageSystem.CannotTakeDamage`) didn't stop hits or knockback, because the `GA_Spyro_Damage_*` knockbacks are triggered straight by gameplay events and `DamageLibrary` `MakeInvulnerable(Force)` strips every effect that grants the tag. A "ghost" Spyro (collision off, held in Flying) slowly rose through the air. Loading a variant class aborted with "Could not find SuperStruct ..." (types 101 and 107, later 111), each right after the previous type sharing its parent was destroyed. A forced garbage collection after each removal didn't help (type 111, `LaserRhynoc_Gallery`, crashed the same way right after `LaserRhynoc`). Keeping only the previous type alive stopped the obvious cases, but type 160 (`BP_LS328_MoneybagsRevenge_C`, a subclass of the Spyro 3 Blue Thief tested earlier) crashed the same way. Every crashing type subclasses an enemy Blueprint that was spawned and destroyed earlier in the session. The test now keeps every tested type alive (hidden, frozen with time dilation 0, no collision) until the run ends. The Spyro 3 skate-race crab `BP_CES3056_GiantCrab_SkateRace_Blue_C` aborted the engine on spawn (13:56), so it and `_SkateRace_C` are skipped. Out of their home level these types have no waypoints or level triggers, so "idle" only means the triggers didn't fire, not that the type is fine.

## Spawn test results (2026-09-19 13:42–14:54, Stone Hill LS102, uncapped 240–370 FPS)

Combined per type in `build/spawntest_results.csv` (newest result per type, from `spawntest_*.csv` in the probe folder; the first 450-distance run is left out). 178 of 185 types have a result. 7 crashed and were skipped: 94, 95, 101, 107, 111, 129, 160. Verdicts: 58 moved, 116 idle (never asked to move out of their home level, so inconclusive), 1 moved without a request, 3 stalled.

**Caveat: LS102 sits at (0, −300000), so X has fine position steps.** A move from rest with any X component isn't rounded away, and only the Y part is on the 1/32 grid. Most levels sit at (±300000, ±300000). This run understates the stalls: re-run it in one of those (the start line now logs Spyro's position).

| Type | MaxAcceleration | FPS | Stall |
|---|---|---|---|
| `BP_CES2019_WaterWorker_B_C` (Spyro 2) | 512 | 280, 340 | Both runs. NoWater_Patrol: first move after 3.54 s, still 3.52 of 5.77 s wanting to move. Recovery: first move 1.25 s. |
| `BP_CES3016_RhynocSpearmen_C` (Spyro 3) | 680 | 342 | ChargeTarget: first move after 2.34 s, still 2.31 of 3.76 s. |
| `BP_CES1015_Ram_C` (Spyro 1) | 512 | 228 | First run only (450 away): Charge still 0.94 of 4.74 s, Attack 0.61 of 0.79 s. Moved normally at 351 FPS in the later run, since the rounding depends on heading and position. |
| `BP_CES3056_GiantCrab_C` (Spyro 3) | 2048 | 340 | PatrolWander still for its whole 0.42 s, then attacked. Too short to call. |

- The default-acceleration chasers and chargers that moved (Army Gnorc, Metalback Spider, Demon Dog, Yak, Horned Rabbit, Crab, ...) started within 3–10 ms at 300–370 FPS. With a fine X axis that's expected, so it doesn't clear them for other levels.
- Low-acceleration types that never triggered here: Diving Ducks (100), Gulp (500), Young Earthshaper (512), Hockey and Cat Hockey Rhynoc (680, 780), Toasty (800), the Spyro 1 and 3 sheep (1200). Most bosses were idle too. Only Fire Worm and Buzz (LS326) moved.
- Crashes on spawn: the skate-race crab and the Hover Cannon Rhynoc (access violation) depend on their level setup. The Ninja Rhynoc Backflip Wall, Shooting Ninja Rhynoc Spawned, Laser Rhynoc Gallery and Moneybags Revenge classes aborted the loader (see the spawn test notes above).

## Spawn test on a coarse level (2026-09-19 15:20–16:03, Spyro at (−298858, −297981), both axes on the 1/32 grid)

Three sessions (`spawntest_20260919_152017/154736/155918.csv`, combined in `build/spawntest_results_coarse.csv`). Bosses, egg thieves, crashers and never-moving types were skipped. 84 types were measured at 260 FPS or more: 47 moved, 30 idle, 1 moved without a request, 6 flagged.

| Type | MaxAcceleration | FPS | Flag |
|---|---|---|---|
| `BP_CES1015_Ram_C` | 512 | 301–302 | Charge: first move after 1.97 s (still 1.98 of 5.49 s wanting to move; under the half-still rule, so not flagged for it). Attack: still 0.61 of 0.81 s. **Rounding stall.** |
| `BP_CES2019_WaterWorker_B_C` | 512 | 266 | NoWater_Recovery: still 1.36 of 2.37 s. Stalled in every run. **Rounding stall.** |
| `BP_Cowlek_C` | 2048 | 299 | Flee: still 5.30 of 7.98 s, 130 units, max speed 61. **Not the bug:** at 30 FPS it was also still about half the time (2.67 of 5.60 s, 152 units, same max speed 55), so its flee is stop-start by design. It covered 27 units per second of wanting to move at 30 FPS against 16 at 299, which is too small a difference to call. |
| `BP_CES3056_GiantCrab(_Blue/_Scorch)_C` | 2048 | 306–317 | TurnAway/return: about 2 s wanting to move, almost no movement. **Not the bug:** all three were identical in a 30 FPS control run (still 2.00 of 2.00 s), so it is crab behaviour out of its level. |

- Rhynoc Spearmen (680) moved normally here, although it stalled for 2.3 s in the Stone Hill run. Low-acceleration stalls depend on heading and position, so one clean run doesn't clear a type.
**30 FPS control run (2026-09-19 20:26, `fps=30 only=Cowlek,GiantCrab`)**: the trigger file now takes `fps=<cap>` and `only=<name,name>`, which ignore the skip rules and the progress file. It cleared the crabs and the Cowlek, so no default-acceleration type is confirmed yet.

- The default-acceleration types that moved at ~300 FPS started within a few ms. They're near their threshold (~304–362 FPS), so they may still stall at higher framerates or other headings.

## 30 FPS controls (2026-09-19 20:26–20:28, same spot)

Each flagged type re-run with `fps=30 only=...`. Distance per second of wanting to move is the clearest measure.

| Type | Accel | 30 FPS | high FPS | Verdict |
|---|---|---|---|---|
| `BP_CES1015_Ram_C` | 512 | charge starts in 0.033 s, still 0.03 of 1.07 s, 148 units/s | 301 FPS: starts after 1.97 s, still 1.98 of 5.49 s, 32 units/s; attack still 0.61 of 0.81 s | **rounding stall** |
| `BP_CES2019_WaterWorker_B_C` | 512 | still 0.07 of 2.30 s (3%), 83 units/s | 266 FPS: still 1.36 of 2.37 s (57%), 33 units/s | **rounding stall** |
| `BP_CES3016_RhynocSpearmen_C` | 680 | charge starts in 0.033 s, still 0.04 of 0.70 s, 209 units/s | 342 FPS (Stone Hill): starts after 2.34 s, still 2.31 of 3.76 s, 39 units/s | **rounding stall** |
| `BP_CES3056_GiantCrab(_Blue/_Scorch)_C` | 2048 | still 2.00 of 2.00 s | 306–317 FPS: the same | not the bug |
| `BP_Cowlek_C` | 2048 | still 2.67 of 5.60 s, 27 units/s | 299 FPS: still 5.30 of 7.98 s, 16 units/s | not the bug (stop-start flee) |

Status: static survey done. Three enemy types confirmed by 30 FPS controls (Ram, Water Worker, Rhynoc Spearmen: all low-acceleration walkers, 512–680), none fixed. No default-acceleration (2048) type confirmed yet; they were tested at ~300 FPS, just above their ~304–362 FPS threshold. Untested: the low-acceleration types that never triggered outside their level (Gulp 500, Young Earthshaper 512, Hockey Rhynocs 680/780, Toasty 800, sheep 1200, Diving Ducks 100, `BP_LS207_Fish_C` 25), patrols (the tour), and Spyro 2/3 characters in their own levels.

## Planned fix: one module for every NPC's walking

Three unrelated enemy types are confirmed and more are untested, so a per-character hook (as `fixes/sheila.lua` and `fixes/buzz.lua` do) doesn't scale: 594 classes have moving states. Plan a single `fixes/npcwalking.lua` (`FIX_NPC_WALKING`) in `levelFixes` (it needs no pawn), reusing the movement model the walking fix already has.

**What it does per tracked character**, once `util.aboveReferenceFps(dt)`:

1. Gate on movement mode Walking or NavWalking, no anim root motion, and `bEnableCarMovement` false (Buzz's fix owns car movement).
2. Predict the unrounded velocity with `lib/movement.lua`: `calcRequestedWalkingVelocity` while the AI's move is live (`RequestedVelocity` nonzero and changed since last frame, as `fixes/sheila.lua` decides it), otherwise input acceleration or braking.
3. Write it back only when the engine's velocity differs from the prediction by rounding alone (per axis within `quantizationTolerance`), so collisions and scripted moves are followed instead.

**Finding the characters without polling:** `NotifyOnNewObject("/Script/Phasmid.PhasmidCharacter")` for spawns, plus a `FindAllOf` on load and on pawn change with the usual `lookup` budget. Keep a table keyed by address with the movement component cached (`engine.characterMovement` style), dropped when the actor goes invalid.

**Cost is the main risk.** `docs/ue4ss.md` puts a struct read at ~330 B and the whole mod at 2.14 KB/frame idle. A level can hold dozens of characters, and the naive version reads `MovementMode`, `Velocity`, `RequestedVelocity` and `Acceleration` from each one every frame (~1.3 KB per character per frame), which would dwarf the current budget. So:

- Only track characters within `NPC_RADIUS` (start at 3000) of the player, refreshed every 0.25 s from one location read per character; a character outside it costs one read per refresh.
- A character that is idle (no request, no acceleration, zero velocity) is checked every Nth frame instead of every frame; a stall lasts many frames, so a few frames of delay costs nothing.
- Profile with `PROFILE` plus `GC_PROFILE` before and after, in a busy level (Town Square, Midday Gardens), and compare against the 2.14 KB/frame idle baseline.

**Verification:** re-run the probe spawn test on the three confirmed types at 30 FPS and uncapped (`fps=30 only=CES1015_Ram,CES2019_WaterWorker,CES3016_RhynocSpearmen`), and check that distance per second of wanting to move matches the 30 FPS numbers in the table above (148 / 83 / 209 units) within about 10%. Then the tour for patrols, and a pass through a Spyro 2 water level for the Water Worker in its own level.

**Open questions:** whether the AI's requested moves in Custom movement mode (the thieves' flee, waypoint traversal) need the same treatment (the tour should say); and whether writing velocity on characters whose Blueprints move them directly (`K2_SetActorLocation`, montage root motion) can be told apart by the root-motion and tolerance checks alone.
