# Spyro 1 flight levels

**Status: matches 30 FPS. No fix needed.** Measured 2026-09-18 in Night Flight (LS111) with the probe's `flight` tracker (`trackers/flight.lua`).

## How flight works

- Spyro is in MovementMode Flying (5) for the whole level. The movement code is native. `GA_Spyro_Fly` has no per-frame logic: it only applies and removes gameplay effects, plays montages (crash) and pushes camera settings.
- `GE_SpyroFlightSpeedControl` overrides the `MaxFlySpeed` attribute (PhasmidMovementAttributeSet). The value changes all the time with pitch. It is 309 at the start of the level, climbs to ~660 in dives and drops to ~380 in climbs. Velocity follows it with a lag of well under a second.
- CMC `MaxAcceleration` is 1000 while flying and 1500 around the entrance and exit. `BrakingDecelerationFlying` is 5.
- None of the fix mod's fixes touch Flying mode.

## Measurement

The first half of Night Flight, flown once uncapped (~500 FPS on average, dt 1–10 ms) and once at the 30 FPS cap, following the same route by hand. Both runs are aligned on the level-entrance frame (z ≈ 1220, v = 0):

| t (s) | path, uncapped | path, 30 FPS |
|---|---|---|
| 4 (scripted entrance, no input) | 1323 | 1327 |
| 10 | 3363 | 3372 |
| 20 | 8151 | 8144 |
| 30 | 12802 | 12835 |
| 38 | 17154 | 17216 |

- `flightrun`: uncapped 39.35 s, path 17703.5, avg 449.9. At 30 FPS: 39.14 s, path 17661.2, avg 451.2 (+0.3%).
- The scripted entrance involves no input, so it is the cleanest comparison. At 4 s the two runs are 0.3% apart. The per-second `flight` lines (speed and MaxFlySpeed) track each other to within the variation of flying by hand.
- Rate of speed change binned by pitch (sin = vz / |v|): for every bin with enough samples at 30 FPS (−0.5 to +0.5), the average dv/dt matches within noise, e.g. climbing at 0.3–0.4 gives −80.7 in both runs. The steep bins (|sin| > 0.8) come from the entrance drop and have fewer than 20 frames at 30 FPS.

## Not measured

- Speed boost / brake inputs: `charge` and `jump` stayed at 0% in both runs. Check them with `flightramp` lines if a boost ever feels different.
- Other flight levels (Sunny, Crystal, Wild Flight) and Spyro 2/3 speedways use the same ability, so they are expected to behave the same way. They weren't measured.
