# Artisans gem thief runs in his idle animation (`BP_CES1012_GemThief`)

Reported by a player: in Artisans Home the gem thief runs away in his idle pose. Reproduction (their
testing, 2026-09-27): **320 FPS with VSync already on while the level loads**. VSync switched on after
the load animates correctly, and loading at 30 FPS with VSync animates correctly. He moves normally —
only the pose is wrong — and montages still play (flaming him plays the hit animation, then he drops back
to idle).

## Cause: the anim Blueprint's `Speed` is NaN, and it can never recover

- `BP_CES1012_GemThief_C`'s `FalconEnemyState_Flee` (`EFalconMovementMode::FleeFromPlayer`) is **the only
  state with no `Montage`** — Alert (`AM_CES1195_Alert`), Death, `Flee_TempImmun`
  (`AM_CES1195_Take_Hit_Slow`) all have one. So while fleeing his pose comes only from the anim
  Blueprint's blendspace, `BS_CES1195_GemThiefNew_Locomotion`.
- `ABP_CES1195_GemThiefNew_C`'s only blendspace input is `Speed`, copied to the node's `X` by
  `EvaluateGraphExposedInputs`. `BlueprintUpdateAnimation` sets it through
  `CalculateTurnRate.UpdateSpeed(pawn, DeltaTime, Speed, 4)`, which is
  **`Speed = Lerp(Speed, VSize2D(GetVelocity()), DeltaTime * 4)`**.
- That accumulator is its own input, so one non-finite frame sticks for the rest of the level:
  `Lerp(NaN, v, α)` is NaN, and an `inf` becomes NaN on the next frame (`inf + α·(v − inf)` = `inf − inf`).
  A NaN `X` lands on the blendspace's idle sample at any speed.

**Measured 2026-09-27 16:47, LS101, 320 FPS uncapped, `gemthief` lines in `UE4SS.log`** (probe
`trackers/gemthief.lua`, hot-reloaded into a session that had loaded in with VSync on):

- Both thieves in the level (`BP_CES1012_GemThief_135`, `BP_CES1012_GemThief2_352`) reported
  `animSpeed=-nan(ind) bsX=-nan(ind)` on **every** frame, in every state.
- The velocity they were given was healthy the whole time: `vel=171 … 405` through
  Alert → Flee → Hit1 → Flee_TempImmun → Flee, `mode=Custom` while fleeing.
- The anim Blueprint was running: `animDt=0.0031–0.0051` (i.e. the real frame time), and the montage
  states matched the play (`anyMontage=true rate=1.0` for Alert and the hit, false while fleeing).
- Nothing else was off: `tick=true updateFlag=1 pauseAnims=false noSkeleton=false animRate=1.0 uro=false
  visible=true dilation=1.0 rootMode=3`. The distant second thief has `tick=false` and a stale
  `lastRender`, which is normal for a character that isn't being looked at, and it was NaN too — so the
  poisoning isn't about being rendered.

Ruled out by this: reduced or stopped anim ticking (URO, `MeshComponentUpdateFlag`, `bPauseAnims`,
`bNoSkeletonUpdate`), `CustomTimeDilation`, a null blendspace, and `GetVelocity()` reading zero under the
Phasmid flee (mode 6) — the velocity is fine, the accumulator is not.

Not caused by the fix mod: no fix touches this actor, its mesh, any anim tick flag, or any animation
asset (only `fixes/druid.lua` edits one, `AM_CES1035_GreenDruid_Casting_Up`). See also
`docs/findings/npc-stalls.md` for the separate stall-from-rest survey, which is what first named this
class in the log.

## The poison arrives in `Velocity`, at the Alert transition (measured 2026-09-27 16:56–16:57)

With the probe logging the finite → non-finite transition, the thief was poisoned **three times in ninety
seconds of normal play**, so this is not a one-off during the load:

```
16:56:24 gemthief poisoned BP_CES1012_GemThief_135 state=Alert mode=Custom vel=-nan(ind) animSpeed=-nan(ind) prevSpeed=1.5839 animDt=0.0031 prevDt=0.0031
16:56:31 gemthief poisoned BP_CES1012_GemThief_135 state=Death mode=NavWalking vel=0.0     animSpeed=-nan(ind) prevSpeed=0.0769 animDt=-nan(ind) prevDt=0.0032
16:57:38 gemthief poisoned BP_CES1012_GemThief_135 state=Alert mode=Custom vel=-nan(ind) animSpeed=-nan(ind) prevSpeed=0.0    animDt=0.0033 prevDt=0.0032
```

- **The movement component's `Velocity` is NaN**, not just the anim Blueprint's accumulator. `vel` here is
  read straight off `CharacterMovement.Velocity`, and the anim Blueprint only inherits it through
  `VSize2D(GetVelocity())`. Both Alert cases have `prevSpeed` at 0–1.6, i.e. **he was at or near a
  standstill when the flee started** — the same starting condition as every other fix in
  `docs/findings/sliding-walking.md` / `sheila-buzz-walk.md`, and consistent with a normalize or divide by
  a velocity that is exactly zero at 320 FPS but never quite zero at 30.
- Both Alert cases are `mode=Custom` (the Falcon flee movement), the state whose movement the
  `npc-stalls.md` survey lists as never measured.
- The Death case is different and worth its own look: `Velocity` was a clean 0 and **`animDt` itself was
  NaN**, i.e. the DeltaTime handed to `BlueprintUpdateAnimation` was not a number that frame.

So the VSync-at-load reproduction is not the whole story: the trigger is a flee starting from rest, which a
load just happens to line up with. Once it lands, `Speed` never recovers, which is why it looks permanent.

## Fix verified in the probe

Writing the live horizontal speed over a non-finite `Speed` restores the run animation on the spot
(confirmed in play, 16:57). One detail the first attempt got wrong: on the poisoned frame `Velocity` is
NaN too, so the write must wait for a frame where the velocity is finite again — `wrote Speed=-nan(ind)`
achieves nothing. After that, `animSpeed` tracked `vel` normally (`vel=302.9 animSpeed=300.0`,
`vel=300.1 animSpeed=300.7`).

`trackers/nanspeed.lua` now applies the same check to **every** `PhasmidCharacter` in the level (round
robin, a few property reads a frame), logging `nanspeed` per class and healing the same way, since
`UpdateSpeed` is in the shared `CalculateTurnRate` library and nothing about the mechanism is specific to
this thief.

## Note on the crashes during this investigation

The game crashed at startup repeatedly on 2026-09-27 and 2026-10-05 while this was being measured, which
cost a session and sent the diagnosis down two blind alleys (a duplicate `NotifyOnNewObject`, then
`trackers/gemthief.lua` polling `FindAllOf`). It was neither: `0xC0000005` at
`Spyro-Win64-Shipping.exe+0x1891327` with `SecondsSinceStart=0` survived disabling the probe and then the
fix mod, and stopped when two unrelated pak mods were removed from `Content/Paks/~mods`. See
`docs/probe.md`.

## It needs a world that has been alive for hours (measured 2026-10-06 06:33)

A fresh boot at 320 FPS with VSync on, Artisans Home, one Idle → Alert → Flee from a standstill: **no NaN
at all.** `animSpeed` and `bsX` tracked the velocity the whole way (`vel=300.2 animSpeed=296.1 bsX=296.1`
… `vel=304.8 animSpeed=300.8`), through Hit1, Hit2, two `Flee_TempImmun` montages and back to Cautious.

The difference from the session that did poison is the **world time**: those three poisonings were at
`time=9248`, `9254` and `9302` seconds — about 2.5 hours into a session — while this run only reached
`time=43`.

That fits the arithmetic. World time is a float32: at t≈9250 s one ulp is ≈0.98 ms, so a 320 FPS frame
(3.1 ms) is only about three ulps, and any time difference taken inside the flee movement can round to
**zero** — a `0/0` away from NaN. At 30 FPS the same frame is 33 ms, about 34 ulps, which never collapses;
at t≈40 s an ulp is 4 µs and even a 320 FPS frame is ~800 ulps. So the bug needs high FPS **and** a
long-lived world, which also explains why the player hit it and a quick test does not.

The `bsX` lag in the first 0.2 s of the Alert (`bsX=2.60` while `animSpeed` climbed 11 → 65) is not the
bug: the `AnimNode_Slot` has `bAlwaysUpdateSourcePose = False`, so while the Alert montage owns the slot
the blendspace under it is not updated and its X keeps the value it had. It caught up the moment the
montage released (`bsX=296.1`).

**To verify the heal without waiting hours**, the probe's T key writes the NaN into the anim Blueprint by
hand and holds the heal back for 5 s (`gemthief poison-test`), so the broken pose is visible, then the
heal lands and `gemthief verdict … HELD` reports whether it stuck.

## A second, easier specimen: the balloonist's NaN DeltaTime

The level-wide sweep (`trackers/nanspeed.lua`, Y) caught **`CNS1127_MarcoTheBalloonist`** with
`animDt=-nan(ind)` on a fresh boot, persistently (four samples, world time 28 → 44 s), while its velocity
and `Speed` were 0. So a NaN **DeltaTime** is reaching that anim Blueprint — the same thing the thief
showed on his Death frame on 2026-09-27 (`animDt=-nan(ind)` with a clean `Velocity`). Marco reproduces
immediately, with no 2.5-hour wait, which makes him the better place to find where these NaNs are made.
He is also the actor `fixes/balloon.lua` already works on (`docs/findings/balloon-camera.md`).

## The per-chase idle pose is framerate-independent, so it is not the reported bug (measured 2026-10-06 06:43)

`gemthief stalepose` lines, one per stretch of running with the blendspace X still at a standstill value:

| cap | duration | frames | montage frames | frozen at | Speed reached | max vel |
|---|---|---|---|---|---|---|
| uncapped (~320) | 0.203 s | 65 | 65 | 2.51 | 65.6 | 171.2 |
| 30 | 0.200 s | 7 | 7 | 3.18 | 82.7 | 188.0 |

**0.200 s at 30 FPS and 0.203 s at 320**, montage playing for every frame of both. So the stale blendspace
under the Alert montage's slot (`bAlwaysUpdateSourcePose = False`) lasts the montage's own fixed time at
any framerate. It is not a high-FPS bug and not worth fixing — it is a fifth of a second at the start of
every chase, on console too.

That leaves the NaN `Speed` (bug A above) as the reported bug: permanent once it lands, which also matches
the player's description better than something that clears itself after 0.2 s.

## The heal is verified, at 30 and 320 FPS (2026-10-06 06:43)

The T test (NaN written into the anim Blueprint by hand, heal held back 5 s) was run at both framerates:

- `gemthief poison-test … Speed set to NaN, heal held 5s` → he ran in the idle pose, confirmed on screen
  at both framerates, with `stalepose` recording 2.200 s at cap 30 and 3.087 s at cap 320 (the stretch ends
  when the heal lands, not after a fixed time).
- `gemthief healed … wrote Speed=299.87 over -nan(ind)` → the pose came back, and the stretch closed with
  `nowBsX=299.93` (cap 30) and `299.68` (cap 320), i.e. the blendspace tracking his real speed again.
- 1563 of 1565 watched frames were clean afterwards (`maxBlendX=301.8` against `maxVel=306.1`).

The `verdict` lines said `BROKE` for a measurement bug, not a real one: the window counted the frame the
write happened on, whose `Speed` had been read before the write, so it always scored exactly one NaN frame
(`nanFrames=1 idleWhileMoving=1`). The verdict now starts from the next frame.

**Shape of a shipped fix:** write `VSize2D(Velocity)` over a non-finite `Speed` on the anim instance, only
when the velocity itself is finite. It needs no per-frame ownership of the value, because `Speed` is its
own Lerp's input and converges from any finite number. Open choice: heal only the anim `Speed` (cosmetic,
cheap, cannot affect gameplay) or also clear a non-finite `Velocity` at the source (fixes whatever else
reads that velocity, but touches enemy movement). Candidate budget: a round robin over the level's
`PhasmidCharacter`s, a few property reads a frame, as `trackers/nanspeed.lua` does.

## Shipped as `fixes/animspeed.lua` (2026-10-06, `FIX_NAN_ANIM_SPEED`)

Writes the character's own horizontal speed over a non-finite anim Blueprint `Speed`, and nothing else:

- Characters come from a `NotifyOnNewObject` on `/Script/Phasmid.PhasmidCharacter` (every NPC and enemy
  derives from it), never from polling.
- Round robin, `CHECKS_PER_FRAME = 2` characters a frame, each re-read every `CHECK_INTERVAL = 0.25 s`,
  with the anim instance cached per character and `GRACE = 1 s` before a newly constructed one is touched.
  A Blueprint with no `Speed` at all (a state machine instead of a blendspace, which is most of them) is
  marked `skip` on the first read and never read again, so the steady-state cost is a couple of property
  reads a frame.
- It writes only when `Speed` is non-finite **and** the velocity is finite — on the frame the NaN lands
  the velocity is NaN too, and writing a NaN over a NaN achieves nothing, so it waits for the next check.
- A character whose `Speed` is a number is not touched at all.
- It heals at every framerate rather than only above 30 (the usual rule): a NaN pose is not what 30 FPS
  does either, and the state cannot arise there, so there is no reference behaviour to preserve.
- Heals are logged at most `MAX_LOGS = 3` times per session, in case a write ever fails to stick.

Still to do: confirm in game that the module heals the thief (the probe's T test proves the mechanism, not
this module's plumbing), profile it with `PROFILE = true`, and add the `README.txt` line once that is done.

## Verified in game, with the probe's healer off (2026-10-06 07:00, LS101, ~310 FPS)

`HEAL = false` in both probe trackers, so `fixes/animspeed.lua` was the only thing that could repair
anything. Four T tests, each writing NaN into the anim Blueprint's `Speed`:

| test | recoveredAfter | NaN frames | verdict |
|---|---|---|---|
| 1 | 0.044 s | 13 | HELD |
| 2 | 0.150 s | 41 | HELD |
| 3 | 0.117 s | 33 | HELD |
| 4 | 0.151 s | 81 | HELD (thief 2, the one running that time) |

All within `CHECK_INTERVAL` (0.25 s), with `[HighFpsSlidingAndJumpFix] NaN animation speed fix: healed
BP_CES1012_GemThief_C` in the log and `maxBlendX` ≈ 301 against `maxVel` ≈ 306 afterwards. No Lua errors.
On screen the break is a flicker rather than a stuck pose. Only three mod heal lines appear for eight
heals because of `MAX_LOGS`.

`idleWhileMoving` stays non-zero in the HELD windows (42–69 frames) and that is correct: it counts the NaN
frames before the repair plus the ~0.2 s of stale pose under the Alert montage's slot, which is the
framerate-independent behaviour measured above.

**Profile with every fix on** (`PROFILE = true`, nine 10 s windows, avg frame 3.15–3.40 ms, i.e. ~300 FPS):
fixes avg **0.112–0.179 ms/frame (3.3–5.3% of a frame)**, max 3.0–11.9 ms per window, clock overhead
0.007 ms. In family with the baselines in `docs/ue4ss.md`. The new module's own share was not separated —
the profiler times the whole tick, not each fix — so measuring it needs an A/B with
`FIX_NAN_ANIM_SPEED = false` in the same spot. Its steady-state work is two property reads a frame
(cached anim instance, `Speed`), since every Blueprint without a `Speed` is skipped after one read.
