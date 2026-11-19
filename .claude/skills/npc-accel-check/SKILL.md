---
name: npc-accel-check
description: Check whether an NPC or enemy in Spyro Reignited gets going more slowly at high FPS than at 30 (the slow start from a standstill that Sergeant Tub, Sheila and the Stone Hill rams had), and fix it. Uses a hand-recorded level replay, the probe's per-character traces and tools/Compare-ReplayActors.ps1, so no log reading. Use when a character seems slower, sluggish, stuck or late to react at high FPS, when asked to check a level's NPCs or enemies for the stall, or to verify fixes/npcwalk.lua on a new class.
argument-hint: [level e.g. LS213] [class text e.g. Cowlek]
---

# NPC acceleration check: does it start moving as fast as at 30 FPS?

**The bug:** a character standing still asks to move, and at high FPS its first frames of movement round
to nothing on the level's position grid (1/32 units far from the origin), so it creeps, starts late or
never goes (`docs/findings/npc-stalls.md`). Low-acceleration walkers are hit hardest: rams (512) were 35%
slower to walking speed at ~250 FPS. `fixes/npcwalk.lua` fixes any class added to its `WALKERS` list, as
long as the class moves by requested moves (AI path following).

**The method:** record one take that makes the characters move from a standstill, replay it at 30 FPS
and uncapped, and let `tools\Compare-ReplayActors.ps1` print each character's time from standing to 90%
of its move's top speed (`t90`) in both. If the characters wander at random and the replay cannot make
the same thing happen, ask the user to record the test once per framerate instead (step 4b).
Everything goes through `tools\Invoke-Probe.ps1`; never read the `_actors.csv` files or `UE4SS.log` for
this.

## 1. Look at the level's characters

```
tools\Invoke-Probe.ps1 swap <1|2|3>          # only if the level is in another game
tools\Invoke-Probe.ps1 travel LS213
tools\Invoke-Probe.ps1 characters            # every class: count, acc, walk speed, mode, requestedAccel
tools\Invoke-Probe.ps1 characters cowlek     # each one's name, level-relative position, distance from Spyro
```

- **Suspects:** low `acc` (well under 2048) or a long time to walking speed (`walk / acc`), in Walking or
  NavWalking. `requestedAccel=true` means AI requested moves with acceleration: the kind
  `fixes/npcwalk.lua` corrects. A class in Custom mode (6) or one that is launched or played by root
  motion moves another way, and needs its own investigation (`spyro-fps-bug-hunt` skill).
- **High acceleration (2048) can still be worth a look:** an attack (flame, charge) can send a character
  into a flee or a knockback that starts from rest too.

## 2. Record the take (the user plays; ask them)

The probe only records; a person has to play. Ask the user, in one message, for exactly what the take
must contain:
- start from a **fresh level entry** (breakables and enemies do not reset otherwise);
- the cap is 30 FPS (`tools\Invoke-Probe.ps1 cap 30`), set by Claude before the take;
- walk to the characters and make them **move from a standstill**, several times, with a few seconds of
  standing between: whatever moves them (approach, flame, charge, a power-up the level has);
- no deaths, no menus; a conversation is fine (the take's own Space presses close it in the replay).

Start and stop it for them, so no key reaches the game window they are playing in:
```
tools\Invoke-Probe.ps1 cap 30
tools\Invoke-Probe.ps1 replay-record start
# ... the user plays, then says "done"
tools\Invoke-Probe.ps1 replay-record stop    # answers with the take id
```
The user can also record it themselves with Home (start/stop) at F5 (30 FPS) and give the take id; the
newest take for the level is `tools\Invoke-Probe.ps1 takes <LS###>`'s first line.

## 3. Replay it

```
tools\Invoke-Probe.ps1 replay take=<id> cap=30 -Timeout 600
tools\Invoke-Probe.ps1 replay take=<id> cap=30 -Timeout 600    # determinism check
tools\Invoke-Probe.ps1 replay take=<id> cap=0 -Timeout 600
tools\Invoke-Probe.ps1 replay take=<id> cap=0 -Timeout 600     # a second uncapped run
```
Each run writes `replay_<take>_run<cap>_<stamp>_actors.csv` (config `REPLAY_ACTORS`, on). The log line
`replay: playing (Jump as a real Space key)` confirms the inputs went out normally.

## 4. Compare

```
tools\Compare-ReplayActors.ps1 -Take <id> -Class <text> -All     # every run, one column each: start here
tools\Compare-ReplayActors.ps1 -Take <id> -Class <text>          # one run in detail (gaps, d0.5)
tools\Compare-ReplayActors.ps1 -Take <id> -Class <text> -Reference <file> -Run <file>   # a given pair
```
The reference is **the recording itself**: a take records every character too
(`replay_<id>_ref_actors.csv`), so the table shows what each one did while the user played. (Takes from
before 2026-11-19 have none; the newest 30 FPS run stands in.) `-All` prints t90 per class and per
character for the recording and every run of the take, with when each character first parted from the
recording by 5 units. A 30 FPS run that parts from the recording early means that character does not
repeat (random AI, or it reacted to something the replay did differently): judge it only on its t90s.

**Reading it:**
- **Judge only on characters with a start in both runs** (`starts 1|1` or more), and on `t90`
  (seconds from standing to 90% of that move's top speed; a move ends at its first movement-mode
  change, so a leap or a knockback is not taken for the walk).
- **`t90` at 30 FPS should be about `0.9 * walk / acc`** (rams: 0.9 × 180 / 512 = 0.32; measured 0.33).
- **Slow:** `t90` longer by a 30 FPS frame (0.033 s) or more in both uncapped runs (rams: 0.44 and 0.46
  against 0.33).
- **`d0.5` is coarse:** a move's start is only known to the reference's frame, so two 30 FPS runs gave
  54.8 and 60.8 for the same ram. Use it only as a hint.
- **Max gap** is mostly Spyro's own uncapped drift (he leaves the recording within ~1 s from the walk-off
  turn snap) and what the characters do about it. It is not the measure here.
- **Few starts:** if the class has no starts in both runs, the take did not make it move from rest:
  ask for another take.

## 4b. When the replay cannot reproduce it: one recording per framerate

A replay restores every character's start (dead ones removed, the rest placed where the recording found
them, `docs/probe.md`), but not their AI's random choices. Most characters repeat; the ones that wander
at random do not: critters (fodder) and, as measured, Zephyr's cowleks, which left their recorded paths
within 0.1-0.5 s even at 30 FPS. Then the replay cannot make the same thing happen: Spyro's flame or
charge misses a character that walked elsewhere, or a wanderer bumps him off the recorded path.

**Decide from the `-All` table and the 30 FPS run:**
- the class parts from the recording (`>5 at`) within about a second **in the 30 FPS runs**, and
- the interaction being tested is missing from the runs (fewer starts than the recording; for a hit, no
  knockback or flee in the runs' movement modes), or Spyro's own run parts from the recording before it
  (`compare_replays.py`, or the trace's first divergence).

If so, do not keep replaying. **Ask the user to record the test by hand at each framerate**, in one
message:
- the same actions on the same characters, as alike as they can, once at 30 FPS and once uncapped;
- Claude sets the cap before each take (`tools\Invoke-Probe.ps1 cap 30`, then `cap 0`) and can start and
  stop them (`replay-record start` / `stop`), or the user uses F5 / F8 and Home and gives the take ids;
- several of the moves being measured in each take (each flame, charge or approach counts once), since
  the two takes are compared statistically, not frame by frame.

Each take records every character (`replay_<id>_ref_actors.csv`). Compare the two recordings directly:
```
tools\Compare-ReplayActors.ps1 -Take <30 FPS take id> -Class <text> `
    -Reference replay_<30 FPS take id>_ref_actors.csv -Run replay_<uncapped take id>_ref_actors.csv
```
Read only the per-class `t90` medians and start counts (and per character where both have starts):
the two takes are different playthroughs, so position gaps mean nothing here. Judge as in step 4: slow is
a `t90` longer by a 30 FPS frame or more. Ask for a second pair of takes before concluding from a few
starts. To check a fix the same way, ask for another uncapped take once it is deployed.

## 5. Fix (requested-move walkers)

1. Add the class name to `fix.WALKERS` in `ue4ss/Mods/HighFpsSlidingAndJumpFix/Scripts/fixes/npcwalk.lua`,
   with a comment giving its acc, walk speed and measured `t90`s.
2. `tools\Check-Lua.ps1`, then close the game (check `tools\Invoke-Probe.ps1 state` shows replay=idle),
   `tools\Install-UE4SS.ps1 -ModsOnly -Probe`, then `tools\Restart-Game.ps1 -ViaSteam` (it comes back in
   the same level).
3. Replay uncapped twice more and compare against the same 30 FPS reference. Fixed means `t90` back
   within a frame of 30 FPS in both runs. The fix logs `NPC walk fix: <class> walked ...s (N frames, ...),
   W written` for each move it corrected.
4. Record it: a section in `docs/findings/npc-stalls.md` (class, acc/walk, the t90 table before and
   after), a player-facing line in the mod's `README.txt`, and the `npc-stalls.md` row in `CLAUDE.md`.

If the class is slow but not a requested-move walker (Custom mode, launched, root motion), do not add it
to `WALKERS`: write up the measurement and hand over to the `spyro-fps-bug-hunt` skill.

## Gotchas

- The character list is taken when the take starts playing: a character spawned later is not traced.
- A take crossing a game switch, or a level travel, cannot be replayed: record within one level.
- Power-ups (e.g. a level's super flame) only exist in the replay if the take picks them up itself.
- Kill enemies that would get in the way (Zephyr's bombing birds) before starting the take: the replay
  keeps them dead.
- Mouse-steered charges replay (the stored right-stick X is restored since 2026-11-19).
- The game crashed once ~3 s after `swap 2` (2026-11-19, UE4SS `FindProperty` on a freed field from a
  Lua property read, not yet traced). If a command times out, check the game is still running and
  restart it with `tools\Restart-Game.ps1 -ViaSteam`.
