---
name: restart-game
description: >
  Restart Spyro Reignited Trilogy and load into Spyro 1, 2 or 3, optionally travelling to a
  particular level (LS###), without a human touching the menus. Use when a Lua change needs a game
  restart to load, when the game crashed or is sitting at the title screen, or when a test needs
  Spyro standing in a specific level. Works from a Claude session with computer use (start, focus,
  quit the game) plus the synced game folder (arm the probe's resume files).
---

# Restart the game and load into a level

The probe already knows how to get back into a level by itself: `lib/resume.lua` notes the current
level, game index and save slot to `resume.txt` every 5 s while anyone plays, and if `resume.go`
exists at the probe's **first update tick** it drives the title screen (Continue, then the game
pick), waits for a pawn and travels to the noted level (`docs/probe.md`, "Restarting from outside
the game"). `tools/Restart-Game.ps1` is the same flow for a human PowerShell prompt; this skill is
the same flow driven by Claude. **Everything below assumes the probe is deployed**
(`Install-UE4SS.ps1 -Probe`).

Paths (Claude's Linux VM): game UE4SS folder `$HOME/mnt/ue4ss`, probe folder
`$HOME/mnt/ue4ss/Mods/SpyroFpsProbe`, log `$HOME/mnt/ue4ss/UE4SS.log`.

## 1. Close the game if it is running

- Deploy any edited Lua **before** starting the game (CLAUDE.md: deploying while it runs can crash
  it; a hot reload rarely picks everything up anyway — a restart is the only reliable load).
- Computer-use access: the shipping exe resolves **only while the game is running**, and only by
  its basename — `computer_resolve_access(["spyro-win64-shipping.exe"])`; the display name
  `Spyro-win64-shipping` and the full path both return notInstalled. Declare
  `systemKeyCombos: true` in the same resolve if the quit will use Alt+F4. A grant lasts the
  session but **expires after 30 min without computer-use activity** — then resolve and request
  again.
- Quit from the title screen or a level: focus the game (`computer_open_application
  "Spyro-win64-shipping"`), then Alt+F4. Closing the window is clean for the save file; only the
  loaded-level note is lost, which is what `resume.txt` is for.
- Confirm it is gone: `computer_resolve_access` for the basename returns notInstalled again
  (process-gone check from the VM is not possible — the crash-dump folder is not synced).

## 2. Arm the resume (after the game is closed)

Write both files into the probe folder. **Order matters**: while the game runs it rewrites
`resume.txt` every 5 s, so a hand-written target level survives only if the game is already gone.

```bash
P=$HOME/mnt/ue4ss/Mods/SpyroFpsProbe
printf 'LS102 0 0\n' > $P/resume.txt   # level, game index, save slot
printf 'go' > $P/resume.go
```

- Game index is 0-based: `LS1## 0`, `LS2## 1`, `LS3## 2`. Keep the slot the existing `resume.txt`
  had unless the task says otherwise (it is the player's save slot).
- To load a game's hub without a particular level, keep the level the save is in (what
  `resume.txt` already says) or any level of that game; resume travels only if the save loads
  elsewhere.
- Writes from the VM (`printf`, heredocs) carry no BOM. PowerShell writes do (CLAUDE.md) and a
  BOM breaks the level match — resume strips it from `resume.txt` but write clean anyway.
- `resume.go` is consumed at the probe's first tick and deleted; a crash mid-resume does not loop.

## 3. Start the game

Preferred, in order:

1. `computer_open_application "Spyro-win64-shipping"` — launches the exe **directly** when it is
   already in this session's allowlist (granted earlier while it ran). No Steam UI involved.
2. Steam library, when there is no grant yet (fresh session, game not running): access Steam
   **and** `steamwebhelper.exe` (Steam's window content is drawn by the helper — without it the
   whole library is a masked rectangle), then double-click the game in the left library list.
   Clicking the Play button also works when nothing covers it.

Steam marks the game as running for ~15 s after the process dies; a launch in that window does
nothing. Wait and retry once.

## 4. Confirm the boot is healthy

A verified good boot (2026-11-16, via Steam): `loaded; trackers on:` ~15 s after launch,
`resume: armed` 2 s later, `resume: back in LS102 after 13 s`. If `loaded;` has not appeared
within ~60 s, or appeared but no `resume: armed` follows within ~30 s, the boot is bad: one
observed failure mode is the DRM race below (no mods at all), another was a boot that loaded mods,
never ticked and silently exited. Screenshot the desktop to see what actually happened
(title screen? gone?), bring the game frontmost (`computer_open_application`), and if it is dead
or modless, quit it (Alt+F4) and relaunch **through Steam**.

## 5. Watch the log

`UE4SS.log` is truncated per launch. Poll for, in order:

- `loaded; trackers on:` — the probe is in.
- `resume: armed for LS### (game N, slot M)` — the flag was consumed.
- `resume: picked game N from the menu` (or the `start game` fallback line).
- `resume: back in LS###` / `resume: arrived` — done, Spyro is standing in the level.
- `resume: gave up` / `can't travel` — read the surrounding lines; usually the level name was
  wrong or the menu never appeared.

Gotcha from `Restart-Game.ps1`: a **direct** exe launch can start before Steam's DRM wrapper has
decrypted the game code — UE4SS then logs failed pattern scans, no mods load and no `loaded;` line
appears within ~60 s. Quit the game and relaunch **through Steam**, which always decrypts first.

Allow ~1–3 min from launch to `back in`; `resume.lua` gives the whole thing up at 300 s.

The probe's command channel also shows whether it is ticking and where Spyro is, without reading
the log (see "Command channel" in `docs/probe.md`). `ping` answers as soon as the probe ticks, even
at the title screen. `state` waits for Spyro and then reports `level=LS###`.

- On the game PC: `tools\Invoke-Probe.ps1 state -Timeout 180`, which waits and prints the answer.
  When the session runs on that PC itself, `tools\Restart-Game.ps1` does steps 1–5 in one go
  (close, arm, start, wait for `back in`). Deploy between closing and starting.
- From the VM: write `@r1 state` into `$P/cmd.txt` and look for the `r1` line in `$P/cmd_result.txt`
  (`r1<TAB>ok<TAB>level=LS102 cap=...`). The probe empties that file when it loads, so lines from
  before the restart are gone. Use a new id for each command.

## 6. Verify before testing

- The log shows the expected level and no `error:` lines (CLAUDE.md: per-frame errors log once).
- Set the frame cap for the test through the command channel, not a key: `cap 30` (or 60, 120, 320,
  0 for uncapped) with `tools\Invoke-Probe.ps1`, or a line in `cmd.txt` from the VM. It needs no
  window focus. Every other probe hotkey works the same way with `key <NAME>` (`keys` lists them).
- Keys sent through computer use are only needed for what the probe does not handle: moving Spyro by
  hand, and menus. For those, follow the focus rule: `computer_open_application` first, then keys.
  If a key lands elsewhere the tool reports a focus error; re-focus, never work around it.
