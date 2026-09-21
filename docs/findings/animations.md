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

## The route the scripted tour runs (2026-09-20)

One level tour (**T**, `tour.txt` with `dwell=3`) travelled all 101 levels in 22 minutes and scanned each
one into `routes.txt`: **1789 stops over 84 levels and 577 distinct kinds of character** — 707 `walk`,
375 `flame`, 375 `charge`, 332 `enterPlay`. What is not in it:

- the 13 flight levels and speedways, skipped on purpose (Spyro never walks there, so a stop can never be
  arrived at, and a crash there ends on a Retry screen that would stop the tour);
- LS222, the one level travel never arrived in;
- LS318, LS327 and LS336, which hold one character each that was already covered in an earlier level.

At about 8 stops a minute, both framerate passes over the whole route take roughly 7.5 hours. `script=`
takes a comma list (`script=walk,enterPlay`) when a run has to be cut down to the stops that start a
chase or a minigame.

### Reading the tour comparison

`Compare-Anims.ps1` is a screen, not a verdict, and the LS104 validation set shows why: it flagged 20 of
26 stop/character groups, and almost all of it was gameplay diverging rather than animation. At 320 Spyro
took a `Damage_Knockback` at one stop and a `Damage_Drown` at another that he never took at 30, and a
blue thief that ran off gave a 161 m difference in where it ended up. A live level is not a controlled
test. Anything it flags goes back through the montage sweep, which is the measurement — both false
positives above were caught that way.

**What the sampling can and cannot see.** Over the first 25000 samples of the full run: every target row
carries its enemy state (100%), but only 48% carry a montage, and Spyro carries one in 12% of his rows and
has no state name at all. Most of the time a character is in its AnimGraph — a locomotion blend space,
not a montage — so the montage column is empty and the state name is what says which animation it is in.
For an enemy or an NPC that is enough. For Spyro the non-montage time is only described by his speed,
movement mode and position, so a difference in his walk or glide pose would not show up here; that side of
him is measured by position instead, in `sliding-walking.md`, `jump-glide.md` and `charge-turn-camera.md`.

## What had to be controlled in the scripted tour (2026-09-21)

The montage sweep needed four things controlled before its numbers meant anything. Driving real gameplay
needed three more, and all three were found by the run doing something wrong for a while first.

- **A run must not cross from one game into another.** Travelling live from LS135 into LS201 sets the
  game index and streams the level in, but Spyro starts at a checkpoint belonging to the game he was in,
  so he is left falling in a black void at his old coordinates while the old level unloads. `levels.current`
  then names whichever level is nearest, which is meaningless, and every stop after it fails. Each game is
  its own segment now (`game=1|2|3`) with a restart between them, because a restart switches games
  properly. A level that cannot be reached is also abandoned whole rather than one stop at a time: it was
  paying the 90 s travel timeout per stop, and LS201 alone would have spent half an hour on it.
- **A conversation that never closes takes input away, and nothing looked like it was wrong.** An NPC in
  Skelos Badlands held Spyro in dialogue; every stop after that teleported him, held forward for the whole
  four seconds, recorded speed 0 and no movement, and the log still said `played`. It was only caught by
  watching the screen. A stop that is told to walk and does not move for 2 s now ends as `could not move`,
  and a dialogue stop that does so loads the level again at once, which is the cheapest thing that clears
  a conversation. Detecting the symptom rather than the conversation covers cutscenes too.
  - The cost is real: of the first 209 stops of the Spyro 2 segment, 52 could not move (24 dialogue stops
    and 28 walk and charge stops caught in the aftermath), and 68% played. Recovering at the dialogue stop
    that caused it took that to 12% locked and 83% played.
  - **A quarter of `enterPlay` stops still lock**, because the script taps flame and jump and neither
    dismisses every Spyro 2 conversation. The recovery keeps the run healthy but the data for those stops
    is lost. Raising dialogue coverage means finding the button that closes a conversation — and changing
    the script invalidates any comparison against a pass that used the old one, so it is a separate run,
    not an edit mid-flight.
- **Stops that cannot move are not all locks.** The first one the check caught was a charge at a fish
  across water, which reads speed 0 in every pass and always did. One stop that cannot move is usually
  the spot; three in a row is the game having taken input away.

## Still to do

- The whole-game montage sweep: `animtest.txt` with no `here`, which tours every level, measures each
  montage once per cap and skips the shared ones it already has (`animtest_done.txt`). Reached LS106 with
  216 montage-cap measurements banked; the dedupe works (LS106 needed only 24 of its 92 montages).
- The scripted tour over the full 1789-stop route at 30 and 320: started 2026-09-20 21:49.
