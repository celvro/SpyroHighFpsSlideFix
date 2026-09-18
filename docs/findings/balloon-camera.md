# Balloon camera spin

**Symptom** (320 FPS, Spyro 1, balloon out of Artisans): near the end of the loading screen the
camera whirls around the balloon.

**Cause** (Blueprint, `GameplayCommon/.../LevelStreaming/Actors/BalloonTransporter`, read with
`AssetDump --code`):

- `Timeline_0` (length 45 s) is started with `PlayFromStart` after the ascent. Its update
  (`Timeline_0__UpdateFunc` -> ubergraph 7650) does
  `SpringArm.K2_SetRelativeRotation(Yaw = SpringArm.RelativeRotation.Yaw + 0.5)`: a fixed step
  per tick, so 15 deg/s at 30 FPS and 160 deg/s at 320 FPS.
- The timeline runs behind the loading screen. When the level load completes (ubergraph 3648)
  the Blueprint calls `ShowLoadScreen(false)`, starts a 1 s camera fade in, and after
  `Delay(1)` (ubergraph 2860) calls `Timeline_0.Stop()` and sets the arm to yaw 180. So the
  spin is visible for that ~1 s fade: ~15 deg of drift at 30 FPS, ~160 deg at 320 FPS.
- `S3BalloonTransporter` (Spyro 3) has the same update (ubergraph 12446).

Not caused by the mod's camera fixes: those only touch Spyro's `FollowCameraComponent`, and
the balloon view is the transporter's own camera on its `SpringArm`.

**Fix** (`fixes/balloon.lua`, `FIX_BALLOON_CAMERA_SPIN`): hook `Timeline_0__UpdateFunc` on both
classes (the hook runs after the body) and replace that tick's 0.5 deg with
`0.5 * dt * 30` (dt includes the actor's `CustomTimeDilation`, as the timeline does).
Frames of 1/30 s or longer are left alone. The final arm yaw is unaffected (the Blueprint
snaps it to 180 when the timeline stops).

**Other transporters**:
- Spyro 3's home world Whirligig (`S3WhirligigTransporter`) runs the same 45 s `Timeline_0` spin
  already scaled by dt: `Yaw += 30 * DeltaSecs * 0.5` (ubergraph 8355). The fix uses the same
  15 deg/s, so it matches what the developers intended. It needs no fix; tested at high FPS, no whirl.
- `WhirlwindTransporter` and `HubWhirlwind` have no per-tick yaw step.
- In the level Blueprints searched so far, `S3BalloonTransporter` is only referenced from
  `LS326_ScorchsPit/.../LS326HunterEscapeController`. Its hook registers, but it hasn't been
  seen running in game.

**Status**: fixed, verified (2026-09-18, high FPS, Spyro 1 balloon): only a slow drift during
the fade in, no whirl. UE4SS.log: `balloon camera spin hook registered` for both classes, with no
hook errors. `S3BalloonTransporter_C` is hooked again on each level load, because its class is
recreated each time; that's expected.
