# Bamboo Terrace: rolling boulders and barrels spin too fast (Spyro 3, LS314)

Reported 2026-11-19: "The boulders and barrels in Bentley's section in Bamboo Terrace are spinning too fast."
Fixed and verified the same day (`fixes/barrelspin.lua`, `FIX_BARREL_SPIN`).

## Cause

`BP_LS314_DestructibleBarrel_C` (the barrels from `BP_BarrelSpawner`) spins a rolling barrel in its
`ReceiveTick` with a fixed step per tick:

```
ExecuteUbergraph_BP_LS314_DestructibleBarrel(629):   (ReceiveTick)
    DeltaT = DeltaSeconds
    if Rolling: Capsule.K2_AddLocalRotation(RotationAxis)       RotationAxis default (P=0, Y=10, R=0)
```

`BP_LS314_PandaRock_C` (the panda boulders, `AimedRockRollTrigger` rolls them) is a subclass and does not
override `ReceiveTick`. The class it derives from, the Spyro 1 Dockworkers' `BP_Barrel_Base`, scales its own
spin by `DeltaSeconds`; only this level's subclass replaced it with the per-tick step. Its path movement is
fine (`Displace` by `DeltaSeconds × 300`). Its facing turn toward the next target point (`Rotate`: `RLerp(…, 0.5)`
per tick) is per frame too, but only changes how quickly the barrel's heading settles; left alone.

## Measurement

`PandaRock1`, `Rolling` set and its tick switched on from `eval`, capsule relative yaw summed over 2 s:

| | 30 FPS | ~318 FPS |
|---|---|---|
| Spyro 2000+ units away | 98–103 deg/s | 100 deg/s |
| Spyro beside it | 300 deg/s (10.0 deg/frame) | 3184 deg/s (10.0 deg/frame) |
| beside it, with the fix | 300 deg/s | 300 deg/s (two runs, ~280–290 FPS) |

**The far rows are a trap.** The game gives far actors a 0.1 s tick interval (`GetActorTickInterval` 0.100 on all
11 rocks with Spyro away, 0.000 with him near), so a far barrel spins 10 deg per 0.1 s at any framerate. A first
measurement taken from across the level showed no difference at all.

## Fix

A hook on `BP_LS314_DestructibleBarrel_C:ReceiveTick` (one hook covers the rocks too). The hook runs after the
body, so it adds `RotationAxis × (dt × 30 − 1)` with `K2_AddLocalRotation`, making the tick's total
`RotationAxis × dt × 30`. `dt` is the tick's own `DeltaSeconds`, so a far actor's 0.1 s ticks (≥ 1/30) are left
alone. `RotationAxis` is single-axis on every instance, so scaling it is exact.
