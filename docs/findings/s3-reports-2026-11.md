# Spyro 3 reports not reproduced (2026-11-19)

Two of the five reports of 2026-11-19 could not be reproduced unattended (no hand-played takes were available).
What was tried, and where to pick each up. The other three are fixed: Gulp (`npc-stalls.md`), Bamboo Terrace's
barrels (`bamboo-barrels.md`), Frozen Altars' lasers (`frozen-altars-lasers.md`).

## Sunrise Spring head-bash rock and egg (LS301)

Report: "Jump and press triangle to break the rock and reveal an egg next to Molten Crater: Spyro gets stuck."

- **The rock:** `BP_S2_TreasureChest_HeadbashRock_C` "Boulder", 407 units from the LS304 portal, beside
  `Egg_Liam` (`QuestEggController_C`). `LS_301_Rock_And_Roll_Camera_Blueprint` rotates the rock each tick from an
  animated socket while its state is `Rotate` (a teleporting `K2_SetActorRotation`).
- **Reaching it:** the rock's top is a dome; Spyro dropped on it always slides off to its foot, ~72 units from the
  center. A head bash needs a jump (Triangle during a plain fall does nothing). What worked: Spyro 120 units behind
  the rock along the camera's facing, 0.15 s of stick forward, jump, Triangle (`InputAction_FaceTop`, added to
  `lib/input.lua`'s `BUTTONS` at runtime) at the apex.
- **Uncapped, once:** the rock broke (state `Death`), Spyro landed, was moved to the rock's center ~0.8 s later
  (the egg reveal) and could not move for at least 4 s, then walked normally when tried a few seconds later. That
  fits the hatchling moment, which holds Spyro at any framerate; it was not stuck for good.
- **Why no 30 FPS control:** the rock cannot be reset. `BP_TreasureChest_BASE` "restore save data" puts it straight
  into `State_Death` whenever any of its gems has a save record under its name (`getSaveDataForActorByName`), and
  the probe's `reload` brings it back broken. The egg's reveal is quest-board state (`QuestSaveData`). Clearing
  both is the next step: the gem records, by name, and the egg's quest entry.

## Lost Fleet skateboard and Hunter (LS320)

Report: "In the skateboard section of Lost Fleet, Spyro often wipes out on nothing. Also when talking to Hunter
there he slowly slides around."

- **Wipeouts are native.** `GA_Spyro_Skateboard` only reacts to `Character.Event.Skateboard.Crash`; Spyro's
  Blueprint sends it when a native skateboard state machine enters `Crash` (`IsSkateboardCrashing`). The reflected
  skateboard settings include `SlideAlongSurfaceCrashSpeed`, `CrashLinImpulseRange`, `CrashAngImpulseRange`: a crash
  when sliding along a surface faster than a threshold. A suspect at high FPS: more frames blocked by small seams or
  lips (as with the Skelos Badlands lizard's steps), each counting as sliding along a surface. Confirming needs the
  native code (`tools/Read-GameVtables.ps1 -OutExe`, `dumpbin`).
- **Scripted runs did not show it.** Spyro put into the level's one `BP_SkateboardTriggerVolume_C` starts
  skateboarding (custom movement mode 4); steering in a fixed world direction: 0° crashes at the same spot and time
  at 30 and ~290 FPS (a real obstacle 290 units ahead), 180° the same at 330 units, 90° and 270° mostly ended the
  skateboarding without any crash at both caps. One 270° uncapped run crashed at speed 414 where 30 FPS did not, and
  three repeats did not crash at either cap.
- **Hunter** (`BP_CNS3707_HunterSkater_C` "CNS2111_Hunter_TEMP", 455 units from the skate volume): `MaxAcceleration`
  650, `MaxWalkSpeed` 400, `BrakingDecelerationWalking` 150, on the 1/32 grid, which is the low-acceleration,
  slow-braking profile that rounds badly. Talking to him (Triangle and Space from 150–160 units, in front and at his
  side) opened the conversation, but he never moved or turned in 12 s at ~300 FPS. If he does move in the reported
  case, `fixes/npcwalk.lua`'s `WALKERS` is where he would go once measured.
