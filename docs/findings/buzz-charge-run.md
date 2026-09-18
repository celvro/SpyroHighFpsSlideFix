# Buzz runs in place (Spyro 3 boss)

Reported 2026-09-18: at high FPS Buzz starts his running attack animation but usually doesn't move.

## Blueprint

`chunk1\Plugins\Characters\Boss\CBS3002_Buzz\Content\Blueprints\BP_CBS3002_Buzz2.uasset` (plus the subclass `BP_CBS3002_Buzz2_LS326`, which overrides `ReceiveTick`).

- The running attack is the `ChargeRun` state: `MovementMode SeekPlayer`, montage `AM_CBS3002_Charge_Run`. It moves on to `ChargeAttack` after 2 s, to `Taunt` when `IsBossOutsideAndLeaving` or `IsMovingAwayFromPlayer` is true, and to `ChargeKnockback` on damage.
- The state-change delegate turns on `PhasmidCharacterMovement.bEnableCarMovement` (native) for `ChargeRun`, `RollAttack` and `RollRetreat`. `UpdateTurnRates` (every tick) sets `CarTurningRate`/`RotationRate` to 270–720 from the distance to the arena centre. Nothing in the Blueprint is per frame.
- Movement component: MaxAcceleration 2048, MaxWalkSpeed 600, GroundFriction 8, BrakingDecelerationWalking 2048. `Acceleration` stays 0 during car movement.

## Car movement model

Each frame the current Velocity turns with the body (the yaw change) and gains MaxAcceleration·dt along the facing, capped at MaxWalkSpeed. At 30 FPS the speed goes up by 68.3 per frame (2048/30) to 600, and the velocity's direction matches the yaw within 0.3°, even while turning 9° per frame. Both speed and direction come from the current `Velocity`, so rounding locks them. A first move rounded to pure +Y stayed at (0, 10) for 0.7 s at 320 FPS while he faced 46°: (0, 10) + 6.4 along 46° = (4.6, 14.6) moves 0.014 in X (rounds to 0) and back to one step in Y. The first version of the fix modelled velocity as speed × facing, so it saw that frame as a real change and never wrote (the 297-unit run below).

## Cause

This is the same position rounding as Spyro's stuck-from-standstill bug (`sliding-walking.md`). The arena is at about (−299,700, −299,800), where positions are stored in 1/32-unit steps, and walking resets Velocity to (displacement / dt) after every move.

- The first move from rest is 2048·dt²: 0.0063 at 1.76 ms frames (570 FPS) and 0.020 at 320 FPS. Once split across X and Y by his heading, the parts are often under half a step (1/64), so the move rounds to 0 and Velocity goes back to 0.
- A hitch gets him moving. For example, a 3.9 ms frame at 570 FPS moved exactly 0.03125. After that, each move rounds to one step and his speed locks near (1/32)/dt, about 16, until the next hitch.

## Measurements (probe `trackers/buzz.lua`, `buzz_20260918_152905.csv`, 2026-09-18 15:29–15:31)

| cap | runs | first move | distance per run (2 s) |
|---|---|---|---|
| uncapped (460–550 FPS) | 6 | 0.15–0.54 s (76–262 frames stuck) | 237–744 (runs cut short: 0.95 s → 237) |
| 320 | 7 | frame 2, except one that never moved (0.35 s, 112 frames) | 292, 934, and one that crawled 36 in 2 s |
| 30 | 3 | frame 2 | 983–1102 |

First fix (speed only), 2026-09-18 15:36–15:39 (`buzz_20260918_153621.csv`): RollAttack 3242–3278 in 5.5 s at 320 FPS vs 3246–3278 at 30. Four ChargeRuns at 320 went 812–1126, but one crawled 297 because of the direction lock above.

## Fix

`fixes/buzz.lua` (`FIX_BUZZ_CHARGE_RUN`) hooks `ReceiveTick` of both Buzz Blueprints. While car movement is on and he is walking or nav-walking, it keeps his unrounded velocity using the model above. It writes it back when the engine's velocity differs only by rounding (per axis within `quantizationTolerance`, as the walking fix does). Otherwise it follows the engine, for example after a wall or a hit. Frames of 1/30 s or longer are left alone.

ChargeRun moves in NavWalking (mode 2); the rolls use Walking (mode 1). The second version handled Walking only, so it fixed the rolls but never ran for ChargeRun (no stint log lines for it). The 15:44–15:45 ChargeRuns at 320 (635–1129, one with a 0.124 s stall) were the unfixed game. The fix now accepts both modes.

**Verified 2026-09-18 15:47–15:49 at 320 FPS** (`buzz_20260918_154702.csv`, no errors in `UE4SS.log`): all 11 ChargeRuns moved on frame 2. The long ones covered 972–1081 in 1.77–1.95 s (a run ends early once he's within 60 of Spyro), about 550 units/s, which matches 30 FPS. The fix wrote on 98–100% of frames. One run stopped for 0.13 s about 80 units from Spyro, going from 600 to 0 in one frame. That's a collision, and the fix correctly followed the engine. At 30 FPS it wrote nothing. Rolls already worked with the first version.

The fix logs one line per stretch of tracking (`car movement Xs (N frames), braking Ys (M frames), W written, F followed the engine`) and skips stretches where it did nothing.

## Sliding after rolls (reported 2026-09-18 after the fix above)

When RollRetreat ends, car movement switches off and he brakes normally with no input. Braking is stock CalcVelocity with friction 16 (GroundFriction 8 × BrakingFrictionFactor 2) and deceleration 2048. At 30 FPS that takes him from 395 to 154 to 24 to 0 in three frames, which the walking fix's `calcWalkingVelocity` reproduces. A frame's braking is at least 2048·dt. It no longer changes the rounded move once that drops below half a step, (1/64)/dt, which happens above about 360 FPS. At 320 FPS the game's own braking stopped him in 0.084–0.091 s (four stops in the 15:36–15:46 sessions, which only changed car movement), against 0.133 s (4 frames) at 30 FPS. With the fix off uncapped (16:06–16:08, `buzz_20260918_160530.csv`, 420–470 FPS), four post-roll stops took 0.417, 0.115, 1.286 and 0.082 s (the last one at a 79 FPS hitch). In the 1.286 s one his velocity locked at two steps per frame in Y (about 30 speed) and he crept 35 units. So the unmodded game slides too, but little enough that the player didn't notice it. The fix now carries its unrounded velocity from the car movement into this braking. The braking prediction runs only while he walks with zero acceleration, no requested velocity and no root motion, and it stops once he stops.

**Verified 2026-09-18 15:59–16:00, whole fight uncapped (420–500 FPS), no errors:** every post-roll stop took 0.08–0.09 s, with the fix writing on all but one frame of each, and the player saw no sliding. Rolls covered 2955–3300 in 5.5 s (3246–3278 at 30 FPS), and running attacks started on frame 1–2.

## Performance (2026-09-18 15:53–15:56, `PROFILE`, no probe)

The hook is timed with `profiler.wrapHook`, because hook callbacks run outside the timed tick. In 10 s windows during the fight (uncapped, 1.5–1.9 ms frames), it cost 0.011–0.042 ms per frame (0.6–2.3% of a frame) and 0.013–0.043 ms per call. Most window maxima were 0.2–4.8 ms, with one of 11.3 ms, in line with the Lua GC spikes in `docs/ue4ss.md`. The whole tick's fixes averaged 0.10–0.18 ms in the same windows. With Buzz absent (15:55:54 onwards) the hook line is gone.
