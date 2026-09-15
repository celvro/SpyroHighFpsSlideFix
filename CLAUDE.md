# SpyroFpsFixes

Mods for **Spyro Reignited Trilogy** (PC/Steam), built on **Unreal Engine 4.19**. Internal project name is `Falcon`.

## Game install

- Game root: `C:\Program Files (x86)\Steam\steamapps\common\Spyro Reignited Trilogy`
- Executable: `Falcon\Binaries\Win64\Spyro-Win64-Shipping.exe` (launched through `Spyro.exe`)
- Paks: `Falcon\Content\Paks\pakchunk{0,1,2}-WindowsNoEditor.pak`
  - Pak **version 4**, **unencrypted** index
- Mod paks go in `Falcon\Content\Paks\~mods\` and are named `*_P.pak` so they take priority over retail paks
- User config (overrides pak config): `%LOCALAPPDATA%\Falcon\Saved\Config\WindowsNoEditor\` (`Engine.ini`, `GameUserSettings.ini`, …)

## Unpacked reference content (read-only)

Unpacked into `Falcon\Content\Paks\chunk0|chunk1|chunk2`. Each folder is relative to its pak's mount point, so paths differ:

| Folder | Mount point        | Top-level dirs      | Files  |
|--------|--------------------|---------------------|--------|
| chunk0 | `../../../`        | `Engine/`, `Falcon/` | 58,539 |
| chunk1 | `../../../Falcon/` | `Content/`, `Plugins/` | 99,043 |
| chunk2 | `../../../Falcon/` | `Content/`, `Plugins/` | 31,623 |

So `chunk1\Plugins\Levels\...` is the game path `Falcon/Plugins/Levels/...`. Never modify these folders.

Notable locations:
- Project config: `chunk0\Falcon\Config\` (`DefaultEngine.ini`, `DefaultGame.ini`, `DefaultInput.ini`, `DefaultDeviceProfiles.ini`, `Windows\WindowsEngine.ini`, `ConsoleVariables.ini`)
- Game content is split into plugins under `Falcon/Plugins/` (`Characters`, `Levels` e.g. `LS101_ArtisansHome`, `GameplayCommon`, `UserInterface`, `Sound`, …)
- Audio is Wwise (`.bnk`/`.wem`)

## Framerate-related findings

- `Falcon/Config/ConsoleVariables.ini` has `[Startup] t.MaxFPS=30`
- `DefaultEngine.ini`: `bUseFixedFrameRate=True`, `FixedFrameRate=30`, `bSmoothFrameRate=False`, `SmoothedFrameRateRange` 22–62
- `Windows/WindowsEngine.ini` overrides this for PC: `bUseFixedFrameRate=False`, `FixedFrameRate=60`, `bSmoothFrameRate=True`
- `DefaultGameUserSettings.ini`: `FrameRateLimit=0`, `bUseVSync=False`

## Jump / glide framerate bug research

Symptom: Spyro reaches ledges at 30 FPS that he can't reach at 60+ (jump height and/or glide distance).

- Movement component is native `PhasmidCharacterMovementComponent` (`/Script/Phasmid`, in the exe). Spyro's blueprint (`CPS1999_Spyro/Content/Blueprints/BP_CPS1999_Playable`) doesn't override `MaxSimulationTimeStep`, so it's the engine default 0.05 and there's no substepping at 30 or 60 FPS.
- Movement values come from gameplay attributes initialized by `CharacterCommon/Content/Data/SpyroCharacterInitialDataTable` (Spyro row: `JumpZVelocity=209`, `JumpMaxHoldTime=0.233`, `GravityScale=0.77`, `GlideDescentMultiplier=-0.31`, `AirControl=1`). World gravity is -980.
- `GA_Spyro_Jump` (Blueprint): `SetupJumpEffects` applies `GE_SpyroJumpNoGravity` (GravityScale overridden to 0 for a duration equal to the `JumpMaxHoldTime` attribute) and copies `JumpMaxHoldTime` to the Character. It then runs the native `PhasmidTask_JumpWithConfirm` and calls `Character.Jump()`. Releasing the button (`OnJumpStop`) removes the no-gravity effect and calls `StopJumping` (skipped while `Character.Enable.NoJumpStop` is set).
- `GA_Spyro_Glide` only sets an initial glide velocity. Glide motion itself is native.
- Neither ability has per-tick Blueprint logic, so the framerate dependence is most likely in native movement code. The no-gravity effect's expiry is also rounded to a frame boundary.
- **Probe heights before 2026-09-13 21:10 are biased.** Old `seg` apex/landDz/horiz values were measured from the first *airborne* frame, which already rose one frame (6.97 units at 30 FPS, 1.45 at 144). That hid the jump bug. Probe and `tools/Compare-Segments.ps1` now measure from the last grounded frame.
- **Confirmed jump height bug.** Every GE_SpyroJumpNoGravity jump (ground, water, charge) peaks higher at 30 FPS. Full-hold ground or water jump: +84.64 at 30 FPS vs +79.74 at 144. Trace `build/probe/water.csv`.
  - Mechanism, from per-frame traces: with the button held to timeout, gravity stays off for ceil(H/dt) frames plus usually 1 frame of lag. That's 8 frames (0.2667 s, 55.73 units) at 30 FPS and 35 frames (0.2431 s, 50.80 units) at 144. Apex = zero-gravity rise + 209²/(2·754.6) = 28.94; that sum matches the measured apex exactly. A few jumps show 0 lag frames (7 frames at 30, 34 at 144).
  - Early release: gravity stays off exactly for the held frames (no extra frame), so the release rounds up to the frame grid.
  - Fix in `HighFpsSlidingAndJumpFix`: track the zero-gravity rise and, when the engine restores gravity, compute the 30 FPS rise: timeout → (ceil(H·30) + lag)/30, release → ceil((rise − dt/2)·30)/30. Keep `GravityScale = 0` until then, then fold the sub-frame leftover into Z velocity (vz'² = vz² + 2·g·vz·leftover) so the apex matches exactly. A replay over recorded traces showed no extension at 30 FPS and +3 frames for 144 FPS full holds. **Verified in game (2026-09-13 21:23):** full-hold standing jump apex was +84.68 at 144 FPS with the fix (×3), +84.64 at 30 FPS, and +79.74 at 144 FPS without it. Charge jump apex was +74.58 at 144 FPS with the fix vs +74.50 at 30 FPS, and 68.7–70.4 without it. The fix made no changes at 30 FPS.
- Glides: in straight-glide tests the glide phase itself (speed 367.8, descent −114) is identical at 30 and 144 FPS. Glide distance differences come from takeoff height (the jump bug above) and glide start timing. Canyon long-glide comparisons using the old biased probe numbers were inconclusive.
- **Hover at the end of a glide is affected too, and the fix covers it** (probe `rise` lines, 2026-09-14). A hover launches at vz 160 with `JumpMaxHoldTime` 0.150; `GE_SpyroHover` changes the attributes and the Character property follows. Gravity stays off 0.2000 s at 30 FPS (6 frames = ceil(0.15·30) + 1) vs 0.160 s at 144 FPS without the fix (23 frames). Apex: +48.91 at 30 FPS, **+42.5 at 144 FPS without the fix** (6.4 units lower, a bigger gap than for jumps), +48.96 at 144 FPS with it (×3 each).
- Same session: ground jumps +84.64 at 30 FPS, +84.68 with the fix, +79.7 without it. Some air/double jumps show the 0-lag variant (34 frames, +75.4), which the fix correctly leaves alone.
- Still untested: landing on ledge edges (the Steam "slips off" report may be the slide bug).
- The probe's `rise kind` classifier (Flying with average vz < −50 → glide-hover) sometimes labels a normal jump `glide-hover`. Real hovers are the ones with vz0=160 and jumpMaxHoldTime=0.150.
- The probe treats swimming as airborne, because surface swimming uses MovementMode Flying (5) like gliding. Water jumps therefore don't get their own `seg` lines; find them in the CSV as mode 5 → 3 with vz > 0.
- Never shrink `MaxSimulationTimeStep` below a frame for experiments. Substeps reproduce the high-FPS sliding bug even at 30 FPS, and the braking fix doesn't account for substeps.

**Target behaviour: every framerate must match 30 FPS** (the console tuning). Some glide distances are impossible otherwise, so a fix that makes 30 FPS behave like high FPS is wrong.

## High-framerate sliding bug

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

## Charge turning / camera bug (confirmed; slip, mouse steering and camera centering fixes verified)

Reported at high FPS: the camera swings in behind Spyro more slowly during a charge, and he seems to turn less sharply. Measured 2026-09-14 11:05 at 144 and 30 FPS (trace `build/probe/charge_turn.csv`). Both effects are real but modest, and each matches a per-frame discretization model exactly:

- **Spyro's turn rate and radius do not depend on framerate.** Full-lock yaw rate is 130.5–130.8°/s at both 30 and 144 (= 21.8°·RotationInterpSpeed 6, because the RInterpTo step is linear in dt). Velocity yaw rate is 129–131°/s and radius 201–204 at speed 458.5.
- **Velocity lags his facing more at high FPS:** slip is +9.35–9.41° at 30 vs +12.06–12.50° at 144. That matches the engine's per-frame `CalcVelocity` friction blend, which keeps (1 − 8·dt) of the lag, followed by MaxAcceleration 1000 along the facing, which keeps (1 − (1000/458.5)·dt). Steady lag is ω·dt·R/(1−R) with R the product of both: 9.27° at 30 and 12.09° at 144. The path heading is therefore about 3° (≈0.02 s) behind at 144, which is the "doesn't turn as sharp" feel.
- **Camera yaw centering is `FInterpTo` toward Spyro's yaw at speed 3.5 (m_ctrInterp),** with a 180°/s cap (camRateMax 180 on large offsets).
  - Steady trail in a full-lock turn is ω·dt·(1−f)/f with f = 3.5·dt: predicted 33.0° at 30 and 36.5° at 144, measured camLagEnd 33.0 and 36.5.
  - Recentering from small offsets: t50 0.186–0.187 s at 30 vs 0.196 s at 144. As exponential speeds, k50 3.71–3.73 vs 3.54, matching −ln(1−3.5·dt)/dt = 3.72 vs 3.54.
  - Large offsets (140–174°) hit the 180°/s cap and take the same time per degree at both rates (t90 ≈ 0.005 s/°).
- The trace also checked out: `input_dt` equals frame dt, and `follow_cam_yaw` and `ctrl_yaw` both equal the PlayerCameraManager yaw.
- One speed parameter can't match both steady lag and decay exactly, because 30 FPS behaves like the high-FPS limit plus a partial-frame delay. The choice is to match the **steady lag** during turns. For the camera, that means ~3.86 at 144 FPS (matching decay would need ~3.67).
- **Slip fix, verified 2026-09-14 11:46 with a controller:** `fixChargeTurnSlip` in `HighFpsSlidingAndJumpFix` (toggle `FIX_CHARGE_TURN_SLIP`).
  - It runs while walking, when dt < 1/30, MaxWalkSpeed ≥ 350, speed ≥ 50 and `IGetIsCharging` is true.
  - It sets `GroundFriction` so the steady lag w·dt·R/(1−R) equals the 30 FPS value, using R = (1 − F·dt)/(1 + MaxAcceleration·dt/speed). That gives 8 → 10.67 at 144 FPS.
  - When the charge ends it restores the base value, and it adopts any outside change to GroundFriction as the new base.
  - It is only safe during a charge: acceleration is always nonzero there, so braking (and the slide fix's braking friction) isn't involved.
  - The write sticks (the game doesn't overwrite GroundFriction per frame): `turn` lines at 144 FPS showed groundFriction 10.67 and slip 9.43–10.34 (one short turn 11.97), vs 12.06–12.50 before. At 30 FPS it stayed 8.00 with slip 9.31–9.46. The remaining spread was velocity quantization. With the walking velocity fix (12:10 session), slip is 9.38–9.46 at 144 FPS (friction 10.67), 9.35–9.46 at 60 (friction 9.50) and 9.38–9.44 at 30. Camera trail at 60 FPS is 34.6–35.2°, matching the FInterpTo prediction of 35.2.
- Normal running turns use the same engine blend, so they likely have the same framerate dependence (untested). Their input is a step change rather than a ramp, which would favour matching decay instead of lag.
- **Mouse charge steering (confirmed, fix verified 2026-09-14 12:10).** Charge frames were binned by mouse speed (raw mouse X summed over the trailing 1/30 s, per second). With the fix, yaw rate matches across 30/60/144 FPS and the model: 36–42 raw/s → 152/132/142°/s (model 147), 48–54 → 181/180/180 (185), and the 210°/s cap from ~60 raw/s at all rates. Mouse steering turns sharper than a controller by design at every framerate: cap 6·atan(0.7) = 210°/s vs full stick lock 6·atan(0.4) = 131°/s.
- Mouse steering details: `InputAxisRightStickX` holds the raw per-frame mouse X, in multiples of 0.1155. Per frame, yaw rate is 6·atan(min(0.5·rx, 1)·0.7) at **both** framerates: 13.9°/s at rx 0.116, 120 at 1.04, capped at 209.9 from rx ≈ 2. So charge_sensitivity is 0.5, charge_modifier 0.7, and the cap is 6·35°. The same hand movement split over 4.8× more frames turns Spyro much less at 144 FPS; fast flicks hit the 210°/s cap either way.
  - Mouse camera look is fine: 1.0° of camera yaw per unit rx at 30 and 144, outside charges.
  - The Blueprint's `UpdateRightStickCameraRotation` would scale rx·DeltaSeconds·100, but that isn't what mouse look uses.
  - The mouse branch is chosen by `IsKeyboardMouseAndUsingMouseCheckingXAxis`: input source 1 (KBM), not console, |LX| == 0, and global `use_old_keyboard_mouse_config` ≠ 0 or missing.
  - Fix: `FIX_MOUSE_CHARGE_STEERING` registers a hook (retried until the Blueprint loads) as both pre and post callback on `CharacterInputComponent_Spyro_C:InputAxis_RightStick_X`. It records one raw sample per frame. While charging (walking or falling, MaxWalkSpeed ≥ 350, since charge jumps set 358) with that predicate true and dt < 1/30, it replaces the stored `InputAxisRightStickX` with the sum of raw mouse X over the last 1/30 s (a sliding window, the oldest frame weighted partially), but only once the stored value equals the raw one. The probe's `mouse_raw` column (its own hook) and the `charge` line's `yawPerMouse` verify it: 30 FPS and fixed 144 should match for similar slow sweeps.
- Camera: `camdump` (2026-09-14 11:46) shows the active settings are **top-level properties of `FollowCameraComponent`** (`pawn.FollowCamera.m_ctrInterp` etc.). Idle → charge diff: m_ctrInterp 5 → 3.5, m_ctrInterpV 0.15 → 4, m_ctrAngleV 0 → −7, m_rotSpeedV 90 → 30, m_rotInterpV.X 15 → 5, m_radDefault 370 → 375, m_radDefaultAtLimit −1 → 375, m_gmblOffset.X 225 → 250, m_clampZSoft.X −25 → −10, m_clampZHard (−150, 25) → (−20, 0), m_posZInterp (13, ·, 450) → (5, ·, 600), m_traceToCeiling false → true. A few tiny garbage floats (e.g. 7e-43) are misread non-float fields. Other dumped values: `m_ctrSpeed` 180 (the measured 180°/s centering cap), `m_numFramesSmooth`/`m_numFramesSmoothPan` 15 (frame-count smoothing, probably of look/pan-ahead, which are 0 here), and `ActiveCamAcceleration`/`Deceleration` 500/100000. There is no transition-state property.
- **Camera centering fix, verified 2026-09-14 12:22–12:25** (trace `build/probe/camera_fix.csv`): `fixCameraCentering` (toggle `FIX_CAMERA_CENTERING`).
  - Above 30 FPS it sets `pawn.FollowCamera.m_ctrInterp` to the lag-matched speed 1/((1+X)·dt) with X = (1−kT)/(kT)·(T/dt), T = 1/30. That gives 3.5 → 3.86 and 5 → 5.76 at 144 FPS.
  - It remembers the base value and the value it wrote, keyed by component address. When the value changes under it (a settings push/pop), it calls `IsTransitioning()`. While that's true it doesn't write, so a current-based blend can't compound; afterwards it adopts the new base. At ≤ 30 FPS it restores the base.
  - A pawn without `FollowCamera` is skipped. Also, `IGetIsCharging` errors now count as not charging instead of disabling the charge fixes.
  - Results:
    - A 6.8 s full-lock charge turn at 144 FPS ended with camLagEnd 33.0 at ctrInterp 3.856, the same as 30 FPS (was 36.5).
    - Recentering after a turn at 144 FPS: k50 3.91–4.03 vs 3.72 at 30. This is the expected lag-match trade-off, about 5% faster.
- **Camera settings transitions** (probe `camtransition` lines):
  - Duration doesn't depend on framerate: charge start (push, `Vector(10,1,500)`) takes 0.900 s at 30 FPS and 0.916–0.920 at 144; charge end (pop, `Vector(5,1,500)`) takes 1.833 vs 1.840–1.842. The earlier 1.5–2.5 s samples were overlapping pushes and pops.
  - m_ctrInterp follows a critically damped blend, remaining fraction ≈ (1+ωt)·e^(−ωt) with ω = the vector's X (10 push, 5 pop). 144 FPS matches the continuous curve; 30 FPS converges a little faster (push remaining 0.199 at 0.27 s vs 0.260 at 144).
  - A transition starts from the current value, so at 144 FPS it starts from the fix's raised value (5.76 or 3.856).
  - Simulating a camera yaw gap closing with the recorded values (FInterpTo, rate cap ignored):
    - After charge start: t50/t90 = 0.132/0.521 s at 30 FPS, 0.125/0.519 at 144 with the current fix, 0.144/0.563 at 144 unfixed. Also scaling inside transitions would give 0.124/0.491, overshooting.
    - During charge-end transitions: 144 with the fix is ~6–7% slower than 30 FPS (t90 0.467 vs 0.440 for a gap opening 0.5 s in). Scaling inside transitions would be 6–7% faster.
  - So skipping transitions is kept. It is within the same ±7% as the lag/decay trade-off, and it avoids the unknown risk of a current-based blend compounding. Whether the blend reads captured endpoints or the current value was not tested.
- **Stuck charge camera (unresolved, reported again 2026-09-14 21:25: "failed to lock behind me while charging up a hill").** In `camera_fix.csv` (144 FPS, fix on, charge starting at t=98.81, x≈−300800, y≈−300450):
  - Spyro started the charge climbing a slope (z 21 → 41, floorNz 0.988), steering full left with stick_y dropping to 0.
  - Before the charge, walking with a 35° offset, the camera rate was 0.
  - The charge-start transition began, and the rate ramped −92.8 → −123.6°/s over 14 frames, then froze at exactly −123.6 for 1874 frames (13 s). Meanwhile Spyro turned steadily at 130.8, so the offset grew linearly from 33° to 128° (0.05°/frame). The rate snapped to 0 on the frame the charge ended.
  - During the freeze: transitioning true for 1.4 s, then false; m_ctrInterp blended 5.13 → 3.50, then the fix wrote 3.856; stick_rx and mouse were 0; pitch −4.35.
  - A normal centering rate would respond to the growing offset (FInterpTo, capped at 180), so the camera's rotation looks latched, not centering. Every other constant-rate run in four traces is the camera matching Spyro at 130.8 in steady turns.
  - Both occurrences had the camera fix on, and whether the fix contributes is unknown. The transition started from the fix's raised idle value (5.76, not 5).
  - The probe now has a `camstuck` detector: offset ≥ 45° and grew ≥ 5° over 1 s, with |camRate| between 1 and 170 while charging. It logs position, rates, ctrInterp, transitioning, floor and sticks, and dumps `camdump_*_stuck.txt` diffed against the normal charge dump. Replaying it over the four traces flags only this episode.
  - **Not reproduced 2026-09-14 21:35–21:47** (trace `trace_20260914_213531.csv`, fix on): 488 charges (324 at ~144 FPS, 59 of them > 1 s; 164 at ~30), including 212 charges with frames on floors with nz < 0.97 at 144. There were no camstuck detections, no un-steered charge frames that stayed ≥ 20° off Spyro for 1 s, and no frozen camera rates (the only constant-rate runs were normal recentering at the 180 cap).
  - The detector now also has `kind=noLock`: offset ≥ 20° with no steering (stick, mouse, or Spyro yaw rate > 30°/s) and still > 70% of it left after 1 s. The frozen-rate hypothesis allows the camera to freeze at rate 0, which leaves a constant gap the "growing" check misses. Replayed over the five traces it has 0 hits; before the yaw-rate condition, a mouse turn at the 210 cap in `charge_fix_mk.csv`, which has no mouse column, was a false positive.
  - Next: keep the probe deployed during normal play so the next occurrence dumps the camera state automatically; then compare with `FIX_CAMERA_CENTERING = false` at that spot.

- Charge steering is Blueprint, in `CharacterCommon/Content/Components/CharacterInputComponent/CharacterInputComponent_Spyro` (a component on `BP_Controller_Player`, property `CharacterInputComponent_Spyro`). `UpdateGroundChargeMovement` normally (when `FollowCameraStatics.CameraCannotCenter` is false) calls `MoveAlongActorForwardVector(InputX = 0.4·|x|⁴·sign(x), InputY = 1, RotationInterpSpeed, actor rotation)`. Here x is `InputAxisLeftStickX` (`MultiplyMultiply_FloatFloat` is a power). That function takes target yaw = actor yaw + DegAtan2(InputX, 1) (at most 21.8°) and calls `RInterpTo(actor yaw, target, DeltaSeconds, RotationInterpSpeed)`. Its forward vector goes through `DoChargeSpecificMovementChecks` (geo compensation, tolerance 0.75) into `AddMovementInput`. Per frame, the input direction therefore leads Spyro by 21.8°·min(6·dt, 1).
- For keyboard/mouse with the mouse steering, `GetChargeMovementValueOnPC` replaces InputX with min(|charge_sensitivity·InputAxisRightStickX|, 1)·sign·charge_modifier. The mouse axis is a per-frame delta (confirmed above).
- Charge attributes: `GE_Spyro_Movement_Charging` overrides MaxWalkSpeed 458.5, MaxAcceleration 1000, and RotationRateYaw 720. From `SpyroCharacterInitialDataTable`: RotationInterpSpeed 6, GroundFriction 8. `IGetIsCharging` on the pawn checks the `Character.MoveState.Charging` tag.
- Charge camera: `GA_Spyro_Charge` pushes `FollowCameraSettings` via `PushCameraSettingsWithTransition(Vector(10, 1, 500))` with m_gmblOffset (250, 0, 75), m_radDefault 375, m_rotSpeedV 30, m_ctrInterp 3.5, m_ctrInterpV 4, m_ctrAngleV −7. The underwater version uses m_radDefault 135 and m_ctrInterp 3. On end it pops them with Vector(5, 1, 500). Its activation adds `Camera.Follow.Center.VerticalRotation`. The centering itself is native `FollowCameraComponent` (`/Script/Phasmid`, `pawn.FollowCamera`), which has frame-count properties `m_numFramesSmooth` / `m_numFramesSmoothPan` plus `ActiveCamAcceleration`/`ActiveCamDeceleration`, `m_ctrSpeed`, and `m_maxCtrDelta`, all suspects.
- Native reflection names (properties, functions, enum values) are plain strings in `Spyro-Win64-Shipping.exe`. `grep -abo "[[:print:]]\{4,\}"` finds them, and neighbouring strings usually belong to the same class.

## Charge dust bug (found 2026-09-14 from assets; second fix verified in game 2026-09-14 20:25)

Reported: the dust behind a ground charge only shows at 30 FPS, and none appears at 60+.

- `BP_CPS1999_Playable` `ReceiveTick` → `Charge_Update` → `Charge_UpdateGroundEffects(IGetIsCharging)` runs **every frame**.
  - If IsCharging and `MovementModeCur == 1` and not `Character.MoveState.SuperCharging`: it deactivates `Charge_GroundEffects` (if valid) and `SpawnEmitterAttached`s a new effect into it. That's `PS_VFX_Spyro_Charge_DustTrail`, or `PS_VFX_Spyro_Splash_CleanWater_Shallow_Charge` when the floor PhysMat SurfaceType is 9.
  - Otherwise it only deactivates it. There is no gate, so each effect emits during exactly one tick.
- `PS_VFX_Spyro_Charge_DustTrail` emitters that matter: `Dust_L_Initial` and `Dust_R_Initial` (spawn rate curve 60 → 20 over t 0–1, duration 0.75, lifetime 0.3–0.5).
  - `Dust_*_Loop` (rate 100–130) have EmitterDelay 0.5, so they never start under per-frame respawn. The mesh emitters are disabled.
  - A fresh effect spawns floor(R·dt) particles per emitter in its only tick: (60 − 40·dt)·dt = 1.956 → 1 per side at 30 FPS, 0.989 → 0 at 60, 0.41 → 0 at 144.
  - Traced 30 FPS frame times are 33.3 ms in 37,675 of 37,853 frames (only 21 frames long enough for 2 particles), so 30 FPS is effectively 1 puff per side per frame.
- Other dust uses are fine: `GA_Spyro_SlideDown` and `GA_Spyro_Damage_SlideBack` spawn the dust trail once. `CheckGroundForDustEffect` (hover ground dust) spawns once and then moves the effect.
- **First fix failed (tested 2026-09-14 12:48–12:50).** It hooked `Charge_UpdateGroundEffects` pre and post, hid respawns from the Blueprint until 1/30 s had passed (`Charge_GroundEffects = nil`, `MovementModeCur = 0`) and dilated each new effect.
  - The hook registered and logged no errors, but no dust appeared at 144 FPS.
  - Probe at 144 FPS: `dustRate` 143.5–144/s and `dustDilationMax` 1.00, so it never hid a respawn or dilated an effect. At 30 FPS: 30.0/s.
  - Cause, confirmed by the second fix's debug counts: with this UE4SS build, only the "pre" callback of a Blueprint function hook runs, and it runs **after** the function body. The post callback never fires. That was true for both `Charge_UpdateGroundEffects` (called from Blueprint bytecode) and `ReceiveTick` (called through ProcessEvent). So the first fix's "pre" saw the new effect as already present and never tracked it.
- **Second fix** (`FIX_CHARGE_DUST`), which doesn't depend on callback order or hiding anything:
  - Hook: one callback, registered as both pre and post, on `Charge_UpdateGroundEffects`. The test build also hooked `ReceiveTick`, but `Charge_UpdateGroundEffects` always handled the effect first, so that hook was removed.
  - Which effect it acts on: only an effect whose address differs from both its address at frame start (read in the EngineTick loop) and the last effect it handled. That means an effect the Blueprint spawned this frame, seen by a callback that ran after the Blueprint body.
  - Time scale:
    - Above 30 FPS, the first effect of a charge, and then one every 1/30 s, gets `CustomTimeDilation` (1/30)/dt, so its only tick emits like a 30 FPS frame.
    - The effects in between get 1e-3, so they emit nothing. 0 is avoided in case the engine divides by the scaled dt.
    - The first callback of the next frame resets them to 1. The EngineTick loop also resets them if callbacks stop.
  - The Blueprint still respawns every frame, as in the unmodified game.
  - Probe `charge` lines report `dustSpawns`, `dustRate` (≈ FPS either way), `dustEmitRate` (effects with dilation ≥ 0.5 per grounded second: ≈ FPS unfixed, ≈ 30 fixed) and `dustDilationMax` (≈ 4.8 at 144 when fixed).
  - **Verified 2026-09-14 20:25–20:30** (trace `trace_20260914_202538.csv` in the game dir):
    - The dust shows at 144 FPS. `CustomTimeDilation` does scale the particle tick.
    - All 35 charges were at 144 FPS: `dustRate` 142.6–144/s, `dustEmitRate` 27.4–32.4/s (29.3–30.7 for charges > 1 s), `dustDilationMax` 4.80. No errors in `UE4SS.log`.
    - A temporary debug build counted callbacks: 144 `pre` calls/s per hook, 0 post calls, and every `pre` call already saw the new effect while charging. That debug logging was then removed.
    - Charges with `dustSpawns=0` were fully airborne (charge jumps, mode 3, MaxWalkSpeed 358) or swimming (mode 5). The Blueprint spawns ground dust only while walking.
    - 30 FPS with this build was not part of that session's log. The fix does nothing when dt ≥ 1/30.

## Green druid Energize bug (cause confirmed 2026-09-14 20:46–20:48; fix verified 21:09)

Reported: at 144 FPS the green druids (wizards) in Alpine Ridge (`LS114_AlpineRidge`) don't activate the stairs or the moving door.

- **Cause** (probe session 20:46–20:48, uncapped vs 30 FPS, `UE4SS.log`): `AM_CES1035_GreenDruid_Casting_Up` is 0.5 s long with the default 0.25 s blend-out. The druid's cast state ends (MontageDone) on the frame the position reaches 0.25, and the next state's montage interrupts it, so later notifies never fire. Its Energize notify is at **0.25089** (TriggerTimeOffset 0, EndTriggerTimeOffset 0.0001). It fires only if that last frame steps past 0.25089.
  - 30 FPS: the state ends after 0.267 s (0.233 → 0.267), and the mechanism toggles every time.
  - Uncapped (144): the state ends after 0.250–0.251 s from 0.243, and the mechanism never toggles (~20 casts). The only exceptions were frame hitches (state ended after 0.252–0.256 s).
  - `Casting_Out` (the Down cast, 0.5 s) has its notify at 0.24986 and toggles at every framerate. Right (2.0 s, notify 0.301) and Left (1.667 s, 0.508) are unaffected.
  - The druid flips `isObjectCurrently Right/Down instead of Left/Up?` only inside the notify handler, so after one missed Up cast it repeats Up forever and the mechanism is stuck. Affected: `GreenDruid2` (stairs), `GreenDruid3` (slow door `_487`) and `GreenDruid4` (walkway `2_302`). The theatric door druid (TheatricCast lasts 1.5 s), the triple stairs and the moving block (Left/Right) are not.
- Ruled out: the `preventChange?` / OnPlayerReady gate below. All mechanisms cleared it about 2.5 s after load.
- **Fix** `FIX_DRUID_ENERGIZE` in `HighFpsSlidingAndJumpFix`: every 60 frames it `StaticFindObject`s the Casting_Up montage, which only the LS113/114/115/118 level assets reference, so it only exists on those levels. It then sets the Energize notify's `TriggerTimeOffset` so its trigger time (LinkValue + offset) is 0.24986, the same as Casting_Out. It checks that LinkValue is the expected 0.25089 and reads the offset back, and is idempotent, so it re-patches after a level reload. Nothing changes at 30 FPS (the same frame crosses it).
- First fix test (21:04–21:06) is invalid: an edit had merged `local HOOK_RETRY_FRAMES = 60` into a comment, so the fix errored (`attempt to compare number with nil`) and never patched (probe `trigger=0.25089`). The same session reconfirms the cause, and the probe's notify hook fired for each toggle. Up casts toggled only with `lastPos=0.249` (frame hitch) and never with 0.243–0.244. The stairs looked like they "failed after interrupting the cast", but that failed cast wasn't interrupted.
- **Verified 2026-09-14 21:09** (uncapped): the log showed `druid Energize notify moved to 0.24986 s`, and the probe read back offset −0.00103 with trigger 0.24986. All 78 Up/Down casts by druids 2, 3 and 4 fired the notify exactly once, including Up casts ending from `lastPos` 0.243. The stairs, door and walkway kept alternating.
- UE4SS: `RegisterHook` on these Blueprint functions (`NotifyGreenDruid`, mechanism `Energize` and player-ready events) failed with `UFunction::Func: 0x0` when first found, as the level loaded. With retries (up to 200) all of them registered once the level had loaded (21:04:39).

Static findings:

- Druid: `CES1035_GreenDruid/Blueprints/BP_CES1035_GreenDruid`, a state machine of native `FalconEnemyStateComponent`s. `TriggerType` is a bitmask of `EFalconTriggerType`: 1 Timer, 2 DistanceLessThan, 4 DistanceGreaterThan, 8 MontageDone, 16 MoveDone, 32 CausedDamage, 64 ReceivedDamage, … 2048 CollisionVolume, 4096 CollisionVolumeExit (the order of the exe strings, consistent with the data).
- Cast loop (class defaults; the LS114 instances don't override the casting states): Idle_Stand (Timer 1 s) → Casting_PreCasting (MontageDone) → Casting_Loop (no native trigger; the Blueprint `Delay(Casting_Loop_Duration)` picks Casting_Up/Down or Left/Right) → casting state (MontageDone) → Idle_Stand. Distance < 175 to Spyro → Panic from any of them.
- For druids with `isUsingNewDruidAnims`, Energize comes from `AnimNotify_Energize` in the casting montage (e.g. at 0.508 s of the 1.667 s `AM_..._Casting_Left`) → `NotifyGreenDruid` → `ActorToManipulate.Energize()`, skipped if `115_ignoreAnimNotifyENERGIZE?`. Without that flag, it energizes on entering the Energize state instead.
- Mechanisms (instances in `LS114_Enemy.umap`):
  - `BP_114_DruidStairs_326` ← `GreenDruid2`.
  - Doors, the `BP_114_DruidSplineObject`s with `fx_ls114_opening_door`: `_487` ← `GreenDruid3` (slow) and `7_147` ← `GreenDruid6_6815` (theatric states).
  - The walkway `2_302` ← `GreenDruid4`.
  - The triple stair block `4/5/6` ← `GreenDruid_Stairs_Bottom/Middle/Top`.
  - `BP_CES1035_GreenDruid_MovingBlock_334` ← `GreenDruid_1432`.
  - Energize toggles the mechanism, and nothing in these Blueprints runs per tick except their timelines.
- Gate: DruidStairs and non-triple, non-beast SplineObjects ignore Energize while `preventChange?` is true (default true). It is only cleared by their `FalconGameStateBase.OnPlayerReady` handler, which they bind in BeginPlay, and only when `DruidRef` is valid. The triple stair block ignores the gate, and the MovingBlock has none. (Not the cause, see above.)
- The investigation used a temporary druid probe, `SpyroDruidProbe`, removed after verification and never committed. It polled druid state (`FalconEnemy:BP_GetCurrentStateName()`), the montage position (`Mesh:GetAnimInstance():GetCurrentActiveMontage()` / `Montage_GetPosition`) and mechanism Blueprint flags (`obj["preventChange?"]`) every frame, and hooked `NotifyGreenDruid`. All of these worked from Lua.

## Fire dragon segment bug (cause found 2026-09-14 from assets and disassembly; fix verified 22:31–22:34)

Reported: in the Fireworks Factory (`LS322_FireworksFactory`) dragon fight, the dragons are much harder to hit at 144 FPS, their body sections are bunched up, and they may move faster.

- Dragons: `CBS3012_FireDragon/Blueprints/BP_CBS3012_FireDragon` (head, instances `BP_CBS3012_PurpleFireDragonMoby10…` and `…RedFireDragonMoby24…` in `LS322_FireDragon_design.umap`) with `BodySegments` of `BP_CBS3012_FireDragon_Lg/Med/Sm_Segment` actors (17/2/1, `MaximumHealth` 20). The head flies native `TraverseWaypointsLooped` states along `PhasmidPatrolPath`s. Segments have no movement of their own.
- The head's `ReceiveTick` calls `UpdatePrevActors(DeltaSeconds)` (unless `bIsDead`). That raises `Mesh` by 20, calls the head's `DragonSineMovement.MoveUpdate(FMax(DeltaTime, 0.033), null)`, then for each valid segment with `IsAlive_0` calls `MoveUpdate(FMax(DeltaTime, 0.033), LastActive)` (LastActive = head, then the previous live segment), and lowers the mesh by 20. **FMax, not FMin:** at 144 FPS every frame passes 0.033.
- Native `UDragonSineMovementComponent::MoveUpdate(float Delta, AActor* Leader)` (exec thunk 0x14049F800, body 0x140450870; props bAlive 0x110, RotationZDelta 0x114, SinePhase 0x118, SineAmplitude 0x11C, SineFrequency 0x120, hidden sine offset vector 0x124):
  - Returns at once if `bAlive` is false.
  - With a leader: SinePhase += (leader.SinePhase − 0.25 − SinePhase)·2·Delta. SineAmplitude += (max(leader.SineAmplitude, 5) − SineAmplitude)·2·Delta. Target = leader root location − leader offset; base = own root location − own offset. Two lerps by 4·Delta: p1 = lerp(base, target, 4Δ), p2 = lerp(p1, target, 4Δ). Offset = (0, 0, sin((WorldTime + SinePhase)·SineFrequency)·SineAmplitude); `SetActorLocation(p2 + offset)`. If recently rendered (0.25 s), rotates its component (0xF8) towards the leader's plus RotationZDelta.
  - Without a leader (head): only the mesh bob, `SetRelativeLocationAndRotation((0,0,sin(...)·amp))`, from world time. No Delta use.
- So a segment keeps K = (1 − 4Δ)² of its distance per call and trails a steadily moving leader by dt·K/(1 − K) seconds of its speed: **0.1006 s at 30 FPS, 0.0509 at 60, 0.0212 at 144** (4.7× shorter body). Passing the true dt would give 0.1198 at 144 (the continuous limit is 0.125), so FMin alone wouldn't match 30 FPS either. Head speed, GrowCountdown, the attack trace and `GE_SuperFireImmunity` don't depend on framerate.
- Fix `FIX_DRAGON_SEGMENTS` in `HighFpsSlidingAndJumpFix`: hooks `UpdatePrevActors` (re-registered whenever the function object's address changes, since the class reloads with the level; RegisterHook failures retried up to 200 times). In the callback it keeps every live segment's `DragonSineMovement.bAlive` false, so the Blueprint's calls do nothing, and repeats the Blueprint's loop (mesh +20, `MoveUpdate(Δ', leader)` with bAlive briefly true, mesh −20). Δ' makes the steady trail match 30 FPS: K' = 0.1006/(dt + 0.1006), Δ' = (1 − √K')/4 (0.00821 at 144 FPS). For dt ≥ 1/30 (and InitializeBody's dt 0) it passes the Blueprint's max(dt, 0.033). An alive segment that still has bAlive on is new (HandleDeath clears IsAlive_0 and bAlive together) and is only taken over. After an error, segments get bAlive back.
- Trade-off like the camera fix: steady trail matches exactly; a step disturbance decays a bit faster at 144 FPS (0.726 left after 1/30 s vs 0.751).
- The exe's `.text` is SteamStub-encrypted on disk (`.bind` section). For disassembly, copy the decrypted `.text` from the running game into a copy of the exe (read-only `ReadProcessMemory`, section raw 0x600 size 0x2278800), then `dumpbin /DISASM /RANGE:...` from Visual Studio 2022. Native function pointers: find the `FNameNativePtrPair` (`{char* name, exec ptr}`) whose name pointer points at the function name string in `.rdata`; property params in `.data` list names and offsets.
- Probe `dragon` lines (per dragon, every second): fps, head speed, live and `managed` (bAlive off, i.e. taken over) segments, mean link distance (3D, horizontal, head→first), body length, and lag (link/speed, frames ≥ 100 speed) next to the 30 FPS and unfixed-at-this-framerate predictions. Links include the segments' vertical sine offsets, so lag reads a bit high on slow or turning stretches.
- **Verified 2026-09-14 22:31–22:34** (fix on, `UE4SS.log`, no errors; hook registered once when the level loaded, 22:28:42):
  - Both dragons sit idle (speed 0) until the fight starts, then fly at a constant 700.
  - `managed` equalled `segments` on every line, including segments that grew back.
  - Lag per link, lines at speed ≥ 650: 144 FPS purple 0.0902 (104 lines, 0.061–0.102), red 0.0933 (107); 30 FPS purple 0.0932 (34), red 0.0954 (33); 60 FPS 0.094–0.096 (3 each). Unfixed prediction at 144 was 0.0213.
  - Mean link 63.0/65.3 at 144 vs 65.3/66.5 at 30. Head→first segment link is 71.0 at both, i.e. 0.1006·700 = 70.4. Other links are shorter because curves cut the chord and sine offsets differ.
  - **Unfixed baseline, 2026-09-14 22:48–22:52** (`FIX_DRAGON_SEGMENTS = false`, `managed` 0 throughout): the model holds. Horizontal link averages (the 3D ones are inflated at short gaps by the ±25 vertical wave, e.g. 3D first link 22 vs horizontal ~13):

    | | purple | red | model (straight, ×700) |
    |---|---|---|---|
    | 30 FPS unfixed | 60.9 | 58.4 | 70.4 |
    | 60 FPS unfixed (2 lines each) | 31.6 | 31.3 | 36.9 |
    | 144 FPS unfixed | 13.4 | 13.2 | 14.6 |
    | 30 FPS, fix build | 62.7 | 63.9 | 70.4 |
    | 144 FPS fixed | 57.6 | 60.2 | 70.4 |

    Measured/model is ~0.85–0.91 at every rate (curves). Fixed 144 is ~95% of 30 FPS, and 4.4× the unfixed 144 gap. The first link matches 30 FPS exactly, while later links come out a few percent shorter. That may be the faster decay (0.726 vs 0.751 kept per 1/30 s) compounding along the chain on curves, or just different path stretches; it wasn't separated.
  - Regrowth is framerate-independent: a segment returns 8 s after the last hit (`GrowCountdown` reset to 8), then every 11 s, at both 144 and 30 FPS. The player said the dragons "seemed like the regen at a normal pace now", and things looked normal.
  - **Profiled 2026-09-14 22:56–23:01** (`PROFILE = true`, fix on, uncapped/VSync, `UE4SS.log`, no errors): during the dragon fight (12 windows, avg frame 6.94–7.07 ms, ~143.7 FPS) fixes averaged 0.287 ms/frame (4.1% of frame). After the fight ended the level's frame time dropped to 2.5–2.7 ms (~385 FPS, no VSync cap) but the fixes' absolute cost barely changed, 0.235 ms/frame average (9.0% of the now much shorter frame) — the two dragons keep ticking (and the hook keeps running) even away from the fight, so the cost is roughly constant per frame rather than tied to combat. That's higher than the v1.1.0 baseline (0.08–0.15 ms/frame) logged above, consistent with iterating up to 40 segments across two dragons every frame.
  - Per-window max cost was 13.0–20.2 ms during the fight and 12.7–17.9 ms after, well above the v1.1.0 baseline's 0.2–4.6 ms max. Cause not isolated; possibly Lua GC from the small table literals `onDragonUpdate` allocates each call for `K2_AddRelativeLocation`'s vector and out-param arguments (2 calls per dragon per frame, so only 4 short-lived tables/frame — plausible but unconfirmed). Worth a follow-up: cache/reuse those tables, or profile with `FIX_DRAGON_SEGMENTS = false` to see if the spikes are already present without this fix.
  - **Table-reuse follow-up, disproven 2026-09-15 11:25–11:27.** Replaced the two `K2_AddRelativeLocation` calls' per-frame vector and out-param table literals with three tables shared at module scope (safe: Lua is single-threaded, each call finishes using them before the next starts, and the lift/lower vectors' values never change). Re-profiled the same way (fix on, dragon fight, uncapped): 17 windows, avg frame 7.06–7.56 ms (~132–142 FPS, a little more loaded than the previous session), fixes avg 0.283 ms/frame (3.9%) — statistically the same as the 0.287 ms before the change. Max per window was 12.5–25.0 ms, if anything slightly worse than the 13.0–20.2 ms before. So the 4 tables/frame were not the (or not the main) source of the spikes. More likely cause: the ~40 per-segment property reads and method calls (`segments[i]`, `.IsAlive_0`, `.DragonSineMovement`, `.bAlive`, `:MoveUpdate(...)`) each frame, which UE4SS's Lua bindings may wrap in their own allocations — much more numerous than the two AddRelativeLocation calls and not practical to eliminate without restructuring the fix. Kept the table-reuse change anyway (it's free and slightly cleaner), but stopped looking for the spike's cause: at 12–25 ms once per ~10 s window it's at most one dropped frame, small next to the visual fix.
  - **Spikes cleared of the dragon fix, 2026-09-15 11:31–11:33** (player reported drops even away from the dragon fight). Profiled with `FIX_DRAGON_SEGMENTS = false` (so the dragon hook never registers) across a Fireworks Factory stretch with dragons present, then a stretch in an ice level with no dragons at all (confirmed by the probe's `dragon` lines, which log independently of the fix, stopping at the level change). Both stretches showed the same 12–15 ms max-per-window spikes as with the fix on (avg cost 0.26–0.31 ms/frame, max 13.4–15.5 ms). So the spikes are unrelated to this fix — they happen with it off, and in a level that has no fire dragons at all. Likely one of the mod's other always-on fixes, or general Lua GC pressure across all of them (the very first v1.0.0 baseline above only saw 0.2–3 ms spikes; this is 12–15 ms after several more fixes were added since). Not investigated further; worth a dedicated profiling pass per fix if it becomes a player complaint.

## Frame spikes (cause found and fixed 2026-09-15)

Reported for 1.2.0: periodic hitches at high FPS, very visible even when idle and only turning the camera.

- **Cause: a `StaticFindObject` that finds nothing costs ~10–11 ms** (it scans the whole object array); one that finds its object costs ~0 ms. Measured 2026-09-15 12:38 (`UE4SS.log`, os.clock timing): druid montage and dragon `UpdatePrevActors` misses took 10–11 ms each; the mouse and dust hook lookups (hits) took 0.0 ms.
- 1.1.0 looked up the druid montage every 60 frames forever, on every level. 1.2.0 added the dragon function lookup on the same frame, so ~21 ms was lost every 0.4 s at 144 FPS. That was also the 12–27 ms profiler max spikes (present with or without the dragon fix, since the druid lookup always ran). GC and profiling overhead had been ruled out earlier that day (spikes unchanged with the collector fully stopped).
- First fix (at most 10 lookups after each new pawn) removed the hitches, but a slow Alpine Ridge load outlasted those lookups and the druids broke again.
- **Current fix (not yet verified in game):** nothing polls. `NotifyOnNewObject` on `/Script/Engine.BlueprintGeneratedClass` (`CharacterInputComponent_Spyro_C`, `BP_CPS1999_Playable_C`, `BP_CBS3012_FireDragon_C`) and `/Script/Engine.AnimMontage` (`AM_CES1035_GreenDruid_Casting_Up`) grants that fix 10 lookups (one per 60 frames), run from the tick; each also gets 1 lookup at startup. A found montage with no `Notifies` yet keeps retrying (found lookups are free), as does a found dragon function whose RegisterHook fails (capped at 200 failures).
- Rule: never poll `StaticFindObject` for something that may not exist.

## UE4SS (runtime Lua modding)

- UE4SS experimental build `v3.0.1-1133-gb4cefa18` is staged in `tools/bin/ue4ss-dist/` (gitignored). `tools/Install-UE4SS.ps1` installs it (`dwmapi.dll` + `ue4ss/` in `Falcon\Binaries\Win64`) and deploys `ue4ss/Mods/*` (player-facing fixes) with `enabled.txt`. `ue4ss/DevMods/*` (the probe) is deployed only with `-Probe`; without it, a previously deployed probe has its `enabled.txt` removed (its traces stay in the game dir). Use `-ModsOnly` after editing Lua, and `-Uninstall` to remove everything. The installer sets engine version 4.19, turns on the external console, and **disables hot reload**. Ctrl+R crashed this UE4SS build twice: an access violation writing 0x24 in ntdll+0xFA7D, called from UE4SS.dll's engine-tick hook right after mods reinstall. Restart the game to pick up Lua changes. Crash dumps land in `%LOCALAPPDATA%\Falcon\Saved\Crashes\*\UE4Minidump.dmp`; read them with `build/DumpInfo/DumpInfo.exe <dmp>` (source in `tools/DumpInfo`), which prints the exception and module-relative stack values.
- Profiling: set `PROFILE = true` in `HighFpsSlidingAndJumpFix/Scripts/main.lua`. Every 10 s it logs `profile: N frames (avg frame X ms), fixes avg Y ms (Z% of frame), max, clock overhead` to `UE4SS.log`. Timing uses `GameplayStatics:GetAccurateRealTime`: UE4SS fills plain out-params into the passed table under the parameter name, e.g. `seconds.Seconds`, and `os.clock` only has 1 ms resolution. This excludes UE4SS's own hook overhead; measure that externally by comparing frame times with and without `dwmapi.dll`.
- Profile baseline (v1.0.0, 144 FPS VSync, 2026-09-13): fixes avg 0.13–0.20 ms/frame (1.9–2.8% of 6.95 ms), max 0.8–2.7 ms per 10 s window, clock overhead 0.009 ms. Suspected cause: `UEHelpers.GetPlayerController()` runs `FindAllOf("PlayerController")` on every call, creating per-frame garbage. The mod now caches the controller and gameplay statics, and reads mode and velocity once per frame. After caching: running/jumping windows 0.017–0.059 ms avg, but standing still 0.107–0.113 ms, because the braking path still called GetCurrentAcceleration/IsPlayingRootMotion/K2_GetActorLocation at zero velocity. It now exits early at zero velocity. **Result (22:15 session):** 0.019–0.026 ms avg in every window, including standing still (~0.35% of a 144 FPS frame). Max per window 0.5–2.1 ms even at idle, when the tick does almost nothing, so the spikes aren't the fix logic. Jumps still +84.68. Jump apex (+84.68) and stops (≤0.17 s) were unchanged by the caching refactor. Max per window stays 0.2–3 ms, likely Lua GC or thread preemption inside the timed region.
- Profile v1.1.0 (2026-09-14 21:23–21:26, all fixes, 144 FPS VSync, normal play): fixes avg 0.08–0.15 ms/frame (1.2–2.2%), max 0.2–4.6 ms per window. Windows with loading hitches (7.2–7.6 ms average frames) peaked at 9–11 ms, and uncapped ~385 FPS windows averaged 0.03 ms. That's about 4–6× v1.0.0, and it hasn't been optimized yet. Per-frame work added since v1.0.0 includes FollowCamera/m_ctrInterp property reads and writes, the Charge_GroundEffects read, and IGetIsCharging plus the mouse predicate while MaxWalkSpeed ≥ 350.
- `GetAccurateRealTime` out-params: the first profiling attempt found `PartialSeconds` missing from its own table, so `accurateSeconds` accepts either field from either table and logs both tables if one is still missing.
- `RegisterHook` on a **Blueprint** function in this build calls only the first (pre) callback, and it runs **after** the function body; the post callback never fires (measured on `BP_CPS1999_Playable_C:Charge_UpdateGroundEffects` and `:ReceiveTick`, 2026-09-14). A hook can't act before a Blueprint function runs or change its inputs. Register the same callback as pre and post, and make it idempotent.
- UE4SS Lua is 5.4, so `math.frexp`, `math.pow` and friends don't exist. A Lua error inside a per-frame loop only logs once (the mods guard with `errorLogged`), so check `UE4SS.log` for `error:` lines before trusting a test.
- Probe `drift` lines of ~0.15–0.2 s are normal stops: braking from full speed takes ~0.17 s. Multi-second drifts are the bug.
- The first AOB scan fails because the exe is still unpacking; the second pass succeeds (EngineTick hook found). Log: `Falcon\Binaries\Win64\ue4ss\UE4SS.log`.
- `ue4ss/DevMods/SpyroFpsProbe` (deploy with `Install-UE4SS.ps1 -ModsOnly -Probe`): F5/F6/F7/F8 set `t.MaxFPS` to 30/60/120/0. On load it restores `MaxSimulationTimeStep` to 0.05 if an old build changed it. It prints a `seg` summary per airborne segment, a `drift` line for grounded sliding without input, a `rise` line for every zero-gravity rise (kind ground/water/glide-hover/air, time at launch speed, apex from the launch frame), and charge lines. Those are `charge` (per charge), `turn` (grounded full-lock steer ≥ 0.5 s: yaw rates of Spyro/velocity/camera, radius, accel angle, slip, camera lag), and `camlock` (camera closing a ≥ 10° yaw offset after charge start or turn release: t50/t90 and the equivalent exponential speeds k50/k90, to compare against m_ctrInterp 3.5). Charge detection calls `IGetIsCharging` and falls back to MaxWalkSpeed ≥ 450, and optional calls that fail log `... unavailable` once. The `charge` line also has `startSpeed`, `t400` (from the last untagged frame to 400 speed, for starts below 150), `mouseDist` (raw mouse X), `yawPerMouse`, and `dustSpawns`/`dustRate`/`dustDilationMax` (charge dust effect respawns). CSV `mouse_raw` comes from the probe's own hook on `InputAxis_RightStick_X`; `stick_rx` is the stored value, which the mouse fix replaces. `camdump_<time>_<idle|charge|manual>.txt` holds every reflected `FollowCameraComponent` property (recursing into structs and arrays). It is written once while idle, once ≥ 0.75 s into a charge after the camera transition, and on F9. After the charge dump, `camdump diff` log lines list the values that changed. Per-frame CSV goes to `ue4ss\Mods\SpyroFpsProbe\trace_*.csv` in the game dir.

## Repo layout

- `tools/Config.ps1` — shared paths (`$GameDir`, overridable with `$env:SPYRO_GAME_DIR`; `$RepoRoot`; `$BuildDir`)
- `ue4ss/Mods/HighFpsSlidingAndJumpFix` — the shipped fixes (released: braking slide + jump height; unreleased: walking acceleration, charge turn slip, mouse charge steering, camera centering, charge dust, green druid Energize, fire dragon segments), a UE4SS Lua mod published as "High FPS Sliding and Jump Fix" (`VERSION` constant in `main.lua`; player-facing `README.txt` ships in the mod folder)
- `tools/Package-Release.ps1` — builds the Nexus zip `build/release/HighFpsSlidingAndJumpFix-<VERSION>.zip`, laid out relative to the game root (`Falcon/Binaries/Win64/ue4ss/Mods/HighFpsSlidingAndJumpFix/` + `enabled.txt`, forward-slash entries, UE4SS not included). Needs a UE4SS experimental build: `LoopInGameThreadAfterFrames` was added Dec 2025 and isn't in stable v3.0.1.
- `ue4ss/DevMods/SpyroFpsProbe` — per-frame movement logger for investigating framerate bugs
- `tools/Install-UE4SS.ps1 [-ModsOnly] [-Probe] [-Uninstall]` — installs UE4SS and the Lua mods
- `tools/Compare-Segments.ps1 -Trace <csv> -Segments <ids>` — side-by-side stats for probe airborne segments
- `tools/DumpInfo/` — minidump reader for game crash dumps (build: `dotnet build tools/DumpInfo -c Release -o build/DumpInfo`)
- `tools/AssetDump/` — C# (.NET 9) reader for cooked UE 4.19 `.uasset`/`.uexp`. It prints imports, exports, tagged properties (including DataTable rows) and, with `--code`, disassembled Blueprint bytecode. Build: `dotnet build tools/AssetDump -c Release -o build/AssetDump`. Run: `build/AssetDump/AssetDump.exe <file.uasset> [--export <name>] [--no-props] [--code] [--hex]`. Cooked function exports have no object-GUID flag, and `UStruct::Children` is serialized as an array.
- `build/` — generated output (gitignored)

## Tooling

- Scripts are PowerShell. Python is not installed (the `python` on PATH is only the Microsoft Store stub).
- There is no pak build pipeline. The unused one (`tools/Build-Mod.ps1` with `mods/<ModName>/`, packing with [repak](https://github.com/trumank/repak) `--version V4 --mount-point ../../../`) was removed; restore it from commit 50c1467 if a fix ever needs an asset or config pak.
- Editing `.uasset`/`.uexp`: use UAssetGUI or FModel with the engine version set to **UE4.19**. Changed assets must stay in the cooked format; replacing a `.uasset` also means shipping its matching `.uexp` (and `.ubulk` if one exists).
