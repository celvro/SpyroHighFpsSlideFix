# Sheila stalls around Buzz's arena (Spyro 3)

Reported 2026-09-18: at high FPS, when Buzz is knocked into the lava right after a roll, Sheila is sometimes still on the far side of the arena and takes too long to reach him for the stomp.

## Blueprint

`chunk1\Plugins\Characters\Player\CPS3339_Sheila\Content\Blueprints\BP_Sheila_SP3NPC_Buzz.uasset` (parent `BP_Base_Friendly`).

- She alternates between `PatrolIdle` (FacePlayer), `PatrolMoveIn` (SeekPlayer, within 450–600 of the player) and `PatrolMoveOut` (FleeFromPlayer, 400–550).
- Buzz's burn state calls `ChangeState_SeekBurningBuzz`. `SeekBurningBuzz` (SeekPlayer towards her target) moves to `JumpOnBuzz` once `IsPositionedForBuzzJump` holds: she's within 50 and within `AngleMinSheilaAndBurningBuzz` of Buzz around the arena centre.
- The jump (`CalculateJumpToBuzzVelocity`, `SheilaJumpAboveBuzz`) turns her movement component's tick off and moves her with `K2_SetActorLocation`. It uses forward Euler at 1800 up and 980 gravity, so the apex sits about v·dt/2 higher at 30 FPS (about 30 units) than at high FPS. That's small, and not fixed.
- Movement component: MaxWalkSpeed 400, MaxAcceleration 2048, GroundFriction 8, braking 2048, RotationRate 200, `bUseAccelerationForPaths` false, `bRequestedMoveUseAcceleration` true. Her AI moves her through `RequestedVelocity` (UE 4.19 `ApplyRequestedMove`), so `Acceleration` reads 0.

## Measurements (probe `trackers/buzz.lua`, 2026-09-18 16:11–16:13, `buzz_20260918_161120.csv`)

| | 30 FPS | uncapped (400–530 FPS) |
|---|---|---|
| first move of a patrol move | 0.033 s | 0.08–0.24 s |
| time to 50% / 90% of 400 | 0.10 / 0.20 s | 0.3–0.8 / 0.4–1.1 s, or never |
| short patrol moves | 100–250 units | 5–60 units (e.g. 22.5 in 0.72 s) |
| SeekBurningBuzz | already moving, reaches Buzz in 0.7–1.0 s | once from a standstill: 0.4 units in the 0.16 s before, then 1.74 s with t90 1.13 s |

At 30 FPS her speed rises by exactly 68.3 per frame (2048/30) to 400. Uncapped she stands still with Velocity 0 until a hitch, like Buzz's ChargeRun (`buzz-charge-run.md`). The cause is the same: the arena is ~300,000 from the origin (1/32 position steps), and her first move from rest, 2048·dt², rounds to nothing.

## Fix

`fixes/sheila.lua` (`FIX_SHEILA_BUZZ_WALK`) hooks her `ReceiveTick`. While she walks (movement tick on, no root motion), it keeps her unrounded velocity with the walking fix's model. That's `calcRequestedWalkingVelocity` while her AI requests a move, otherwise input acceleration or braking. It writes that velocity back when the engine's value differs only by rounding. It logs one line per walking stretch (`walking Xs (N frames, M moving), W written, F followed the engine`) for stretches of 0.05 s or more.

First version (16:20, uncapped) gated the request on her controller's `PathFollowingComponent`, which never reports a move: her state logic calls the move request directly, aimed to reach the target in one frame (RequestedVelocity 50,000–200,000). The fix then predicted braking while she walked, braked her from 43 to 0 in 4 ms at the start of SeekBurningBuzz and held her there (the first stomp never happened), logging 2,609 one-frame stretches. In that session `RequestedVelocity` was nonzero and changed on every one of ~5,600 PatrolMoveIn/SeekBurningBuzz frames and was 0 in PatrolIdle, so the fix now treats a nonzero request that changed since last frame as live. It no longer logs stretches under 0.05 s.

**Verified 2026-09-18 16:23–16:25, uncapped (380–550 FPS), no errors in `UE4SS.log`:** every walk started on frame 1–4 (`firstMove` 0.002–0.010 s) and reached 50% / 90% of 400 in 0.10 / 0.17–0.18 s (30 FPS: 0.10 / 0.20 s). Patrol moves covered 42–2602 units with 1–4 still frames. All five stomps went through, with SeekBurningBuzz taking 0.52–1.06 s (30 FPS: 0.73–1.00 s). The fix wrote on all but about one frame of each stretch and followed the engine on none. After each jump there's a 0.08 s braking stretch (1 moving frame) as she lands.
