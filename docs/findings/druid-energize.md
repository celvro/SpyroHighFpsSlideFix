# Green druid Energize bug (cause confirmed 2026-09-14 20:46–20:48; fix verified 21:09)

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

