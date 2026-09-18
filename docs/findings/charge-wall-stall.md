# Charge stalls against walls at high FPS (fixed and verified 2026-09-18)

Reported: charging along or into a wall at a shallow angle, Spyro sometimes gets "stuck" and barely moves forward. At 30 FPS he slides right past the same spot.

## Measurements

**Quicksave repro** (trace `trace_20260918_014507.csv`, LS204, charges 272–279, fix mod on):
- Every uncapped charge (~330 FPS) from the spot stalled 4–11 times along the same ~15-unit line. The first stall came within 1 unit of the spot.
- On each stall frame, position didn't change at all (x/y identical to the float) and velocity dropped to exactly 0, from 40–166. That repeated about every 10 frames. Between stalls the walking fix rebuilt the velocity from 0 (+3/frame), Spyro crept 1–2 lattice steps (1/32), and the next stall reset it. `t400` was 1.6–1.8 s or never, against the ideal 0.40.
- At 30 FPS (charges 276, 277) from the same spot there were no stalls, and t400 was 0.43 s.
- During the uncapped stalls z crept up (576.25 → 576.53 in steps of ~0.05, with floorDist going negative), while at 30 FPS it stayed 576.25. That matches the step-ups seen below along a sloped wall.
- Yaw turned from 149° to 126° over the stall stretch, against 145° to 135° at 30 FPS, with the stick at 0.

**Hits** (probe `trackers/hits.lua`, a `ReceiveHit` hook on `BP_Base_Playable`; `hits_20260918_022047.csv`):
- After a restart, LS204 streamed in at a different offset (y −300000 instead of +300000), and **the original spot stopped reproducing it** (4 uncapped charges, t400 0.44–0.45 s). The stalls still happened elsewhere against steep walls (charges 25, 26, 44).
- Every stall was against `SM_LS204_Collision_TFB_2` faces with normal ≈ (±0.536, ∓0.773, 0.34). That's a 70° non-walkable slope, touched about 12 units below the capsule centre.
- A stall frame has 3 blocking hits, all with `Time` 0, `TraceStart` equal to the position and no penetration. That's the move, then the step-up/slide attempts, all blocked at the start, so the displacement is 0 and PhysWalking sets Velocity = displacement/dt = 0.
- Charge 44 slid along that wall at ~220 speed with a hit every frame (T 0–0.84, sweep ≈ 0.7 units). Acceleration pointed 540–600 of its 1000 into the wall (facing ~35° into it). Then one frame blocked completely: 226 → 0.
- The component of the per-frame displacement into the wall jittered ±0.02–0.09 units. That jitter is the 1/32 position lattice at ~300000 from the origin, and it's comparable to the whole frame's move at this framerate.
- Swept distances get rounded as well: with velocity (0.9, 0.4)·20 at 320 FPS the recorded sweep was (0.0625, 0), about 25° off the requested direction.
- **Comparison** (same session, wall hits with nz < 0.7):

  | | wall hits | hits with T = 0 | mean sweep | wall-contact frames with no movement |
  |---|---|---|---|---|
  | 30 FPS | 84 | 14% | 10.8 | 0 of 70 |
  | uncapped | 1100 | 18% | 0.84 | 23 of 990 (2.3%) |

  Fully blocked first hits happen at both rates. At 30 FPS the slide that follows still covers most of a ~15-unit move. Uncapped, the ~0.7-unit slide is itself blocked at T = 0 on some frames, so the frame moves nothing and velocity resets.

**Second session** (`trace_20260918_023556.csv`, `hits_20260918_023556.csv`, 320 → 30 → 320 FPS, charges 1–29):
- Frames touching a wall (hit normal z < 0.7): **0 of 150 frozen at 30 FPS, 272 of 777 frozen uncapped.**
- At 30 FPS, charges 26 and 27 crossed two of the uncapped stall spots without slowing. The pole and the charge-29 wall below weren't visited at 30 FPS.
- **Charge 29, a complete lock:** at (−297642, −298101) against a near-vertical wall (normal (0.998, 0.042, 0.051)), 218 of 224 frames (0.8 s) had no movement at all, with 675 of 676 wall hits at Time 0.
  - The acceleration pointed along the wall (its component along the wall normal was between −0.22 and +0.21), and the stick swept left and right.
  - Speed cycled 0 → 3.3 → 6.7 → 0. That's the walking fix adding 1000·dt per frame, until its prediction (~10) exceeded the quantization tolerance ((1/32)/dt ≈ 10.4) next to the engine's 0, at which point it adopted the engine's 0 again. So the speed never got above ~7, which is 0.02 units per frame, and every such move was blocked.
  - He only escaped once he turned to face away from the wall (acceleration 36% away from it).
- **Charge 29, the pole:** the same run ended hitting `AbilityGate_Superjump2/Pole_L` (normal (−0.98, −0.07, 0.18)), dropping from 458 to 30. He then crawled along the pole at 10–56 for 0.7 s, with 97 of its 110 hits at Time 0.

## Cause

This is float32 position quantization again (see `sliding-walking.md`), meeting collision.
- Near a wall, each frame's move and slide are only ~0.7 units at 330 FPS. Their end points are rounded to the 1/32 lattice, which moves the capsule toward or away from the wall by an amount comparable to the move itself, and bends short sweeps by several degrees.
- Some frames that leaves the capsule in contact, with the move and the slide both pointing slightly into the face. Every sweep then blocks at Time 0.
- PhysWalking turns the zero displacement into zero velocity. From 0, a 330 FPS move is a lattice step or two, so the next contact blocks again. That's the sawtooth "stuck" state, which only ends when the facing turns far enough from the wall.
- It can become a full lock (charge 29). The walking fix rebuilds speed from 0, but it gives up as soon as its prediction exceeds one quantization step (≈10/s) next to the engine's 0. That caps the speed at ~7, or 0.02 units per frame, and moves that short are always blocked against the wall. At 30 FPS the first move from rest is already 1000·dt² = 1.1 units.
- At 30 FPS the same rounding is ~0.1% of a 15-unit move, so a frame never ends up with no displacement.

Whether a spot reproduces it depends on the exact lattice alignment. That's why it needs "the exact right angle", and why it went away when the level streamed in at another offset: the level's collision vertices get transformed to different world coordinates, which shifts the wall relative to the lattice.

## Open questions and fix ideas

- The original spot's hits weren't captured (it stopped reproducing), so its wall is inferred from the identical symptoms.
- The walking fix (`fixes/walking.lua`) doesn't cause the stall, since the engine produces the zero velocity. It does shape the recovery: it rebuilds velocity from 0 at 1000·dt per frame. Without it, Spyro couldn't restart at all above ~250 FPS (stuck from standstill).
- It also writes back its predicted velocity whenever the engine's value is within one quantization step (≈10/s at 330 FPS). So up to ~10/s of velocity that the wall removed can be restored into the wall. That's small next to the 540–600 of acceleration into the wall, but untested.
- The lock is the walking fix's tolerance meeting the blocked frames. A fix probably belongs in `fixes/walking.lua`: a frame with zero displacement against a wall shouldn't reset the tracked velocity.
- Fix idea: on a walking frame where the engine reports zero displacement while the predicted velocity is large and input acceleration is nonzero, keep the predicted velocity projected onto the wall plane (what 30 FPS ends up with after sliding) instead of 0. That needs the hit normal, from a `ReceiveHit` hook or a short sweep, and a check that a head-on stop still stops.

## Fix (2026-09-18)

`FIX_WALL_SLIDE` in `fixes/walking.lua`:
- A `ReceiveHit` hook on `BP_Base_Playable` records the 2D normals of Spyro's own blocking hits with normal z < 0.7, up to 8 per frame.
- Above 30 FPS, on a walking frame with wall hits, the fix takes the predicted velocity and removes its component into each wall. If that still points into an earlier wall, it's a corner and the result is 0.
- It writes that projection whenever the engine's velocity is slower than it, or within the quantization tolerance of it. Otherwise it keeps the old behaviour and follows the engine.
- 30 FPS is unchanged. To verify: the probe's `chargestall` lines and the frozen-frame share of wall-contact frames (hits CSV + trace), at the charge-29 wall (−297642, −298101) and the `AbilityGate_Superjump2` pole. Also check that charging head-on into a wall still stops him.

**Verified 2026-09-18 02:53–02:55** (`trace_20260918_025318.csv`, `hits_20260918_025318.csv`): 320 → 30 → 320 → 30 FPS. The hook registered and there were no errors.
- Frames touching a wall, on the ground:

  | | before (`023556`) | after (`025318`) |
  |---|---|---|
  | 30 FPS | 150 frames, 0 frozen, 0 under speed 20 | 266 frames, 0 frozen, 1 under speed 20 |
  | uncapped | 781 frames, 275 frozen, 308 under speed 20 | 1213 frames, 17 frozen, 0 under speed 20 |

  The 17 remaining frozen frames are single blocked moves. The velocity survives them, so the next frame moves on.
- Every `chargestall` line now has nonzero displacement. None has the old "moved 0, speed → 0".
- The charge-29 wall at uncapped: charges 1 and 5 slid along it at 252–458 (min speed). The pole: charges 1 and 3 passed at 353–458.
- Head-on still stops like 30 FPS. At the charge-29 wall, uncapped charge 38 went 458 → 38 and 30 FPS charge 46 went 306 → 22.
