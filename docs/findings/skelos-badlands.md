# Skelos Badlands (LS212) orb mission: lava lizard steps and the steam vent (prepared 2026-10-06)

Two reports from the mission, both at high FPS, neither measured yet:

1. One of the lava lizards ("the dinosaurs") should climb two steps near the end of its route and can't.
   It gets up eventually.
2. The gust of air that lifts the bone-stealing lava toad isn't blowing. Seen on a level load at 320 FPS;
   30 FPS being checked.

## The mission, from the assets

- `chunk1\Plugins\Levels\LS212_SkelosBadlands\Content\Maps\LS212_design.umap` places 16 `BP_LavaLizard_C`
  (`BP_LavaLizard2..8`, `BP_LavaLizardB1..B8`), 16 `BP_CNS2221B_CavemanBoneBuilderBaby_C` (`_01..08`,
  `_B01..B08`), a `LizardStartTrigger`, a `BP_LizardReset`, `IGC_Selector_Lizards1/2` cutscene selectors
  and a `MissionMaster_Collect`. Runtime instances named `BP_CNS2221B_CavemanBoneBuilderBaby_Chased1/2`
  appear as well. The lizards run the mission's `Mission*` events (`MissionSetup`, `MissionReset`,
  `MissionEnd`, ...).
- `BP_LavaLizard` (`chunk1\Plugins\Characters\Enemy\CES2031_LavaLizard`) states: `Spawn`, `ShakeEgg`,
  `Idle`, `Wait`, **`WalkToGuy`** (MovementMode `TraverseWaypointsOnce`, target Waypoint, montage
  `AM_CES2031_Walk`), `TurnToGuy`, `WaitBeforeEating`, `EatGuy`, `Done`, `Death`, `LaunchToDeath`.
- Movement defaults (`CharMoveComp`, a `PhasmidCharacterMovementComponent`): **MaxStepHeight 50**,
  MaxWalkSpeed 143, WalkableFloorAngle 50, RotationRate yaw 250, DefaultLandMovementMode Walking,
  MaxAcceleration 2048 (inherited), capsule radius 23.49, half-height 40. The Blueprint keeps its own
  `MyMaxStepHeight`, read from the component at BeginPlay and written back on a mission reset.
- In a live session (`stalls_20261006_070850.csv`, LS212) the lizards walk in **movement mode 6 (Custom)**
  with `RequestedVelocity` and `Acceleration` at 0 and speed up to 143, so the Phasmid waypoint traversal
  moves them itself rather than through input acceleration. Mode-6 stretches averaged 147 still frames at
  320 FPS (≈0.46 s) against 1 frame at 30 (≈0.03 s) — that is the symptom to pin down, not yet a cause.

### Why a step is suspect at high FPS

At MaxWalkSpeed 143 a frame's move is 4.8 units at 30 FPS and 0.45 at 320. That is the size at which
`docs/findings/charge-wall-stall.md` found frames blocking at `Hit.Time` 0 and leaving no displacement at
all (the 1/32 position lattice 300,000 from the origin is 0.03 units). A step-up also sweeps forward by
that same per-frame delta after lifting the capsule, so a short frame has less of the step top to land on.
Whether the lizard stalls, or climbs only on a long frame, is what the probe now records.

### The steam vent

`BP_SteamVent` (`LS212_SkelosBadlands\Content\Blueprints`, one instance `BP_SteamVent_52`), from
`AssetDump --code`:

- BeginPlay binds the game state's `OnPlayerReady`. `Player rEady` binds `ItemStateChange` to
  `MySteamLavaToad`'s `FalconEnemyComponent.OnStateChange`, stores the toad's Z in `StartingPos`, then
  loops: `Steam_VFX.K2_DestroyComponent` → `SpawnEmitterAtLocation(PS_LS212_VFX_LavaToad_Steam_Vent_Orange)`
  → `AkAudio.PostAkEvent(fx_ls212_steam_vent)` → `Timeline_0.PlayFromStart()` → `Delay 0.2` → round again.
- `Timeline_0__UpdateFunc` runs once per tick and sets the toad's location to
  `(toad.X, toad.Y, StartingPos + Timeline_0_NewTrack_1_<guid>)` with `K2_SetActorRelativeLocation`
  (sweep off, no teleport). So one float curve track drives the whole lift, and the timeline is restarted
  every 0.2 s.
- `ItemStateChange` stops the timeline when the toad's state reaches `WatchState`, which defaults to
  `LaunchToDeath` — i.e. when it dies, so a state race at load is unlikely to be the cause.

Hypotheses to separate, in this order:

1. The Blueprint stops asking: the timeline isn't playing, or the track stays at 0 (the chain never
   started, or `Delay`/`PlayFromStart` interact badly).
2. The Blueprint asks and the engine undoes it: the toad is a character, so its movement component runs
   after the Blueprint's tick and re-plants it on the floor. The commanded rise per frame falls with dt
   (0.45 units at 320 FPS where 30 FPS gets 4.8), which is the scale the floor snap and the position
   lattice work at — the same family as the stall above.
3. The steam particles themselves don't emit (the `docs/findings/charge-dust.md` family, where a
   respawned effect's single tick emits `floor(rate·dt)` = 0 particles). Here the effect lives 0.2 s, so
   this is the least likely of the three, but the component's bounds are logged to rule it out.

## Probe tooling (added 2026-10-06, not yet run in game)

- `trackers/lizard.lua`: every `BP_LavaLizard_C` within 12,000 units of the player. `lizard_<stamp>.csv`
  per frame per active lizard (state, mode and custom mode, position, displacement, dz, velocity,
  `RequestedVelocity`, acceleration, MaxStepHeight, floor dist and normal, root motion, hit counts).
  `lizardstall` lines for a stretch in `WalkToGuy` that got nowhere, with the blocking normals and how
  many hits were at `Time` 0; `lizardstep` lines for each z gain over 3 units, with **the dt of the frame
  that managed it against the running average** (whether only a long frame gets it up); `lizardsummary`
  per state. Hits come from a hook on `BP_Base_Enemy_C`'s capsule `OnComponentHit`
  (`BndEvt__CapsuleComponent_K2Node_ComponentBoundEvent_3_ComponentHitSignature__DelegateSignature`),
  filtered to lizards, into `lizard_hits_<stamp>.csv`.
- `trackers/steamvent.lua`: no hooks, so it survives a hot reload. Per frame it reads the vent's
  `StartingPos`, the timeline track property, `Timeline_0:IsPlaying`/`GetPlaybackPosition`, the
  `Steam_VFX` component (address changes count the Blueprint's respawns, `IsActive` and
  `GetComponentBounds` stand in for particle activity) and the toad's position, movement mode, velocity
  and floor. `vent` lines once a second; `ventlift` per lift attempt: commanded rise against the rise the
  toad kept, and the frames that were commanded up but stood still or were pulled back down.

Both are always on and cost nothing outside LS212 (no lizard or vent actor, no rows).

## Measured in game, 2026-10-06 07:36–07:42 (trace/lizard/steamvent `*_20261006_073630.csv`)

One pass of the mission uncapped (180–220 FPS, logged `cap=?`), then one at 30, probe trackers as above.

### The steps: confirmed, and it is the frame's own length that decides

`BP_LavaLizardB6` is the lizard with the long route (985 units) and the only one that meets the two
steps. Its `WalkToGuy` state, same route both times:

| | uncapped (≈208 FPS) | 30 FPS |
|---|---|---|
| duration | **9.747 s** | **6.935 s** |
| distance | 985.8 | 983.0 |
| standing still | 3.005 s, 579 of 2024 frames | 0.100 s, 2 of 208 frames (the first-frame artefact every lizard logs) |
| climbs logged | 4 | 6 |

- **Step 1** at (−302331, −302516), z 564 → 591. Uncapped: a 0.945 s stall, **176 of 179 frames with no
  displacement at all**, 180 blocking hits of which **178 at `Hit.Time` 0**, all against
  `SM_LS212_Collision_2/StaticMeshComponent0` with normal (−0.85, 0.53, **0.00**) — the riser face. It
  then cleared in one frame (dz 18.47, disp 5.18) **on a 36.13 ms frame, against a 6.63 ms average**.
  At 30 FPS the same step is three ordinary 33.3 ms frames (disp 4.75 each, dz 15.1 + 7.3 + 4.5), no stall.
- **Step 2** at (−302142, −302640), z 596 → 622. Uncapped: a 2.026 s stall, 401 of 445 frames still, 446
  hits with **443 at Time 0**, normal (−0.99, 0.10, 0.03). Cleared on frames of 9.87, 32.64 and 30.38 ms.
  At 30 FPS: three 33.3 ms frames again (dz 15.7 + 6.8 + 4.3).
- Stalled frames by frame length (both stalls, `lizard_20261006_073630.csv`):

  | frame | frames | frames that moved at all | largest move | mean move when it moved | total dz |
  |---|---|---|---|---|---|
  | 4 ms | 257 | 23 | 0.407 | 0.059 | 0.25 |
  | 5 ms | 366 | 28 | 0.738 | 0.196 | 0.25 |
  | 6 ms | 6 | 0 | 0 | — | 0 |
  | 8 ms | 1 | 0 | 0 | — | 0 |
  | 10 ms | 1 | **1** | 1.415 | 1.415 | 8.78 |
  | 33 ms | 3 | **1** | 4.770 | 4.770 | 0.25 |

  So the requested move clears the step at 1.4 units (10 ms) and never at 0.4–0.7 (4–5 ms). The threshold
  is between ~0.75 and ~1.4 units of requested displacement, i.e. somewhere around 100–140 FPS for this
  lizard's 143 speed. The few short frames that move at all creep in multiples of the 1/32 lattice
  (0.059 ≈ 2 steps, 0.407 ≈ 13).

- Throughout the stall it is in **MovementMode 6 (Custom), CustomMovementMode 1** — Phasmid waypoint
  traversal — with `MaxStepHeight` **900** (the game raises it from the Blueprint's 50 for this walk),
  standing on flat walkable floor (`floor_nz` 1.0, FloorDist 1–2), `RequestedVelocity` and `Acceleration`
  at 0 and `Velocity` steady at 143. Nothing moves vertically either (total dz over all the short stalled
  frames is 0.5 units): the climb is done entirely by the one long frame.

**Cause.** Custom traversal asks for the same 143 units/s at every framerate, so the per-frame move
shrinks with dt (4.8 units at 30 FPS, 0.45 at 320). Against the riser the whole swept move blocks at
`Time` 0 — no slide, no step-up, zero displacement — and the next frame starts from the same place, so it
repeats. A step-up is only accepted once the forward part of the move is big enough (≥ ~1.4 units here,
with MaxStepHeight already at 900, which rules the height out), which at this framerate only happens on a
hitch. That is the same blocked-frame family as `charge-wall-stall.md`, but without the velocity reset:
Custom mode doesn't recompute `Velocity` from the displacement, so the lizard keeps its speed and simply
doesn't translate.

Fix idea, not written yet: dilate the lizard while it is stalled so its own frame is 30 FPS long, the way
`FIX_CHARGE_DUST` dilates a one-tick effect (`CustomTimeDilation = (1/30)/dt` on one frame out of every
(1/30)/dt, ~1e-3 on the others). That reproduces 30 FPS movement exactly, which is the target, and needs
no native call. Alternatives: nudge the actor over the step by hand once a stall is detected, or raise the
requested speed while blocked (which 30 FPS does not do, so it would overshoot).

### The steam vent: no framerate difference seen yet

55 `ventlift` attempts across the session, at 30, ~190 and 320 FPS. Every one is the same: duration
4.83 s, `trackMax` 227.6, **rise kept 226.9–227.1**, commanded rise 255.5–255.8 spread over 83 frames at
30 FPS and 486–576 frames uncapped, **`stuck` 0 and `pulledBack` 0 in all of them**. So the Blueprint's
`K2_SetActorRelativeLocation` wins against the toad's movement component at every framerate (it stays in
NavWalking with FloorDist 0), and hypothesis 2 above is out. The `Steam_VFX` component is present and
active with the same bounds radius (866) at 30, 320 and uncapped, so hypothesis 3 is out for the emitter
existing at all.

The vent spawns its emitter **once** (`respawns` 1, then 0) and the timeline runs past 2.6 s of playback,
so the 0.2 s `Delay` loop in the bytecode does not actually go round again — one emitter, one timeline
run, repeating about every 5 s.

The one state the probe did see with nothing blowing is after the mission: `playing=nil`,
`track` frozen at 213.9, `vfx=none`, and the toad at z 0 in state `None` — i.e. the toad gone and
`ItemStateChange` having stopped the timeline for good (`WatchState` is `LaunchToDeath`). 3,821 frames of
that at the end of the session. Worth checking against what was reported: the chain also does nothing
before `OnPlayerReady` (the first two seconds of the level show `playing=nil`, `track` 0,
`StartingPos` 0).

## Fix (`FIX_LIZARD_STEPS`, `fixes/lizard.lua`, written 2026-10-06, not verified in game yet)

A hook on `BP_LavaLizard_C:ReceiveTick` (one hook, every lizard, re-registered when the level loads,
`lookup.hookLevelFunction`) watches each lizard that is in MovementMode 6, on frames shorter than a
30 FPS frame. A frame counts as blocked when it moved less than 1e-3 horizontally while `Velocity` is
still asking for more than 10 units/s. After 3 blocked frames in a row the lizard gets its time in 30 FPS
portions, the way `FIX_CHARGE_DUST` does for a one-tick effect:

- one tick in every 1/30 s of real time gets `CustomTimeDilation = (1/30)/dt`, so it asks the engine for
  the same 4.8-unit move a 30 FPS frame does and the step-up is accepted;
- the ticks in between get 1e-3, so they ask for nothing and the total time the lizard gets is unchanged;
- normal time comes back after 2 portions in a row that moved at least a quarter of a 30 FPS move, or as
  soon as the lizard stops asking to walk, leaves mode 6, or the frame is 1/30 s or longer. 10 s of
  portions for one lizard is the safety valve, and a lizard the game is already dilating is left alone.
- Each stint logs one line: `lava lizard step fix: BP_LavaLizardB6 stepped for 0.123s, 4 portions
  (2 moved) over 25 frames, cleared`.

To verify: the probe's `trackers/lizard.lua` is still in place, so run the mission at 320 and compare
`lizardsummary BP_LavaLizardB6 state=WalkToGuy` against the 30 FPS numbers above (9.75 s and 3.01 s
standing still unfixed, 6.94 s and none at 30). The stalls should shorten to a few frames each, the
`lizardstep` lines should no longer need a 30 ms hitch, and the route time should land near 7 s.

The steam-vent tracker (`trackers/steamvent.lua`) was removed on 2026-10-06, since 55 lift attempts
measured the same at 30, ~190 and 320 FPS. The measurements above are the record; if the gust turns out
to be wrong at high FPS after all, it needs a new repro first (what state the vent was in), not the
tracker back.

## Second run, 2026-10-06 08:03 (320 FPS, ~158 actual, `lizard_20261006_080314.csv`)

The fix was deployed and its hook registered, but **it never engaged**, so this run is another unfixed
measurement — and a worse one, which is useful: it shows the stall has two shapes.

- `BP_LavaLizardB6` stalled at the **first** step, (−302334.8, −302513.8, 564.24), for **12.749 s**, 2006
  of 2022 frames still, 2019 of 2022 hits at `Hit.Time` 0 against the same
  `SM_LS212_Collision_2` face (normal (−0.85, 0.53, 0.00)), `zGain` 0.000, net move 0.364. It never got
  up: the state ended it (WalkToGuy → PreIdle, the mission giving up on it). Route total 17.0 s with
  12.8 s standing still, against 9.75/3.01 in the first run and 6.94/0 at 30 FPS.
- The difference from the first run: **`Velocity` was exactly 0.00 on every frame of this stall** (best
  in the whole stall 7.1), where the first run kept the full 143 throughout. 7.1 is in the (1/32)/dt
  range for a 6.25 ms frame (10.0), the signature of a restart from rest whose per-frame gain is rounded
  away (`sliding-walking.md`, `buzz-charge-run.md`). So once a blocked frame has taken its velocity, the
  lizard has to accelerate from rest while pressed against the riser, and at this framerate it can't.
- Frame times were a steady 6.25 ms with no hitches, which is why nothing saved it this time. The first
  run only got up the steps on 10–36 ms frames.

**Fix correction.** The trigger used `Velocity` as the "it is trying to walk" test, which this stall
fails, so the fix stood by and watched. It now triggers on MovementMode 6 + no displacement + the
FalconEnemy state being `WalkToGuy` (the state is only read on a frame that is already blocked, and a
lizard that is merely standing about is asked once and then left alone until it moves). Deployed
2026-10-06 08:2x, still not verified in game.

## Verified, 2026-10-06 08:16–08:18 (two runs at 320 FPS, 199–220 actual, fix on)

`BP_LavaLizardB6` got up both steps every time, with no hitch to help it.

| `WalkToGuy` | 30 FPS | unfixed, run 1 | unfixed, run 2 | **fixed** |
|---|---|---|---|---|
| duration | 6.935 s | 9.747 s | 17.011 s (never got up) | **6.823 s / 6.843 s** |
| standing still | 0.100 s | 3.005 s | 12.787 s | **0.133 s / 0.153 s** |
| still frames | 2 of 208 | 579 of 2024 | 2008 of 2695 | **18 of 1360 / 22 of 1394** |
| distance | 983.0 | 985.8 | 613.9 | 984.2 / 983.7 |

- Every stint is the same: `stepped for 0.035–0.038s, 2 portions (2 moved) over 9–11 frames, cleared`.
  Two portions per step, both moved, three stints per route (the first step needs two climbs, the second
  two more: 4 climbs, against 6 at 30 FPS).
- The `lizardstep` lines now land on **ordinary 4.5–5.0 ms frames** (dt at the running average) with
  4.7–4.96 units of displacement, instead of needing a 10–36 ms frame. The stalls are down to
  0.050–0.068 s with 8–11 still frames.
- The hit normals during a fixed stall now include (−0.58, 0.36, 0.73), (−0.67, 0.43, 0.60) and
  (−0.72, 0.47, 0.51) next to the vertical Time 0 ones: those are the step-up sweeps landing on the step
  instead of the riser.
- No `error:` or `disabled after` lines in `UE4SS.log` across both runs.
- Measurement artefact to expect: the probe divides a portion's 4.7-unit move by the real 4.7 ms frame,
  so its `speed` column reads ~1000 on a portion frame while `vel` stays 143. Nothing moves at 1000; the
  lizard is simply getting a 30 FPS frame's worth of movement in one short frame.
