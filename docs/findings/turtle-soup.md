# Sunny Beach turtle soup: turtle walking and the charge slide

Question (2026-10-06): in the Sunny Beach (LS206) orb challenge "turtle soup", do the box turtles walk
and slide the same at high FPS as at 30? Two different movement systems are involved, so they are two
separate questions. **Nothing has been measured in game yet** — this is the static analysis and the
probe that will answer it.

## The minigame

`BP_Orb_Turtle_Controller` (LS206_SunnyBeach/Blueprints) spawns `BP_BoxTurtle_Spawned_C` turtles, which
walk to `BP_TurtleCauldron` and jump in; the player charges them away to stop them. The controller has
two games (`StartGame1` / `Start Game 2`, `Game1Timer` / `Game2Timer`, `SpawnTurtle(Dummy)`), the usual
`Mission_*` interface, and a `CurrentTurtles` / `MyTurtles` array.

The level's own turtles are a different class, `CES2225_BoxTurtle_C` (and `_NoPlate_C`): plain
`MoveToTarget` walking and a pressure plate, no slide. They share the mesh and the animations, so they
are the walking control.

## The turtle's state machine (`BP_BoxTurtle_Spawned`, exports #116–#130)

`FalconEnemyComponent` with `InitalStateName = Idle`:

| State | Movement | Montage | Leaves on |
|---|---|---|---|
| Idle | none | — | the controller changes it |
| MoveOutOfTube | TraverseWaypointsOnce → Waypoint | AM_2225_Run | 4 s or 80 units → MoveToCauldron |
| MoveToCauldron | SeekPlayer → Target (the cauldron) | AM_2225_Run | distance 110 → Pause; Damage.Charge/SuperFire → SlideIn; Damage.Fire → TurnAway |
| MoveToCauldron_Invuln | SeekPlayer → Target | AM_2225_Run | 1.75 s → MoveToCauldron |
| MoveToDummy | SeekPlayer → Target (a `Turtle_Dummy` spawned 300 ahead) | AM_2225_Run | 3 s → MoveToCauldron; charge → SlideIn |
| Pause | none | — | 3 s → Jump; charge → SlideIn |
| Jump | none, a Blueprint timeline along a spline | — | 1 s → GameOver |
| SlideIn | none (projectile, below) | AM_2225_SlideIn (0.167 s) | montage end → Slide |
| Slide | none (projectile) | AM_2225_SlideLoop (0.333 s, looped) | **3 s** → SlideOut |
| SlideOut | none (projectile off) | AM_2225_SlideOut (0.5 s) | montage end → MoveToCauldron |
| TurnAway | none, a Blueprint timeline `RLerp` | — | the timeline |
| RunAway | FleeFromPlayer | — | 3 s / 200 units → MoveToCauldron |
| Death | — | AM_CES107_Bull_Template_Death | destroys itself |

None of `A_CES2225_Slide_IN/LOOP/OUT`, `_Run` or `_Walk` sets `bEnableRootMotion`, so no animation moves
the turtle: every unit of travel is one of the two movement components.

## Walking: the character movement component

`CharMoveComp` (export #248) over `BP_Base_Enemy`'s:

- `MaxWalkSpeed` **80**, `MaxStepHeight` **20**, `RotationRate` Y 250, `MaxSplineSpeed` 150
- `DefaultLandMovementMode` **NavWalking** (from `BP_Base_Enemy`), `bUseControllerDesiredRotation`
- `MaxAcceleration` not overridden anywhere in the chain → the native **2048**
- capsule radius 20, half-height 20

So MoveToCauldron / MoveToDummy are the Sheila case of `sheila-buzz-walk.md`: a `RequestedVelocity`
accelerated at `MaxAcceleration`, in a mode that resets `Velocity = displacement / dt` after the move.
By `npc-stalls.md` that stalls from rest above **fps ≈ √(64·2048) = 362** axis-aligned and **√(45·2048)
= 304** on a diagonal, and **LS206 streams in at (300000, −300000), so both horizontal axes are on the
1/32 position grid** — the worst case, unlike the Stone Hill spawn test which had a fine X.

A steady walk is safe: 80 units/s is 0.25 units per frame at 320 FPS, eight grid steps. It is only the
first frames out of a standstill (every state change into a walking state, and every recovery after a
slide) that can round to nothing. With `MaxStepHeight` only 20 the blocked-sweep family of
`charge-wall-stall.md` and `skelos-badlands.md` is the other candidate.

## The charge slide: a projectile movement component

The charge does **not** go through the character movement component at all.
`ExecuteUbergraph_BP_BoxTurtle_Spawned` at 2865 (the SlideIn enter event, reached from 4614):

1. `CapsuleComponent.SetCollisionResponseToChannel(0/1, 2)` — block WorldStatic and WorldDynamic.
2. `IRequestChargeBonk()` on the player.
3. Face away: heading from the player + 180 → `K2_SetActorRotation`.
4. `Displace (Actor)` by 0 with that yaw, no sweep, teleport — an unstick.
5. `PhasmidProjectileMovement.Activate(false)`; `MaxSpeed = 300`;
   **`SetVelocityInLocalSpace((300, 0, 0))`**.
6. Spin loop sound and `PS_VFX_LS206_Soup_Turtle_Spin`.

On Slide exit (4011) the component is deactivated, the sound and particles stop and `MaxSpeed` is set
back to 300. Component defaults (export #250): `MaxSpeed` 300, `bShouldBounce`, `Friction` **0**,
`bBounceAngleAffectsFriction`, `BounceVelocityStopSimulatingThreshold` **0**, `bConstrainToPlane`,
`bInitialVelocityInLocalSpace` false. The native `PhasmidProjectileMovementComponent` defaults
(gravity scale, bounciness, `MaxSimulationTimeStep`/`MaxSimulationIterations`, the plane normal) are not
in the asset — the probe dumps them at runtime as `turtlepmc`.

So the slide is ~3.17 s (SlideIn 0.167 + Slide 3) of projectile movement at 300 units/s, bouncing off
the arena walls, ≈ 950 units of travel. Candidates for a framerate difference:

- **Bounces.** `UProjectileMovementComponent::HandleBlockingHit`/`HandleDeflection` resolve a bounce
  within the frame and re-sweep the rest; with `Friction` 0 and the stop threshold 0 the speed should be
  preserved, but a sweep that blocks at `Time` 0 leaves no displacement, and a tiny dt makes that far
  more likely — the same blocked-frame family as `charge-wall-stall.md`. A turtle that loses a frame
  per wall contact slides shorter at high FPS.
- **The character movement component is still ticking** while the projectile component drives the actor.
  Nothing in the Blueprint disables it, and `PhysWalking` recomputing `Velocity` from the frame's
  displacement can fight the projectile's own velocity. Whether it does is a runtime question.
- **The 3 s `Slide` trigger** is a Falcon time trigger with `bAdjustForActorTimeDilation`, so it should
  be framerate-independent; the montages are short and looped, so they are not what ends it.

## The probe (`trackers/turtle.lua`, 2026-10-06)

Tracks every `BP_BoxTurtle_Spawned_C`, `CES2225_BoxTurtle_C` and `_NoPlate_C` within 12000 of Spyro,
reading both movement components side by side. Blocking hits come from `lib/enemyhits.lua`, the shared
hook on `BP_Base_Enemy`'s capsule hit event (factored out of `trackers/lizard.lua` on the same day so
two trackers do not both `RegisterHook` the one Blueprint function).

- `turtle_<stamp>.csv` — one row per frame per active turtle: state and state time, movement mode,
  position/yaw/displacement, the CMC's `Velocity`/`RequestedVelocity`/`Acceleration` and its limits, the
  floor, root motion, the projectile component's active flag/velocity/speed/heading, hits (total, at
  `Time` 0, walls), distance to Spyro and to the state's target.
- `turtle_hits_<stamp>.csv` — every blocking hit: what was hit, the normals, the sweep and its `Time`.
- `turtleslide` — **the headline line**, one per slide from the charge hit to the turtle being back on
  its feet: duration, path length, net distance and heading change from where it was hit, bounces, hits
  at `Time` 0, max/avg projectile speed, still frames, the states it passed through.
- `turtlestart` — a walking state entered from a standstill: time to 50% and 90% of `MaxWalkSpeed` and
  to the first move that was not rounded away.
- `turtlestall` — a walking state that got nowhere: duration, still frames, velocity/request/accel, the
  blocking normals and how many hit at `Time` 0.
- `turtlerun` — one per state: duration, distance, max/avg speed, still frames, hits.
- `turtlecmc` / `turtlepmc` — both movement components dumped once, for the first minigame turtle.

## How to run it

1. Deploy: `tools/Install-UE4SS.ps1 -ModsOnly -Probe` with the game **closed** — UE4SS watches the
   deployed folder and the reload it triggers crashed the game when this tracker was first deployed
   (access violation inside `UE4SS.dll`, nothing after the `Auto-reloading Lua mod` line in the log).
2. Go to Sunny Beach and stand by whoever starts the orb challenge; **V** saves the spot, **B** returns
   to it, so each take starts the same way.
3. **F5** for 30 FPS, play a run, then **F4** for 320 and play the same run. Every log line and CSV row
   carries the cap, so the two line up.
4. Charge turtles from a standing start and from the same angle in both runs; the slide distance depends
   on where it was hit and which wall it meets, so compare several.

## What to compare

| Measurement | Where | Matches 30 FPS if |
|---|---|---|
| Slide path length and net distance | `turtleslide` | within a few % at 320 |
| Slide duration | `turtleslide` | ≈ 3.17 s at both (the Falcon time trigger) |
| Projectile speed held | `turtleslide` `pmcSpeed avg` | ≈ 300 at both; a lower average means frames lost to blocked sweeps |
| Bounces | `turtleslide` `bounces` / `hits t0` | the same count off the same walls |
| Walk from rest | `turtlestart` | `firstMove` within a frame or two of 0, `t90` the same |
| Walk speed | `turtlerun` `avg` | ≈ 80 at both |
| Stalls | `turtlestall` | none at either framerate |

## Measured (2026-10-10, `turtle_20261010_125621.csv`, 30 FPS vs 220–270 FPS)

One session, 11 minigame turtles, 13 slide episodes, 36 starts from rest, no `turtlestall` lines and no
`error:` lines. The framerate came from the game's own cap rather than F5/F4, so the log lines carry
`cap=?` and the real figure is each line's `avgFps`.

**Native projectile defaults** (`camdump_20261010_125835_turtlepmc.txt`), which the asset didn't hold:
`Bounciness` **0.6**, `ProjectileGravityScale` 1, `MaxSimulationTimeStep` 0.05,
`MaxSimulationIterations` 8, **`bForceSubStepping` false**, and `bConstrainToPlane` true with a
`PlaneConstraintNormal` of (0,0,0) and `PlaneConstraintAxisSetting` Custom — a zero normal, so the
constraint is a no-op. With substepping off and a 30 FPS frame (0.0333 s) already under
`MaxSimulationTimeStep`, the component takes one step per frame at every framerate, which is why there
is nothing here for the framerate to change.

**The slide is framerate-clean.** Per slide episode, actual travel rate over the projectile's own
velocity magnitude:

| | 30 FPS | 220–245 FPS |
|---|---|---|
| travel / projectile speed | 0.984–0.995 | 0.992–1.003 |
| zero-displacement frames | 0–1 of ~92 | 0 of ~500–740 |
| speed held, slides that never hit a wall squarely | 291–296 | 295–297 |
| speed held, slides that bounced | 193–214 | 212–237 |
| duration (SlideIn + Slide) | 3.066–3.067 s | 3.010–3.014 s |

So no frames are lost to blocked sweeps at either framerate, and the speed held is set by `Bounciness`
0.6 and which wall it meets, not by dt — 300 → 180 on a head-on bounce, at both. The `hits` counts are
~1.5–1.7 per frame at **both** framerates, nearly all at `Time` 0: constant floor contact, not a stall.
Path length (390–863) varies entirely with the bounce geometry, which is why it has to be read next to
the speed-held ratio rather than on its own. The only difference is the duration, 0.055 s (1.8 %)
longer at 30 FPS, which is the 3 s Falcon time trigger snapping to a 33 ms frame boundary.

**Walking matches, and 30 FPS is the slower one.** Mean per-frame speed over the frames that moved, per
state run (`MoveToCauldron` / `_Invuln` / `MoveToDummy`):

| | 30 FPS | 220–270 FPS |
|---|---|---|
| speed while moving (`MaxWalkSpeed` 80) | 76.1–80.0, clean runs ≈ 79.7 | 76.2–79.1, clean runs ≈ 78.6 |
| frames standing still | **3.70 %** (892 frames) | **0.24 %** (13,483 frames) |
| whole-state average, still frames included | ≈ 76.8 | ≈ 78.4 |
| `turtlestart` `firstMove` | 0.100 s (3 frames) | 0.011–0.014 s |
| `turtlestart` `t90` to `MaxWalkSpeed` | 0.133 s | 0.041–0.053 s |

Moving speed is within 1.4 %, and the net travel rate is if anything slightly *ahead* at high FPS,
because 30 FPS loses 15× more frames to standing still. `t90` of 0.041 s at high FPS is exactly the
`MaxWalkSpeed`/`MaxAcceleration` = 80/2048 = 0.039 s the acceleration allows; at 30 FPS the same ramp
costs 4 frames, so each state entry starts ~0.09 s late. That is the only measurable walking
difference, and it favours high FPS.

**No pathfinding difference.** `dist` and `net` agree to under 1 % in every walking run at both
framerates (356.2/356.0, 257.8/257.7, 424.4/425.0, …): a dead-straight approach to the cauldron, no
wandering or circling either way. One run printed `net=421601.7` on a 392-unit path — a tracker bug,
not game behaviour, when a turtle is destroyed mid-state and its last position is read in another frame
of reference. `logRun` now prints `net=jumped` when the net exceeds the path travelled.

**The derived velocity is noisy at high FPS; the travel is not.** `velMax` runs 83.7–85.2 against a
`MaxWalkSpeed` of 80 at high FPS (and 103.6–105.3 against 100 for the level's own turtles), about 5 %
over, while 30 FPS reads 80.5. That is the 1/64 quantization of a 0.35-unit frame move showing up in
NavWalking's `Velocity = displacement / dt`, not a real speed change — the path speed over those same
frames is 78.6.

**Caveat: this did not reach the predicted threshold.** The high-FPS runs were 220–270 FPS, and the
quantization stall for `MaxAcceleration` 2048 is predicted above ~304 FPS (diagonal) to ~362
(axis-aligned). The stall from rest is therefore still untested for these turtles: re-run with **F8**
(uncapped) or **F4** (320) to settle it.

Status: measured at 30 vs 220–270 FPS — walking speed, pathfinding and the charge slide all match
30 FPS, so there is nothing to fix. Untested above ~270 FPS.
