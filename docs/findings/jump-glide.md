# Jump / glide / hover height

## Framerate config

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

