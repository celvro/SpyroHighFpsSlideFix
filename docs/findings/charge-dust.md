# Charge dust bug (found 2026-09-14 from assets; second fix verified in game 2026-09-14 20:25)

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

