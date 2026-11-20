# Frozen Altars: the roof lasers kill enemies too fast (Spyro 3, LS321)

Reported 2026-11-19: "Heat lasers in the Frozen Altars kills enemies way too fast." Fixed and verified the same
day (`fixes/rooflaser.lua`, `FIX_ROOF_LASER`).

## Cause

`BP_LS321_RoofLaser_C` (4 in the level, operated by Spyro) traces its beam in `ReceiveTick` and, on every tick
the trace hits one of its targets, calls the target's `OnReceiveLaserTowerDamage` once. No `DeltaSeconds`
involved. The targets count calls:

| target | per call | dies at | while not lasered |
|---|---|---|---|
| `BP_CES3352_HotCoalRhynoc_C`, `BP_CES3353_TinyMammoth_C`, `BP_CES3354_ClubberRhynoc_C` | `LaserDamage += 1` | 30 | own tick: `LaserDamage -= 1` per tick |
| `BP_CES3054_Snowman_C` | `CurrentModelScale -= 0.01` | scale < 0.25 (75 calls) | `Melt_Grow` state |
| `BP_LS321_IceWall_C` | `BeingLasered = true` | | own tick: `LaserDamage += 1` per tick while lasered |

Each tick also spawns a muzzle emitter and a ground-burn emitter. The laser's aiming is the one part tuned for
frame time (`DeltaSeconds × 30`).

## Measurement

Laser 0 switched on (`LaserActive`) from `eval`, its `AimPoint` (a `TargetPoint`) put on the target every frame,
Spyro next to the target (far actors tick every 0.1 s, see `bamboo-barrels.md`). Of the 20 targets, only one is in
laser 0's line of sight: `BP_CES3354_ClubberRhynocMoby98…` (the others are behind level geometry, which the
beam then reports as its hit).

| | first hit to LaserDamage 30 |
|---|---|
| 30 FPS (2 runs) | 0.80, 0.97 s |
| ~300 FPS, unfixed | 0.121 s |
| ~280 FPS, fixed | 0.968 s |

Only one fixed run: every repeat needs a fresh level, the probe's `reload` crashed the game once here (an access
violation inside PhysX while the sublevels streamed out), and a restart costs a minute.

## Fix

While frames are shorter than 1/30 s, the lasers and their targets get an actor tick interval of 1/30 s
(`SetActorTickInterval`), so their Blueprint `ReceiveTick` (trace, hit calls, emitters, recovery, melting) runs as
often as at 30 FPS, with the accumulated `DeltaSeconds`. Their movement and animation are other components and
keep ticking every frame. The visible cost: the beam's end point is set in the laser's tick, so it follows the aim
30 times a second. Frames of 1/30 s or longer get the interval the fix set taken back off.

The game puts near actors back to interval 0 (and far ones to 0.1), so the fix looks again at the lasers every frame
and at the targets 4 per frame; an interval above 1/30 (a far actor's 0.1) is left alone. The lasers are found by a
`FindAllOf` once their Blueprint class loads (`lookup.watch`, a few tries 60 frames apart), the targets through
`NotifyOnNewObject(PhasmidCharacter)`, and the targets are only touched while a laser exists, since some of their
classes appear in other levels.

Not checked: how a laser operated by the player (rather than switched on from Lua) feels with the 30 Hz beam end.
