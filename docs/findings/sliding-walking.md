# High-framerate sliding bug

Above ~80 FPS, Spyro keeps sliding at a constant low speed after a short step. The cause was confirmed with probe traces (steady 144 FPS vs 60 FPS):

- Levels sit far from the origin (e.g. x≈-301,800, y≈-299,500), where float32 positions have 1/32 unit spacing.
- UE 4.19 `PhysWalking` resets `Velocity = (location change) / dt` after every move, so velocity is quantized to multiples of (1/32)/dt: 4.5 at 144 FPS, 1.875 at 60.
- Braking is stock `ApplyVelocityBraking`, fitted from traces as friction 16.0 and deceleration 100 (speed drop per second = 16·speed + 100). At high FPS one frame's braking is less than half a quantization step, so the rounded move restores the old speed, e.g. stuck at (−9, −9) forever. At 60 FPS braking always exceeds half a step, so he stops in 9 frames. The threshold is where deceleration < (1/32)/(2·dt²), about 80 FPS at this spacing.
- Frame pacing is not the cause: frame times were a steady 6.9–7.4 ms. The "uncapped + VSync" workaround just holds a 60 Hz display at 60 FPS.
- Fix: `ue4ss/Mods/HighFpsSlidingAndJumpFix` (always on). While walking with zero acceleration, it tracks the unquantized braked velocity using the engine formula. It writes that value back when the engine's value differs only by quantization, and never when a real collision changed it.
- **The same quantization also distorts acceleration** (found 2026-09-14 11:47, trace `build/probe/charge_fix_mk.csv`). At 144 FPS a frame's 1000·dt = 6.94 lands on multiples of 4.5 per axis, so speed climbs in "lanes" of +4.5 (648/s) or +9 (1297/s) depending on heading and position. One charge start averaged ~870/s; 30 FPS gains exactly 33.3 per frame (1000/s). Top speeds are unaffected (running 268.5, charge 458.5 at both), but pickup differs ("feels like he runs faster" at 30).
  - Fix: `fixWalkingVelocity` (toggle `FIX_WALKING_ACCELERATION`) generalizes the braking fix to the full 4.19 `CalcVelocity` for walking. That covers the analog modifier and max input speed, braking when over max, the friction direction blend, and adding acceleration with the clamp. Standing still seeds tracking at zero, so the first move is predicted. With the flag off, only braking is fixed, as before.
  - **Verified 2026-09-14 12:10–12:13** (trace `build/probe/fix_verify_mk.csv`), with no errors in `UE4SS.log`:
    - Charges from standstill reach 400 speed (`t400`) in 0.400–0.405 s at 144 FPS, 0.400–0.410 at 60 (one 0.431, a blocked run) and 0.402 at 30. The ideal is 0.400.
    - Charge speedMax is 458.5 at 144 FPS (it was 461+ from quantization overshoot).
    - Stops after running are still normal: `drift` lines of 0.10–0.19 s.
  - Swimming/flying (PhysFlying also resets velocity from displacement) are not covered.
- **Stuck from a standstill at high FPS (reported 2026-09-16 at 320 FPS: Spyro turns but doesn't move; fixed and verified at 320 FPS).** The first frame's move from rest is MaxAcceleration·dt² per unit of heading: 0.048 at 144 FPS but 0.0098 at 320. That's under half the 1/32 spacing, so it rounds to 0 and velocity resets to 0 every frame. With full input it starts at ~253 FPS; with partial stick it happens at lower rates (e.g. 30% stick at ~140 FPS). Whether the unmodded game does it too is untested (the player suspects it may not have, so it isn't listed in the READMEs or Nexus description). `fixWalkingVelocity` returned early at zero velocity to save engine calls, so it never predicted from rest. Now it returns early only when acceleration is also zero.

