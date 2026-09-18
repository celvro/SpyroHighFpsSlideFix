# Frame spikes (cause found and fixed 2026-09-15)

Reported for 1.2.0: periodic hitches at high FPS, very visible even when idle and only turning the camera.

- **Cause: a `StaticFindObject` that finds nothing costs ~10–11 ms** (it scans the whole object array); one that finds its object costs ~0 ms. Measured 2026-09-15 12:38 (`UE4SS.log`, os.clock timing): druid montage and dragon `UpdatePrevActors` misses took 10–11 ms each; the mouse and dust hook lookups (hits) took 0.0 ms.
- 1.1.0 looked up the druid montage every 60 frames forever, on every level. 1.2.0 added the dragon function lookup on the same frame, so ~21 ms was lost every 0.4 s at 144 FPS. That was also the 12–27 ms profiler max spikes (present with or without the dragon fix, since the druid lookup always ran). GC and profiling overhead had been ruled out earlier that day (spikes unchanged with the collector fully stopped).
- First fix (at most 10 lookups after each new pawn) removed the hitches, but a slow Alpine Ridge load outlasted those lookups and the druids broke again.
- **Current fix, verified 2026-09-15 12:48–12:50:** nothing polls. `NotifyOnNewObject` on `/Script/Engine.BlueprintGeneratedClass` (`CharacterInputComponent_Spyro_C`, `BP_CPS1999_Playable_C`, `BP_CBS3012_FireDragon_C`) and `/Script/Engine.AnimMontage` (`AM_CES1035_GreenDruid_Casting_Up`) grants that fix 10 lookups (one per 60 frames), run from the tick; each also gets 1 lookup at startup. A found montage with no `Notifies` yet keeps retrying (found lookups are free), as does a found dragon function whose RegisterHook fails (capped at 200 failures).
- Verification log: no errors; druid notify patched at 12:48:31, 12:48:46 and 12:49:09 (the montage is recreated on each druid level load, and each load was caught); mouse and dust hooks registered 12:48:32; dragon hook registered 12:50:07 in Fireworks Factory. Druids and dragons worked, including Alpine Ridge after its slow load.
- Rule: never poll `StaticFindObject` for something that may not exist.

