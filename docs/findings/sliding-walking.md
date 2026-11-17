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


## Walking off from rest turns differently above 30 FPS (level replay, 2026-11-16; measured, not fixed)

Found by replaying 30 FPS takes uncapped (~250 FPS) with `tools/replay.lua`. The stick and camera are identical at every timestamp in both runs, so this is the game, not the harness (`docs/probe.md`, level replay).

- **How ground input becomes a direction** (`CharacterInputComponent_Spyro`, `RequestGroundMovement`, Ubergraph 29530-32320):
  - **Below 0.75 x MaxWalkSpeed (201 u/s)**, or when not moving forward: `AddMovementInput(Normal(fwd*sign(Y) + right*sign(X)), |(X, Y)|)`. The direction is snapped to **8 ways by the signs of the stick axes**, so an X of -0.048 under a Y of 0.9 aims the push at a full 45 deg diagonal.
  - **Above it**, moving forward with the stick within ~105 deg of his facing: `MoveAlongActorForwardVector`, which turns his facing toward the true stick angle with `RInterpTo` at speed 5.
- **The difference: the branch is decided once per frame.** At 30 FPS a frame that starts below 201 pushes toward the snapped diagonal for a whole 33 ms. Uncapped, the switch to the smooth branch comes within ~4 ms of crossing 201.
  - Take `LS102_20261116_233040` f165-166 (a gamepad take, stick (-0.048, 0.895) after a start from rest): both runs turn -25 deg on f165. The 30 FPS recording starts f166 at 190.8 u/s, still under the threshold, and turns another -20 deg to 132.9. The uncapped run was at 200.9 and turned back, ending f166 at 153.6.
  - Result: 14 deg apart within one frame. 1.6 s later the uncapped run lands a jump 30 units away, past an edge, and the takes part for good.
- **A smaller contributor: forward input lags half a frame at 30 FPS.** A frame consumes |(x_k, y_(k-1))| + |(x_k, y_k)| (the X event fires before Y), so half of the forward push uses last frame's Y. On an analog ramp from rest the uncapped run is ~9 u/s faster for the first few frames (f159: 17.8 vs 11.0), which is also why it reaches 201 sooner.
- **Other facing differences of 3-9 deg** in the same takes appear wherever Spyro stops, turns in place or slows out of a charge: the same low-speed branch, entered and left on different frames. Speeds, acceleration, charge speed and jump arcs all match (below).
- **What matches uncapped** (four LS102 takes, 7-21 s each):
  - Walking acceleration and top speed are identical (1000 u/s^2 from rest, 268.5), and braking agrees to about a unit.
  - Charge speed: 458.5 at both.
  - Jumps: the probe's `rise` tracker gave apex +84.68 uncapped against +84.64 at 30, with 0.263 s gravity-off hold.
  - A walking-only take (`223337`) stays within 5 units over 9.7 s, with facing ~1 deg off after turns.
- **Not done:** whether the snap is worth fixing (it is the console's behaviour, so the target is to make high FPS do it too), and a minimal take that reproduces it without a charge first. A fix would have to hold the slow branch for whole 1/30 s windows, or evaluate the 201 threshold on 30 FPS boundaries.
