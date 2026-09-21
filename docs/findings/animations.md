# Every character's animations at 30 vs 320 FPS

Question (2026-09-20): does any character animate differently at a high framerate? Three fixed bugs were
animation-adjacent — the charge dust (`charge-dust.md`) and the Alpine Ridge druid (`druid-energize.md`)
were anim notifies that fire once per tick, and the Fireworks Factory dragon (`fire-dragon.md`) bunched up
— so the animations themselves are worth sweeping rather than waiting to notice one.

Two tools, because gameplay and the animation assets reach different things:

1. **The montage sweep** (`tools/animtest.lua`, **I**) plays every montage of every kind of character in a
   level straight through `Montage_Play`, at 30 FPS and then at 320, in the same level visit. It covers a
   character's whole repertoire in seconds instead of provoking one attack at a time, and it measures the
   things a framerate can change: how long one pass takes, how far root motion moves the character, and how
   many particle and audio components the notifies make.
2. **The scripted tour** (`tools/autotest.lua`, **O**) now samples the animation of the played character and
   of the character each stop was recorded in front of, so the animations that only gameplay starts —
   state-machine locomotion, chases, dialogue, minigames — are compared too. `tools/scan.lua` records a stop
   per class and script (`walk`/`flame`/`charge` for enemies, `walk`/`enterPlay` for NPCs), and `enterPlay`
   is what gets into a minigame: walk into whoever starts it, tap through the dialogue, then hold forward
   and jump.

Both are described in `docs/probe.md`; this doc holds the measurements.

## What had to be controlled first (2026-09-20, LS104 Town Square)

Four things made the first runs meaningless, and all four are now handled in `lib/anim.lua`:

- **Characters the game isn't using don't animate at all.** The Town Square thief's montages sat at
  position 0 for the whole timeout. Its mesh tick was off (and other characters can have
  `CustomTimeDilation` 0, `bPauseAnims`, `bNoSkeletonUpdate` or `GlobalAnimRateScale` 0). `anim.hold` turns
  all of them on for the montage and puts them back afterwards.
- **A character that isn't being looked at ticks its animation at a reduced rate**
  (`MeshComponentUpdateFlag`, `bEnableUpdateRateOptimizations`), which would read as a framerate difference.
  Both are forced off during a montage.
- **The AI keeps walking the character about** while the montage plays: its state component and its AI
  controller tick separately from the actor, so disabling the actor's tick is not enough — the chickens
  wandered 80 units through their Squawk, and a fleeing Bull-taming Gnorc 459 units through an animation
  with no root motion at all. All three ticks are off during a montage now, the character is pinned until
  its root motion takes over, and `drift` records how far it had to be pulled back.
  - **This one produced a false positive worth remembering.** Pinning the character on every frame that
    isn't root-motion driven leaves out the frame the root motion starts on — and that frame is 33 ms of
    movement at 30 FPS against 3 ms at 320. The bull's `AM_CES1207_Run_StopTurn` came out at 191.8 units
    at 30 FPS and 197.4 at 320, a repeatable 3% "high FPS moves further", which was entirely this. With
    the AI ticks off and every frame counted from the first root-motion one, both framerates give 197.3
    (30 FPS: 197.28 exactly, three runs; 320: 197.59–197.97, one frame's worth of spread).
- **A montage stops reporting itself as playing at its blend out**, not at the end of its sequence, so
  every montage looked like it had been interrupted. The blend out is read from the asset and taken off the
  length before a pass is called `cut short`.

Verdicts per montage: `played` (ran to its blend out), `looped` (its last section runs back to the start,
so one pass is what is measured), `cut short` (the character's own state machine played something over it),
`sub-frame loop` (a loop shorter than one frame, so the position reads the same every time it is sampled
— the chicken's 0.03 s death loop at 30 FPS; the comparison doesn't time these), `stuck` (the position
never advanced for another reason) and `refused` (`Montage_Play` would not start it).

**Where the character stands changes what its root motion covers**, and that was the second false
positive. Spyro's `AM_CPS1999_LoopEntrance` came out at 834 units at 30 FPS against 670 at 320, the same
both times the sweep ran; repeating it on its own gave 834/799/427/427 at 30 and 670/427/427/427 at 320.
The montages before it left him in a different place in each pass, and the loop covers a different
distance from different ground. Each montage now starts from the spot and facing the character had when
the level's list was built, and LoopEntrance comes out at 834.32 units at 30 FPS against 833.86 at 320.

Even so, **a flagged montage means "measure it again", not "a bug"**: re-running one on its own
(`animtest.txt` with `here montage=<name>`) takes seconds and is the cheapest way to tell a real
difference from where the character happened to be.

## First level measured (LS104 Town Square, 2026-09-20)

6 kinds of character (Spyro, Bull-taming Gnorc, Bull, Blue Thief, Chickens, Save Fairy), 90 montages,
measured at 30 and 320 FPS in one visit, about 3 minutes per pass. Verdicts: 116 played, 58 looped, 4 cut
short, 2 sub-frame loops across the two passes.

**Nothing differs between 30 and 320 FPS.** After the four controls above, `Compare-Animtest.ps1` flags
nothing: every montage runs for the same time (within the 33 ms a 30 FPS frame can hide), moves the
character the same distance, and spawns the same number of particle and audio components.

The numbers worth keeping as the shape of a clean result:

| Montage | Length | 30 FPS | 320 FPS |
|---|---|---|---|
| `AM_CPS1999_LoopEntrance` (Spyro, root motion) | 5.0 s | 4.900 s, 834.32 units, 146 root frames | 4.901 s, 833.86 units, 1526 root frames |
| `AM_CES1207_Run_StopTurn` (Bull, root motion) | 1.93 s | 1.733 s, 197.28 units (identical in four runs) | 1.735–1.736 s, 197.6–198.0 units |
| `AM_CES1237_BulltamingGnorcNew_AttackRecovery` | 2.67 s | 2.433 s | 2.433 s |

One thing to keep an eye on rather than a finding: the bull's `AM_CES1207_Run_StopTurn` spawned 16–20
particle components at 30 FPS (20, 18, 18, 16 over four runs) and exactly 16 at 320 every time. The
30 FPS side is the variable one, so it is not the charge-dust pattern of effects disappearing at high
framerates, but a montage whose dust count is not fixed is worth a second look if the whole-game sweep
turns up more like it.

## Still to do

- The whole-game sweep: `animtest.txt` with no `here`, which tours every level, measures each montage once
  per cap and skips the shared ones it already has (`animtest_done.txt`).
- The scripted tour at 30 and 320 with the animation sampling, once the route file covers more than LS104
  (the tour, **T**, builds it by scanning each level it visits).
- Minigames: `enterPlay` stops exist only once a level with a minigame NPC has been scanned.
