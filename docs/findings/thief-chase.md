# Gnorc thief chase speed (measured 2026-09-15 14:49–14:55 in Magic Crafters, trace `thieves_20260915_144907.csv`)

- **The circular thief (`BP_CES1011_ThiefBlue2_1409`) runs ~2% faster at 144 FPS:** average speed while MaxWalkSpeed is 700 is 698.4 at 144 FPS (14.3 s) vs 684.3 at 30 FPS (19.6 s).
  - Cause: every ~3.05 s it reaches a flee destination and goes Flee → Idle (one frame, mode NavWalking) → Flee. The Idle frame moves normally, but the next frame moves only part of a step and the frame after that doesn't move at all. Both run at MovementMode Custom 6.
  - That costs ~1.5 frames of travel per cycle: 36–47 units at 30 FPS (≈0.05–0.07 s), ~5.5 at 144 FPS (≈0.008 s). Predicted average speeds are 688 and 698.2.
- **Long flee paths match (Town Square, 2026-09-15 15:06–15:09, `thieves_20260915_150651.csv`, `BP_CES1011_ThiefBlue_202`).** Its FleeDestination leg is ~1780 units in a straight line. With Spyro chasing close (~260–270 away), the leg took 7.79 and 7.83 s at 144 FPS (avg speed 382.2, 379.8) and 7.80 s at 30 (381.0).
  - The thief moves at ~0.76 of MaxWalkSpeed at both rates, because of path curves and changing MaxWalkSpeed.
  - The only zero-speed frames are the 1-frame stalls when a flee state starts (Alert → Flee, Idle → FleeOrigin), with no mid-path stalls.
  - So the per-restart loss only matters for thieves whose loop is made of many short flee paths, like the Magic Crafters circular thief (a restart every ~3 s). Not worth a fix for now.
- Things that match across framerates:
  - The MaxWalkSpeed ramp at chase start is identical, e.g. 605.6 vs 607.1 at chaseTime 1 s and 690.7 vs 691.1 at 3 s.
  - Acceleration is 2047 at both (MaxAcceleration 2048, far above the quantization step).
  - Top speed is 700 at both.
- Instance overrides: the circular thief's desired distance starts at ~700 and shrinks ~13/s. `BP_CES1011_ThiefBlue_785` starts at ~420 and shrinks ~75/s.
- Predicted laughs: 4 at 30 FPS vs 1 at 144 FPS (that one during a super charge at speed 861).

Static findings:

- Spyro 1 egg thieves (`CES1011_ThiefBlue/Blueprints/BP_CES1011_ThiefBlue`, plus `BP_CES1045_ThiefGreen`, `BP_CES1045_ThiefRed`, `BP_CES1157_ThiefPurple`) have a `ChaseSpeedManager` component (`CES1011_ThiefBlue/Blueprints/ChaseSpeedManager`). S2 thieves (plane, kangaroo, Arabian) reference the same one, and S3 thieves use a copy, `CES3033_RedThief/Blueprints/ChaseSpeedManager_S3`. Movement is `PhasmidCharacterMovementComponent` driven by `FalconEnemyStateComponent` flee states.
- Class defaults: InitialDesiredDistance 300, FinalDesiredDistance 120, DistanceShiftTime 40, MinSpeed 290, MaxSpeed 700, AccelerationFactor 0.7, SpeedResetDistance 1000.
- Tick while `ChaseIsOn`: ChaseTime += dt. CurrentDesiredDistance = max(lerp(300, 120, ChaseTime/40), 120). DesiredSpeed = MapRangeClamped(CurrentDesiredDistance − GetDistanceTo(Spyro), −50..50 → 290..700), so close = fast. **MaxWalkSpeed = Lerp(MaxWalkSpeed, DesiredSpeed, dt·0.7)**, and MaxFlySpeed and MaxSwimSpeed are copied from it. That lerp keeps (1 − 0.7·dt) per frame, which is 0.708/s at 30 FPS vs 0.702/s at 144, so it is nearly framerate-independent.
- While `PreChase`, a chase starts (`Begin Chase`) and the chase time resets once Spyro is > 1000 away on X or Y.
- It laughs (`Haha`: PrintString + AkEvent, 3 s cooldown, no speed effect) when Spyro's horizontal speed dropped by > 150 since the manager's previous tick. That check is per frame, so it fires far more often at 30 FPS (braking from a charge loses ~250 per frame at 30 FPS vs ~50 at 144).
- Thief velocity is subject to the same float32 position quantization as Spyro (levels far from the origin), so acceleration from a standstill may be distorted at high FPS. Top speed should follow MaxWalkSpeed.
- Probe: `thief` lines and `thieves_<timestamp>.csv` (see `docs/probe.md`).

