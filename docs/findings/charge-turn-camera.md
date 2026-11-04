# Charge turning / camera bug (confirmed; slip, mouse steering and camera centering fixes verified)

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
  - **Caught 2026-09-15 16:42** (trace copied to `build/probe/camstuck_164211.csv`, trace t 11.39–16.31 = log 16:42:31.4–36.3; `camstuck 1.1 kind=growing`, dumps `camdump_20260915_164232_{charge,stuck}.txt`). 144 FPS, fix on. The charge started at t 11.39 (transition from ctrInterp 5.76). Spyro jumped 0.24 s later, **during the transition**, off a platform (z 583 → 657 → landed 415), with stick full left the whole time, and kept charge-hopping.
    - From the charge start the camera never centered. Its rate didn't follow the offset but seemed tied to the stick: −13.8 → −17.6 while the offset grew 8 → 59°, −10.9 while stick_x was 0, then exactly −18.7 at stick −1 while the offset grew 104 → 174°.
    - When the offset wrapped past ±180 (t 13.93), the rate jumped to exactly +3.0 and stayed there through landings and jumps for 1.3 s, while the offset shrank −177 → 0 because Spyro turned. Once the offset crossed 0 (t 15.25), normal centering came back (rate ramped −25 → −129, trail ~32°). That was the "ran a full circle before it locked back on".
    - Pitch sat at −4.351 during that stretch, and transitioning was false from t 12.3.
    - The dumps show nothing unusual: charge → stuck differs only in m_ctrInterp 3.85796 → 3.85866. So the latched state isn't a reflected property. Candidates in the dump: `m_ctrDecelAngle` 20, `m_ctrDecelAngleTurnModifier` 5, `m_ctrDecelTimeMultiplier` 5, `m_ctrYawClamp` 30, `m_maxCtrDelta` 360, `m_ctrSecondTargetInterp` 1, `m_center{,Hold,Active}InterpParams`, `m_centerToHoldTime` 0.05.
    - Both catches had the charge start with something else going on (slope climb; jump during the transition) and a steady full-lock steer.
  - The player says it also happens at 30 FPS, so it's a vanilla bug. Both fixes live in the main mod anyway (player's choice).
  - **Cause, from disassembly (2026-09-15):**
    - The native FollowCameraComponent update is at VA 0x141EF54C0–0x141EF9604, with the centering block at 0x141EF6515–0x141EF6853.
    - Reflected component offsets: m_ctrInterp 0x900, m_ctrSpeed 0x904, m_ctrDecelAngle 0x908, m_ctrDecelAngleTurnModifier 0x90C, m_ctrDecelTimeMultiplier 0x910, m_maxCtrDelta 0x914, m_ctrYawClamp 0x920, m_ctrSecondTargetInterp 0x924. `tools/Find-PropertyParams.ps1` finds these.
    - Unreflected state: current yaw 0xA38 / pitch 0xA3C, target yaw 0xAB0, previous target yaw 0xAB4, "centering was active" byte 0xAA5, scale 0xC20, blend 0xAA8. `FindDeltaAngleDegrees` is at 0x140207DD0.
    - Centering has two phases.
      - **Phase A (blend 0xAA8 == 0):** on the first centering frame (0xAA5 false, no second target at 0x930), it latches scale = min(|gap|·(1/90), 1). Each frame after that, yaw += scale·(sign(gap)·m_ctrSpeed·dt + target yaw change this frame), limited to |gap|.
      - **Phase B:** when |gap| ≤ |target change this frame|·m_ctrDecelAngleTurnModifier + scale·m_ctrDecelAngle (or the step would overshoot), the blend ramps 0 → 1 at m_ctrDecelTimeMultiplier·dt from the phase A step into clamp(gap·m_ctrInterp, ±m_maxCtrDelta)·dt. It stays in phase B until centering stops, which resets 0xAA5 and 0xAA8 at 0x141EF71CA.
    - These exactly explain both catches.
      - 16:42: gap0 5.45° gives scale 0.0606. Rate = 0.0606·(−180 + Spyro's rate): −10.9 when not turning, −18.8 at −130.8 (measured −18.7), and +3.0 once the gap's sign flipped (measured +3.0).
      - 14 Sep: gap0 ~35.8° gives scale 0.398, and 0.398·(−180 − 130.8) = −123.6, the measured freeze.
    - The stuck state happens whenever Spyro turns away faster than 180·scale before the gap gets under the threshold, so it can happen at any framerate.
    - The turn term uses the **per-frame** yaw change: at full lock it's 21.8° at 30 FPS but 4.5° at 144. So at high FPS it sticks more easily, and a normal recenter switches to phase B later (a framerate difference not fixed yet).
    - A gap of exactly 0 at centering start latches scale 0 (rate 0), which only the turn term can release.
    - **Jumping doesn't matter** (nothing in the centering block reads movement mode). What matters is the gap at centering start (charge start) and the turn that follows.
      - The gap per second changes by ω·(1 − scale) − sign·180·scale.
      - Turning toward the side the camera points (gap and ω opposite) shrinks the gap through 0, where the check passes, so it can't stick.
      - Turning away from where the camera points (same sign) grows the gap if scale < ω/(ω+180): gap0 < 38° at full stick lock (131°/s), < 48° at the 210°/s mouse cap.
      - It must also miss the check on the way. Already turning at full lock at the start, the check passes immediately for gap0 ≤ turn term/(1 − 20/90): 28° at 30 FPS or with the switch fix, 5.8° at unfixed 144.
      - So it sticks when the charge starts with Spyro going straight (or turning gently) and the camera ~5–38° off to one side, then he steers hard the other way. At 30 FPS that needs the gap to get past ~22° + scale·20 while the turn ramps up, so larger starting offsets. At unfixed 144, a few degrees is enough.
      - Both catches fit: 35.8° and 5.45°, each turning away from the camera side. The 17:07 test charges started at ~0°, which can't stick.
      - Repro: angle the camera ~20–30° to the left of Spyro, start a charge straight ahead, then full lock right. Try with `FIX_STUCK_CAMERA = false` first to confirm, then on. The player couldn't reproduce it by hand (2026-09-16).
      - Probe hotkeys **J** (33° gap) and **H** (12° gap) automated it (`updateCamRepro`, removed from the probe 2026-09-17 after testing finished; restore from commit c70718b if needed):
        - Armed (up to 10 s): every frame until a charge starts, Spyro is turned to face the gap right of the camera.
        - Once charging: he is turned right at 130.8°/s for 3 s, as if steering at full lock, so press charge without the stick.
        - Logs `camrepro charge started` (gap at start) and `camrepro done` (gap and camera rate at the end). The `camstuck` detector covers the rest.
        - **Confirmed by the player 2026-09-16:** J gets stuck at both 30 and high FPS, and H only at high FPS, as predicted. The runs with all fixes on haven't been reported yet.
        - **Fixes verified 2026-09-16 12:16–12:17** (all three camera fixes on, `UE4SS.log`, no errors, no `camstuck`): 8 automated charges.
          - Before any F-key (the uncapped setting from the previous session): J from 32.5°, H from 11.8°.
          - 30 FPS: H ×2 from 11.2°, J from 30.8°.
          - Uncapped (F8): J ×2 from 32.5°.
          - Every run ended locked on, trailing 33.0–33.1° at camera rate 130.8–131.0°/s, the normal full-lock trail at 30 FPS.
          - No `stuck camera release` lines: releases fire as the gap grows past ~41°, under the 45° log cutoff. The player confirmed the camera locks on in all cases.
        - Expected: 33° should stick at every framerate without `FIX_STUCK_CAMERA`. 12° should stick only at high FPS with neither camera switch fix on. With `FIX_CAMERA_CENTERING_SWITCH` or at 30 FPS, the check passes once the turn starts.
  - **Fixes in `HighFpsSlidingAndJumpFix` (`fixCameraCenteringSwitch`, verified 2026-09-16 with the probe's J/H repro, see below):**
    - m_ctrDecelAngleTurnModifier is read only by the phase B threshold check. It is a component-only property: its params appear once, and it isn't in `FollowCameraSettings` like m_ctrDecelAngle is. So settings pushes, pops and transitions don't touch it, and any change the fix didn't make is adopted as the new base.
    - `FIX_CAMERA_CENTERING_SWITCH`: below 30 FPS frame time, the modifier is base/(30·dt) (5 → 1.04 at 144 FPS), so the turn term matches 30 FPS.
    - `FIX_STUCK_CAMERA` (also changes 30 FPS): when |Spyro yaw − control yaw| has grown `STUCK_CAMERA_GROWTH` 8° since its minimum, the modifier is set to 1e6 for one frame. That forces phase B whenever Spyro turned that frame, which he must have for the gap to grow. The minimum then resets to the current gap.
    - It logs `stuck camera release` while charging at a gap of ≥ 45° (`STUCK_CAMERA_LOG_GAP`). It was 25° at first, which logged every full-lock turn: the trail grows 24.7 → 33°, and those releases do nothing.
    - First test (2026-09-15 17:07–17:08, 144 FPS, trace `trace_20260915_170655.csv`, which cut off at t 43.45 because the game was killed after a freeze):
      - No errors. The mod loaded, and the probe logged no `camstuck` lines.
      - 6 charges jumped 0.08–0.24 s after starting, at full lock, and the camera trail topped out at 33–34° each time.
      - All of them started with a gap of ~0°, which switches to phase B immediately even without the fix. So the original stuck case (a gap of ~5° or more at centering start) wasn't reproduced yet.
    - The game froze after alt-tabbing out and back in at ~17:08:24. There was no crash dump, no Windows error event and no error in `UE4SS.log`, so the cause is unknown. The newest crash dump (16:41:07) is from the earlier flame session: an access violation reading −1 at exe+0x16EEEB3.
    - README.txt now lists the camera lock fix and says it's the one fix that also changes 30 FPS.

- Charge steering is Blueprint, in `CharacterCommon/Content/Components/CharacterInputComponent/CharacterInputComponent_Spyro` (a component on `BP_Controller_Player`, property `CharacterInputComponent_Spyro`). `UpdateGroundChargeMovement` normally (when `FollowCameraStatics.CameraCannotCenter` is false) calls `MoveAlongActorForwardVector(InputX = 0.4·|x|⁴·sign(x), InputY = 1, RotationInterpSpeed, actor rotation)`. Here x is `InputAxisLeftStickX` (`MultiplyMultiply_FloatFloat` is a power). That function takes target yaw = actor yaw + DegAtan2(InputX, 1) (at most 21.8°) and calls `RInterpTo(actor yaw, target, DeltaSeconds, RotationInterpSpeed)`. Its forward vector goes through `DoChargeSpecificMovementChecks` (geo compensation, tolerance 0.75) into `AddMovementInput`. Per frame, the input direction therefore leads Spyro by 21.8°·min(6·dt, 1).
- For keyboard/mouse with the mouse steering, `GetChargeMovementValueOnPC` replaces InputX with min(|charge_sensitivity·InputAxisRightStickX|, 1)·sign·charge_modifier. The mouse axis is a per-frame delta (confirmed above).
- Charge attributes: `GE_Spyro_Movement_Charging` overrides MaxWalkSpeed 458.5, MaxAcceleration 1000, and RotationRateYaw 720. From `SpyroCharacterInitialDataTable`: RotationInterpSpeed 6, GroundFriction 8. `IGetIsCharging` on the pawn checks the `Character.MoveState.Charging` tag.
- Charge camera: `GA_Spyro_Charge` pushes `FollowCameraSettings` via `PushCameraSettingsWithTransition(Vector(10, 1, 500))` with m_gmblOffset (250, 0, 75), m_radDefault 375, m_rotSpeedV 30, m_ctrInterp 3.5, m_ctrInterpV 4, m_ctrAngleV −7. The underwater version uses m_radDefault 135 and m_ctrInterp 3. On end it pops them with Vector(5, 1, 500). Its activation adds `Camera.Follow.Center.VerticalRotation`. The centering itself is native `FollowCameraComponent` (`/Script/Phasmid`, `pawn.FollowCamera`), which has frame-count properties `m_numFramesSmooth` / `m_numFramesSmoothPan` plus `ActiveCamAcceleration`/`ActiveCamDeceleration`, `m_ctrSpeed`, and `m_maxCtrDelta`, all suspects.
- Native reflection names (properties, functions, enum values) are plain strings in `Spyro-Win64-Shipping.exe`. `grep -abo "[[:print:]]\{4,\}"` finds them, and neighbouring strings usually belong to the same class.



## Stuck charge camera reproduced on demand (2026-10-10, probe `camera` + `charge`, `trace_20261010_142617.csv`)

Reported by the player as "charge camera is back to being slow", and by them narrowed to "fixed in Spyro 1, only happening on Spyro 2 and 3". **The per-game split is the player's observation and is still unmeasured** — see the dead end below.

The bug itself is now reproducible: 25 sustained full-lock charge turns (|yaw rate| > 150 deg/s for >= 0.5 s, longest 2.44 s) produced 9 `camstuck` episodes and 104 `stuck camera release` lines, with the camera trailing up to **99.7 deg**. Earlier runs the same day logged 25-29 releases each.

- **Mechanism, as the data shows it**: phase A turns the camera at `scale * 180` deg/s with `scale = min(|gap|/90, 1)`, which is below Spyro's ~210 deg/s charge turn, so the gap grows for as long as he keeps turning. `camstuck 9.1`: offset 24.6 -> 99.2 in 1.00 s, camRate 146.4 against spyroYawRate 210.0. `FIX_STUCK_CAMERA` fires and forces phase B, but phase B cannot close a gap while Spyro keeps out-turning it: `camstuck 9.1 ended after 0.51 s: offset 44.6 (max 99.7)`. This is the same unresolved case as the 2026-09-14 report above, now with a repro.
- **The three camera fixes are all computing their intended values**, so nothing is disabled: `m_ctrInterp` 3.910 is exactly `referenceInterpSpeed(3.5, 3.45 ms)`, and `m_ctrDecelAngleTurnModifier` 53.333 is `5 * (1/30) / 3.125 ms` from the switch fix.
- **Why 2026-09-16 looked verified**: those 8 charges all started at a gap of ~0 deg, and the releases fired under the 45 deg `STUCK_CAMERA_LOG_GAP`. The fixes were verified without the bug ever being exercised.
- **Camera settings transitions take ~33 s of the ~135 s of camera activity (~24%)**, and the centering fix deliberately stands down while one is blending. `charging=false->true` transitions run 1.4-4.1 s, and the game blends `m_ctrInterp` through the raw 3.5/5 values during them (e.g. `camtransition 1`: 5.888 -> 3.594 over 0.50 s, `end=3.910` once the fix resumes). Worth checking whether a stuck episode is more likely to start inside a transition.
- **Not the cause, ruled out by experiment**: the `util.clearHit` sweep out-param change (a run with its body commented out still logged 25 releases) and the probe itself (a run with no probe loaded logged 28).

### Dead end: the per-game comparison, and why the trace cannot support one

A first pass compared the Sunny Beach turtle run (`trace_20261010_125621.csv`) against the stress run and found the camera trailing at most 40.2 deg there, 0% of charging frames past 45 deg, against 99.7 deg and 13.4% in the stress run. **That comparison is invalid**, for two reasons:

- Sunny Beach is **LS206**, a Spyro 2 level (`chunk1/Plugins/Levels/LS206_SunnyBeach`), not Spyro 1 as first assumed. The level list is the authority here: LS1xx is Spyro 1, LS2xx Spyro 2, LS3xx Spyro 3.
- That run never exercised the bug. Its **longest sustained full-lock stretch was 0.48 s, with zero stretches >= 0.5 s** (against 25 in the stress run), and its median charging yaw rate was 11.0 deg/s against 209.1. The gap needs sustained turning to grow, so a low maximum there means nothing. The runs also differed in framerate (207 vs 275 avgFps).

The `LS206` in that session's log was only the probe's stored quicksave spot, not the level being played.

**Tooling gap: the trace has no level column**, and positions alone cannot name a level (several sit near +/-300000). `lib/levels.lua` already resolves level names, which is how the quicksave line prints `LS206`. Until a level identifier is in the row, no per-game or per-level claim can be read out of a trace.

### Per level and per framerate (2026-10-10, three-game run, `trace_20261010_145631.csv`)

With `level=` on the `camstuck`/`camlock` lines (LS1xx = Spyro 1, LS2xx = 2, LS3xx = 3), one session charging in all three games, at 30 / 120 / uncapped:

`camlock` k50 (the exponential speed that closes the gap; `m_ctrInterp` is 3.5 charging, so **30 FPS sits at k50 ~3.6** and that is the target):

| level | camlock events | k50 range | camstuck |
|---|---|---|---|
| LS101 (Spyro 1) | 3 | 3.44 - 6.46 (at 120, 258, 318 FPS) | **0** |
| LS201 (Spyro 2) | 10 | **0.28**, 1.46, 2.79, 3.01, 3.59, 3.63, 3.79, 3.80, 7.08, 9.49 | 3 |
| LS310 (Spyro 3) | 8 | **1.67**, 1.81, 3.40, 3.59, 3.65, 4.06, 4.36, 5.71 | 4 |

- **The 30 FPS reference is healthy in the affected games**: LS201 at `avgFps=30.0` gives k50 3.59, LS310 at 30.0 gives 3.65, both matching `m_ctrInterp` 3.5. So this is a pure high-framerate deviation, which is in scope for the mod.
- **The bad cases are 2-13x slower than 30 FPS**: LS201 k50 **0.28** at 291.7 FPS (a 17.5 deg gap took 2.461 s to halve) and 1.46 at 280.7; LS310 1.67 at 120 FPS (offset0 79.2) and 1.81 at 309.2. Every LS101 sample stayed at or above 3.44, including at 318 FPS with a 50.8 deg gap closing in 0.201 s.
- **`camstuck` only in LS201 and LS310, none in LS101**, which matches the player's report. **Not yet conclusive**: LS101 drew only 3 camlock events against 10 and 8, so it had roughly a third the exposure. What it does show is that a 50.8 deg gap at 318 FPS closed normally there.
- One episode (`camstuck 9.1`, LS201) started with `transitioning=true` and `ctrInterp=4.062`, i.e. inside a camera settings transition, where the centering fix deliberately stands down. Worth checking whether the slow locks cluster on transitions.
- Mechanism unchanged: `camstuck 13.1` camRate -158.5 against spyroYawRate -209.9, gap 1.3 -> 71.6 deg in 1.00 s.

**Tooling**: `level=` added to the `camstuck`, `camlock`, `charge` and `turn` lines. `trackers/camera.lua` resolves it once a second from `levels.current` (inside `updateDump`, which already has the pawn) and publishes it as `state.level`, so it costs nothing per frame and needs no change to `lib/row.lua` or the trace. With it on the `charge` and `turn` lines, the next run can show charge exposure per level directly, which is what this one could not.

### Repro: restart a charge right after stopping (2026-10-10, LS102 Stone Hill, `trace`/log 22:47–22:49)

**The bug is not Spyro 2/3 only.** Stone Hill (**LS102, Spyro 1**) produced 2 `camstuck` episodes and **118 `stuck camera release` lines**, the most of any run so far. The earlier "0 camstuck in LS101" was under-exposure (3 camlock events against 10 and 8), exactly as flagged, not a property of Spyro 1. Treat the game as irrelevant until something shows otherwise; what matters is the charge pattern.

Player's repro, confirmed in the data: **stop a charge and immediately start another, then hold a full-lock turn.** Charge starts reconstructed from the `charge` lines (start = log time - dur), with the gap from the previous charge's end:

| charge | gap before | camOffset0 | dur | camstuck |
|---|---|---|---|---|
| 1 | (cold) | -25.3 | 14.37s | - |
| 2 | 0.61s | -3.9 | 1.65s | - |
| 3 | **0.15s** | **+34.0** | 8.66s | **3.1** at t=4.01s, offset 49.2 -> 125.9 |
| 4 | 1.34s | -114.8 | 2.01s | - |
| 5 | 0.13s | +10.6 | 2.46s | - |
| 6 | **0.47s** | **+12.3** | 4.78s | **6.1** at t=4.00s, offset 27.5 -> 56.1 |
| 7 | 0.33s | -12.3 | 8.29s | - |

- **Why the restart matters**: a charge restarted inside ~0.5 s begins before the camera has finished recentering, so centering starts with a small non-zero gap and latches `scale = min(|gap|/90, 1)` tiny (gap 12.3 -> `scale` 0.137 -> 24.6 deg/s). Spyro then out-turns it at 210 deg/s. A cold start is safe either way: the gap is ~0 and the switch to phase B passes immediately, or it is >= 90 and `scale` is 1 (charge 4 started at -114.8 and did not stick).
- **But the starting offset alone does not decide it.** Two camlocks started at the same `offset0=12.3` and ended k50 **7.28** (healthy) and **0.62** (broken). The difference is whether Spyro keeps turning long enough for the gap to outrun the phase-B threshold `|gap| <= |yaw change this frame| * m_ctrDecelAngleTurnModifier + scale * m_ctrDecelAngle`. Once the gap passes it, phase A is capped at `scale * 180` and never recovers. So the precondition is the small latched scale, and the trigger is a sustained turn: **both** are needed, which is why it is intermittent.
- **`camlock` k50 this run** (30 FPS target ~3.6): 5.46 (offset0 25.3), **0.63** (34.0), 1.18 (114.8), 7.28 (12.3), **0.62** (12.3). The two bad ones took ~1.1 s to halve the gap against 0.19 s at 30 FPS, ~6x slow.
- **The camera-transition lead is dead.** Both episodes report `transitioning=false`, at t ~4.0 s into the charge, well after that charge's transition ended (every transition this run was `charging=false->true`, 1.0-2.3 s). The fix standing down during transitions is not what is going wrong. Note the quick restarts also mean no `charging=true->false` transition was ever logged — the restart interrupts it.
- The switch fix does equalise the threshold arithmetic: at 210 deg/s, 30 FPS gives `7.0 * 5 = 35`, and 300 FPS with the scaled modifier gives `0.70 * 50 = 35`. So the remaining gap is not that term, and the next thing to look at is what re-latches `scale` (when centering restarts) rather than the threshold.

### Where `scale` is latched (2026-10-10, `dumpbin /DISASM /RANGE:0x141EF5000,0x141EF7A00`)

`scale` lives at **`FollowCameraComponent + 0xC20`**, and it is latched **once per centering episode**, not per frame. That is the root cause.

```
0x141EF6621  call   0x140207DD0                ; -> xmm0 = gap (signed yaw delta)
0x141EF6626  movzx  ebx, byte ptr [rsi+0xAA5]  ; "centering already running" flag
0x141EF6632  test   bl, bl
0x141EF6634  jne    0x141EF665C                ; already running -> SKIP THE LATCH
0x141EF6636  cmp    qword ptr [rsi+0x930], 0
0x141EF663E  jne    0x141EF665C                ; second target set -> skip
0x141EF6640  movaps xmm1, xmm0
0x141EF6643  andps  xmm1, xmm14                ; |gap|      (xmm14 = 0x7FFFFFFF, abs mask)
0x141EF6647  mulss  xmm1, [0x1427ACC90]        ; x 0.01111111 = 1/90 (read from .rdata)
0x141EF664F  minss  xmm1, xmm13                ; min(.., 1.0)  (xmm13 = 1.0f @ 0x1422A73FC)
0x141EF6654  movss  [rsi+0xC20], xmm1          ; *** THE LATCH ***
```

- `[rsi+0xC20]` is written in only two places: this latch, and `0x141EF6597` which stores `1.0f` on the sibling path. It is **read in exactly one place**, `0x141EF66AB` (`movss xmm5,[rsi+0xC20]`), then multiplied into the camera turn at `0x66D7` and into the threshold term at `0x66F6`.
- `[rsi+0xAA5]` is the gate. It is set to **1** at `0x141EF684C`, at the end of the phase-A path, and cleared to 0 at `0x141EF6861` and `0x141EF71CA`. So frame 1 of an episode latches `scale`; every frame after it takes the `jne` and `scale` is frozen at the frame-1 gap.
- **The phase switch, by contrast, is re-evaluated every frame**, at `0x141EF670B`: `comiss xmm2, xmm0` / `jbe`, i.e. `|gap| <= |yawChangeThisFrame * [rsi+0x90C]| + scale * [rsi+0x908]`. By the arithmetic and the runtime camdump values, `+0x90C` is `m_ctrDecelAngleTurnModifier` (the switch fix writes it, and the dump reads back 53.333 = `5 * (1/30)/3.125 ms`) and `+0x908` is `m_ctrDecelAngle` (20). Not proven from the property params table, which does not carry offsets for native structs.

**Why a frozen `scale` is self-reinforcing**: phase A's rate is capped at `scale * 180` deg/s, so a small frame-1 gap means a permanently slow camera for the whole episode — gap 12.3 deg latches 0.137, i.e. 24.6 deg/s against Spyro's 210. As the gap then grows, the threshold grows only by `scale * 20`, which is tiny for the same frozen `scale`, so the episode cannot escape into phase B either. A cold start is safe both ways: gap ~0 passes the switch immediately, and gap >= 90 latches `scale` 1 (180 deg/s).

**Open question for the fix**: with the switch fix on, the threshold should match 30 FPS (at 210 deg/s: `7.0 * 5 = 35` at 30 FPS, `0.70 * 50 = 35` at 300), so a 12-28 deg gap ought to pass `|gap| <= ~37.7` and leave phase A. It does not, in the stuck frames. Note `camstuck 1.1` recorded `spyroYawRate=0.0`, which collapses the first term to zero and the threshold to `scale * 20` (~2.7 deg) — so a frame where Spyro is momentarily not turning may be what keeps it in phase A. **Next: have the probe compute and log the threshold next to the gap per charge frame.** Every term is available (gap, yaw rate, dt, `m_ctrDecelAngle`, `m_ctrDecelAngleTurnModifier`), and `scale` can be reconstructed as `min(|gap at centering start|/90, 1)` since it is frozen.

**`+0xC20` is not a reflected property** (the camdump's 553 values do not include it), so a Lua fix cannot write `scale` directly. The reflected levers remain `m_ctrDecelAngle` and `m_ctrDecelAngleTurnModifier`, i.e. the threshold, which is also the only term the game re-evaluates per frame.

### The stuck charge camera happens at 30 FPS too (2026-10-10, `camphase` logging, log 23:19-23:2x)

The probe now rebuilds the native phase test per charging frame and logs every crossing (`camphase`, edge triggered; see `trackers/camera.lua`). 216 crossings, 12 `camstuck`, 112 `stuck camera release`, no errors. **Two of the four `camstuck` episodes were at `cap=30`, `dt=33.33ms`** (12.1: gap 61.1; 16.1: gap 52.8). So this is **not a high-framerate deviation** — the game does it at its own tuned framerate.

Native behaviour, steady frames only (camera transitions excluded, and the mod's own one-frame release frames excluded):

| cap | flip | n | avg gap | avg threshold | avg turn term | avg scale | phase A cap |
|---|---|---|---|---|---|---|---|
| 30 | -> A | 25 | 40.2 | 22.5 | 16.4 | 0.304 | 55 deg/s |
| 30 | -> B | 22 | 20.3 | 32.0 | 27.0 | 0.250 | 45 deg/s |
| uncapped | -> A | 15 | 38.7 | 33.4 | 25.8 | 0.380 | 68 deg/s |
| uncapped | -> B | 7 | 18.2 | 19.3 | 13.9 | 0.269 | 48 deg/s |

- **30 FPS and uncapped now behave the same**: into phase A at a ~40 deg gap, back to B at ~20 deg, `scale` 0.25-0.38, phase A capped at 45-68 deg/s against Spyro's 210. The centering switch fix has done its job.
- **The turn term is not what fails.** It sits at **35.0** on the flips into A at every framerate — exactly the 30 FPS value (`7.0 * 5`). `m_ctrDecelAngleTurnModifier` tracks dt as designed (1.3 deg/frame * 27.03, 0.7 * 47.33, 0.8 * 43.82, and 7.0 * 5.00 at 30 FPS all give ~35). The earlier guess that the turn term collapses on a restart was wrong.
- **What fails is the frozen `scale`**, through both of its roles: it caps phase A at `scale * 180` (as low as **1-2 deg/s** when `scale` latched at 0.003-0.011 from a near-zero starting gap) and it shrinks the threshold's second term to `scale * 20` = 0.1-1.9 instead of 20. The gap then grows past the threshold and stays there.
- **Why `FIX_STUCK_CAMERA` only half-works, now visible**: it sets the modifier to `STUCK_CAMERA_RELEASE` 1e6 for one frame, which passes the switch test (those frames show thresholds in the hundreds of thousands and are excluded above). But one frame of phase B at `m_ctrInterp` ~3.9 closes ~1% of the gap (`3.9 * 3.3 ms`), so the next frame is back in phase A. That is the A -> B -> A oscillation behind 112 releases in one run.

**Scope**: by the project's target (every framerate must match 30 FPS) there is nothing left to fix here — high FPS already matches. `FIX_STUCK_CAMERA` is the one fix that deliberately changes 30 FPS as well, so improving it is a quality-of-life change, not a framerate fix.

**If it is to be fixed**: hold phase B instead of poking it. Keep the modifier elevated for as long as the gap is above the normal threshold while charging, so phase B interpolates continuously at `m_ctrInterp` (the healthy k50 ~3.6 measured elsewhere) until the gap closes, rather than for a single frame. That needs only the reflected `m_ctrDecelAngleTurnModifier`, which is the one term the game re-evaluates every frame. The cost is that charge centering would effectively never use phase A, which is a real behaviour change at every framerate and wants a decision before it is built.



### Holding phase B for the whole charge: no better, and reverted (2026-10-10)

`FIX_STUCK_CAMERA` was changed to hold `m_ctrDecelAngleTurnModifier` at 1e6 for a whole charge instead of one frame, on the theory that one frame of phase B closes too little to matter. **Tested, no better, reverted.**

The hold engaged as intended: `stuck camera release` 112 -> 0, 13 `stuck camera hold` lines, `camphase` crossings 216 -> 56, and the phase lines confirm `modifier 1000000.00` with `phase=B` every frame. But `camstuck` went 12 -> 18, with holds peaking at 99.0, 92.8, 142.2 and 136.9 deg, and `camRate` at detection was only 29.6-108.4 deg/s while `ctrInterp` read 3.911 — a completed `FInterpTo` at 3.9 against those gaps would give 180-400.

`scale` is multiplied into the camera's step at **`0x141EF66D7`**, *before* the phase branch at `0x141EF670E`, so a frozen small `scale` throttles the step in both phases. Phase B does not simply replace it: at `0x141EF6791`-`0x67A7` it lerps from the already-scaled step toward another step, with a blend alpha at `+0xAA8` that ramps over time (`0x141EF6750`-`0x6789`). So phase B recovers gradually rather than immediately.

**What this does NOT show (correcting an overreach):** it does not show `FIX_STUCK_CAMERA` does nothing. `camstuck` fires when the gap grows >= 5 deg over a 1 s window, so every number above describes the *first second* of an episode, during the blend ramp. Nothing here measured whether the camera eventually locks on, or how long it takes. A conclusion that the fix is useless, and a proposal to delete it, were both wrong and withdrawn.

**The 2026-09-16 controlled test stands**: with exact starting offsets set by hotkey, a full turn starting 12 deg off and one starting 33 deg off both locked on with the fix, where 144 FPS stuck without it and 33 deg stuck even at 30 FPS (README.txt, and the player's confirmation above). That is a controlled A/B of the fix and it is better evidence than anything in this section.

**Reconciling the two**: the fix cannot stop the gap growing while Spyro out-turns the camera, because the immediate step stays `scale`-throttled; what it does is get centering into phase B, whose blend ramps toward an unscaled interp step, so the camera does come back - over roughly a second rather than instantly. The charge-restart repro above is the harsh case because the gap keeps growing throughout.

**The measurement still missing** is time-to-lock, not stuck counts: a controlled starting offset with `FIX_STUCK_CAMERA` on and off, reading `camlock` `t50`/`t90`/`k50`, which is exactly what that tracker reports. The `camrepro` hotkey tool that set those offsets has since been removed from the probe (J is `tools/slide.lua` now), so it would need restoring.

### `camrepro` restored (2026-10-11)

Restored from commit `ca9757f`, where it lived in the probe's `main.lua` before the split into modules, now `tools/camrepro.lua` bound to **R**. It is the controlled A/B that verified `FIX_STUCK_CAMERA` on 2026-09-16, and measuring by free play instead is what produced the wrong conclusion on 2026-10-10.

- **R** arms the next gap, cycling 12 -> 33 deg (a press while armed cancels); only `R` was free, since the probe already binds B C G H I J K L M N O T U V Y and the F keys, and the game owns the number keys, W/A/S/D/E/F/P/Q/X/Z, LeftControl and the arrows. `J`, the original key, is `tools/slide.lua` now.
- Armed, it turns Spyro to face `gap` degrees right of the camera every frame until a charge starts; then it turns him right at `TURN_RATE` 130.8 deg/s (full stick lock during a charge) for 3 s. **Press charge without touching the stick.** Mouse steering reaches ~210 deg/s, so a by-hand mouse run is harsher than this tool.
- Needs `ROW_CAMERA` for `camYaw`/`camRate`, so run it with the `camera` tracker on.
- **Read `camlock` `t50`/`t90`/`k50` for the verdict**, not whether the gap grew. The gap grows either way while Spyro out-turns the camera; the question a working fix answers is how fast it comes back. That distinction is the lesson from 2026-10-10.

Wiring touched the probe's `main.lua` (a require, one `update` call, one key bind, three header lines), which a second session also has modified.

### Controlled `camrepro` runs, fix on (2026-10-11, log 00:07-00:11, LS102)

First controlled runs since the tool was restored. **`FIX_STUCK_CAMERA` was on for the whole session** (289 `stuck camera release` lines), so this is one arm only — there is still no A/B.

| R gap | gap measured at charge start | `camlock` k50 | at the end of the 3 s turn |
|---|---|---|---|
| 12 | 11.9 | **4.07** | gap 25.2, camRate -0.0 deg/s |
| 12 | 11.9 | **1.43** | gap 29.9, camRate -0.0 deg/s (charge ended at 1.88 s) |
| 12 | 12.0 | **0.52** | gap 31.7, camRate -190.0 deg/s |
| 33 | 32.8 | **4.32** | gap -28.5 (swung through), camRate 308.2 deg/s |

- The tool sets the gap accurately (11.9-12.0 and 32.8 against 12 and 33 asked for), so the A/B it was built for is repeatable again.
- **The 12 deg case is the bad one and it is erratic**: k50 4.07, 1.43, 0.52 across three runs at ~285-306 FPS. The 33 deg case recovered cleanly. Note this is the opposite ranking to the 2026-09-16 README line, which had both angles locking on.
- `camRate -0.0 deg/s` at a 25-30 deg gap on two of the 12 deg runs looks like the camera standing still, but it is a single instantaneous sample at the moment the forced turn stops, so it is not evidence on its own. **k50 is the measure.**
- **k50 is mostly below the ~3.6 target at both framerates this session**: cap=0, 7 of 11 below 3.0; cap=30, 11 of 14 below 3.0. Consistent with the earlier finding that 30 FPS is not clean here either.
- The spread across identical 12 deg runs (0.52 to 4.07) means **single runs decide nothing**; the A/B needs several repeats per cell.

**Next**: the same R sequence with `FIX_STUCK_CAMERA = false`, five or more runs per angle per framerate, comparing k50 distributions rather than single values. Until that arm exists, nothing here says whether the fix helps.

### A/B settled: `FIX_STUCK_CAMERA` works, and the 2026-09-16 prediction was right (2026-10-11)

Same `camrepro` angles with `FIX_STUCK_CAMERA = false` (confirmed by 0 `stuck camera release` lines), 14 runs: 3 per angle at 30 FPS and 4 per angle at ~315 FPS. The scripted turn makes the runs deterministic — the 30 FPS repeats are identical to 0.1 deg — so these are clean cells, not samples.

| angle | fix | framerate | gap at charge start -> at the end of the 3 s turn | camera rate at the end |
|---|---|---|---|---|
| 12 | off | 30 | 11.2 -> **33.0** (x3 identical) | 130.8 = the turn rate |
| 12 | off | ~315 | 11.9 -> **32.7-33.0** (x4) | 130.7-131.0 = the turn rate |
| 33 | off | 30 | 30.8 -> **81.3** (x3 identical) | 114.0, below the turn rate |
| 33 | off | ~315 | 32.8 -> **83.2-83.3** (x4) | 92.3-115.5, below the turn rate |
| 33 | **on** | ~315 | 32.8 -> **-28.5** (swung through) | 308.2, above the turn rate |
| 12 | on | ~285-316 | 11.9-12.0 -> 25.2 / 29.9 / 31.7 | -0.0 / -0.0 / -190.0 |

- **At 33 deg the fix plainly works, at both framerates.** Without it the gap runs from 33 to ~83 deg and the camera is *still losing ground* (rate 92-115 against the 130.8 deg/s turn), identically at 30 FPS and 315. With it the camera catches up and swings through to -28.5 deg at 308 deg/s. Four fix-off runs per framerate all agree.
- **At 12 deg nothing sticks even with the fix off**: the gap grows to 33.0 deg and holds there at exactly the turn rate, which is the normal full-lock trail. So there was nothing for the fix to do at 12 deg, which is why its fix-on numbers there looked erratic — it was perturbing a camera that was already fine.
- **This is exactly what line 91 of this doc predicted on 2026-09-16**: "33 deg should stick at every framerate without `FIX_STUCK_CAMERA`. 12 deg should stick only at high FPS with neither camera switch fix on. With `FIX_CAMERA_CENTERING_SWITCH` or at 30 FPS, the check passes once the turn starts." `FIX_CAMERA_CENTERING_SWITCH` was on throughout this A/B, so 12 deg not sticking is the predicted result, not a contradiction.
- `k50` is **not usable in this setup**: every run reports `endedBy=chargeEnd` with `k50=n/a`, because the charge ends when the tool stops turning, before the lock can close half the gap. The usable measures are the gap and camera rate at the end of the turn. Earlier sections leaned on k50; prefer these.

**Conclusion: `FIX_STUCK_CAMERA` earns its place and stays.** The 2026-10-10 conclusion that it "does nothing", and the proposal to delete it, were wrong — produced by free-play measurement over 1 s windows instead of this controlled A/B, and by reading `camstuck` counts as if they measured recovery.

**What is still open** is the player's original complaint: a charge restarted within ~0.5 s of stopping, steered by mouse at ~210 deg/s. That is harsher than this tool's 130.8 deg/s stick rate, and the fix helps without fully covering it. Reproducing *that* needs the tool extended to the higher turn rate and to the stop-and-restart pattern.

### `camrepro` extended: mouse turn rate and the stop-restart pattern (2026-10-11)

R now cycles five presets, so one key covers the whole matrix:

| # | gap | rate | mode |
|---|---|---|---|
| 1 | 12 | 130.8 (stick) | cold |
| 2 | 33 | 130.8 (stick) | cold |
| 3 | 12 | 210 (mouse) | cold |
| 4 | 33 | 210 (mouse) | cold |
| 5 | measured | 210 (mouse) | stop and restart |

- **Rate**: 130.8 deg/s is full stick lock; 210 is what mouse steering reaches (measured 2026-10-10) and is the harsher case the complaint came from. Presets 1-2 reproduce the runs already in this doc, so the new rate can be read against them.
- **"restart" mode** turns through a first charge for `FIRST_TURN_TIME` 1.5 s to build a trail, logs the gap, then waits up to `RESTART_WINDOW` 3 s for the player to stop and immediately re-charge, logs **the gap at that second charge**, and turns again for 3 s. The gap there is measured rather than set, because the whole point is the state the recentering leaves behind.
- **Why that state differs from a cold charge at the same gap**: the latch at `0x141EF6654` is gated on `+0xAA5` being clear. If centering is still mid-episode when the second charge starts, the latch is skipped entirely and the *previous* episode's `scale` carries over, which can be far smaller than the current gap would give. A cold charge always latches from the gap it is handed. So preset 5 is not the same experiment as preset 3 at the same angle, and the comparison between them is the interesting one.
- Judge runs by the gap and camera rate at the end of the turn. `camlock` k50 stays n/a in this setup (the charge ends with the turn, before the lock closes half the gap).

### Mouse turn rate is handled too (2026-10-11, fix on, 12 runs, LS102)

Presets 1-4 at three runs each, `FIX_STUCK_CAMERA` on (37 `stuck camera release` lines), no errors.

| gap | rate | gap at the end of the 3 s turn | camera rate at the end |
|---|---|---|---|
| 12 | 130.8 | 33.0, 33.0, 32.8 | 130.8 = the turn rate |
| 33 | 130.8 | 33.0, 33.0 (one run cut short at 1.93 s) | 130.8 = the turn rate |
| 12 | 210 | **53.0, 53.0, 52.4** | 210.0-210.1 = the turn rate |
| 33 | 210 | **53.0, 53.0, 53.0** | 210.0-210.1 = the turn rate |

- **No stuck state at either rate.** In every run the camera ends up turning at exactly Spyro's rate, which means the gap has stopped growing and settled into a steady trail: 33 deg at the stick rate, 53 deg at the mouse rate.
- **The trail scales linearly with the turn rate, to four digits**: 210/130.8 = 1.6055 against 53.0/33.0 = 1.6061. That is the `FInterpTo` steady-lag formula (`w * dt * (1 - f) / f`) behaving exactly as it should, so the bigger trail at the mouse rate is correct behaviour, not a failure.
- The starting angle stops mattering once the turn is underway: 12 and 33 deg converge to the same trail at the same rate. Consistent with the trail being set by the turn rate, not by where centering started.
- One `33 deg, stick rate` run ended at 1.93 s (`charge ended`) with the camera rate at 0.0, which is just Spyro stopping; not a stall.

**So the mouse rate alone does not explain the complaint.** With both camera fixes on, a cold charge at 210 deg/s tracks correctly. That leaves the stop-and-restart state as the remaining suspect, which is the case where the latch can be skipped and a stale `scale` carried over.

**The restart preset did not complete**: it was armed twice and cancelled both times. One attempt got as far as `first turn done: gap 52.8 deg, camera rate 209.1 deg/s` (tracking correctly through the first charge) before being cancelled. With one key, R is also cancel, so the 3 s window was too tight to let go of charge and press it again without touching anything else. Fixed: `RESTART_WINDOW` 3 -> 8 s, the prompt now says explicitly not to press R, and **the restart preset is now first in the cycle** so one press arms it.
