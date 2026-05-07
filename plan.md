# Live Adaptive Pacer for Garmin (Monkey C)

## Context

Garmin's **PacePro** is offline only. Garmin Connect pre-computes per-split target paces from the course's elevation profile, syncs the plan to the watch, and the watch just shows running over/under. It never recomputes mid-race when you blow up at km 6, the temperature jumps 8°C, or HR drifts above the lactate threshold. You want to fill that gap: a **live, sensor-driven pacer** that revises the remaining-distance plan every few seconds based on physiology + course + weather, and surfaces concrete cues ("ease off — hill ahead," "you have 20s in the bank, push the next km").

PacePro does include one pre-race adjustment: a **hill effort level** slider (configured in Garmin Connect before syncing) that scales how aggressively split targets compensate for elevation — lower effort = gentler hill adjustment, higher effort = tighter grade correction. This is still static (baked in before the run), but it's a user preference we should match. Our v1 should expose the same knob via a `Properties` setting (e.g. `hillEffortLevel` 1–5) that scales the GAP correction multiplier in the rule engine.

You own/target a **Fenix 7/8**, are new to both Monkey C and on-device ML, prefer a **rule-based v1 → learned-model v2** sequence, and have your own FIT files for training. This plan is built around that.

---

## Feasibility Verdict

**Doable, with one important reframing:** Monkey C has no TensorFlow Lite, no native NN library, no matrix BLAS. There is no "save trained model, watch loads it." Any model becomes hand-coded inference: weights baked into the `.mc` source as a static array, with a hand-written forward pass.

That sounds limiting but actually fits the problem. Pacing is a low-dimensional regression — maybe 10–15 input features (current pace, HR, HR drift, distance done/remaining, cumulative grade, upcoming-1km grade, temp, humidity, time-in-zone, deviation-from-plan). A **gradient-boosted tree (XGBoost/LightGBM) with depth ≤4 and ≤50 trees**, or a **2-layer MLP with 16 hidden units** (~1–3 KB of weights), is more than enough capacity and fits comfortably in the 128 KB app envelope.

What works in your favor on Fenix 7/8:
- **Sensors** are all native: HR, GPS, barometric altitude, cadence, ambient temp via `Activity.Info` and `Sensor.Info`.
- **Weather is built in** via `Toybox.Weather.CurrentConditions` — temp, wind speed/bearing, humidity, pressure, UV — fetched through the paired phone.
- **Course/route** support exists, but extracting *remaining-elevation profile* on-device is the trickiest watch-side piece — likely needs phone-companion pre-processing.
- `compute()` runs ~1 Hz in a custom data field; plenty of headroom for the inference cost we're talking about.

What does NOT work:
- No "sweat sensor" exists on Garmin. Substitute with HR drift × ambient temp × humidity (a heat-stress proxy). Fenix 8 adds wrist skin temp, which helps but isn't transformative.
- Persistent storage capped at ~8 KB (`Properties` API). The course profile and any cached state must respect this.
- App total < 128 KB recommended. Fine for our model sizes; rules out anything resembling a CNN.

---

## Architecture (Final State)

```
                    ┌───────────────────────┐
                    │  Phone Companion App  │   (optional, Phase 3+)
                    │  - parses GPX/FIT     │
                    │  - elevation profile  │
                    │  - weather pull       │
                    │  - posts JSON to watch│
                    └───────────┬───────────┘
                                │ Toybox.Communications
                                ▼
   ┌────────────────────────────────────────────────────────────┐
   │  Watch-side Data Field (Connect IQ, Monkey C)              │
   │                                                            │
   │  inputs (Activity.Info / Sensor.Info / Weather, 1Hz):      │
   │   currentSpeed, currentHeartRate, altitude,                │
   │   elapsedDistance, elapsedTime, currentLocation,           │
   │   ambient temp, humidity, wind                             │
   │                                                            │
   │  state (rolling buffers, ~30–120s):                        │
   │   HR drift, pace EMA, grade EMA, time-in-zone              │
   │                                                            │
   │  static plan (loaded once):                                │
   │   target finish time, distance, per-meter elevation,       │
   │   initial split table                                      │
   │                                                            │
   │  re-planner (every N seconds):                             │
   │     v1: rule-based (heuristics below)                      │
   │     v2: learned model (weights baked in, hand-coded fwd)   │
   │                                                            │
   │  outputs (rendered + alerted):                             │
   │   target pace next 500m, slow/hold/push cue,               │
   │   ahead/behind plan (s), warning ("hill in 200m")          │
   └────────────────────────────────────────────────────────────┘
```

### Rule-based core (v1) — what the heuristics actually are

1. **Grade-adjusted pace correction.** Apply Strava-style GAP polynomial (well-known closed form) to current pace and to the planned pace for the upcoming 500m, so we always compare like for like.
2. **HR-zone safeguard.** If `currentHeartRate > zone4_threshold` and remaining distance > 30%, ratchet the next-segment target *down* even if behind plan. Blow-up prevention dominates pace ambition.
3. **HR drift compensation.** Compare current HR-vs-pace ratio to the first-5-min baseline. >5% drift in hot conditions → lower target pace by a calibrated amount (Lucia/Coyle-style cardiac drift literature gives reasonable starting constants).
4. **Look-ahead grade.** From the elevation profile, compute average grade for the next 250 m and 1 km. If a >3% climb is within 200 m → pre-emptively soften target. If a sustained descent follows → bank seconds on the descent.
5. **Bank/debt accounting.** Track cumulative seconds ahead/behind plan. Distribute the delta across remaining splits proportional to "easy" segments (flat or downhill), not equally.
6. **Thermal stress modifier.** Heat index (from temp + humidity) above ~24°C WBGT-equivalent → cap aggressive catch-ups; above ~28°C → recommend slower-than-original plan regardless of cushion.

These rules are 200–400 lines of Monkey C. They give a defensible, debuggable baseline and become the **teacher signal** for the learned v2.

### Learned model (v2)

- **Train offline in Python** from your FIT-file history. Features as listed above; label = "what pace did I actually run for the next 500m, conditional on finishing within X% of goal time on this run." Pull only your good runs as positive examples; treat blow-ups as negative.
- **Model class**: start with **LightGBM, depth 4, 50 trees**. Export each tree as a nested if/else in a Monkey C function (small Python script does the codegen). No runtime parser needed; the trees become straight-line code. Total size: usually <10 KB.
- **Alternative**: a **2-layer MLP, 16 hidden, ReLU, fp32**, weights as a static `Array<Float>`, dot products written by hand. ~1.5 KB weights, ~600 multiplies per inference — trivial at 1 Hz.
- **Hybrid option (best long-term)**: physics/rule baseline computes a target pace; the learned model outputs only a *correction* (±X sec/km). Smaller, more robust, far easier to validate.
- **Safety floor**: never let the learned model override the HR-zone safeguard. The rule-based blow-up prevention stays in front of the model.

---

## Phased Roadmap

### Phase 0 — Toolchain & First Data Field (1–3 days)

You're new to Monkey C, so step zero is "make the watch say hello."

- Install **Connect IQ SDK** + **VS Code Monkey C extension** (replaces the old Eclipse tooling). Set up the simulator targeting `fenix7` / `fenix8`.
- Build the official **Hello World data field** sample. Run it in the simulator. Sideload it to your watch via USB.
- *Deliverable*: a data field that shows "Hello" on a workout screen on your actual Fenix.

### Phase 1 — Static Pace Field (3–7 days, learning project)

A purposeful warm-up that teaches every API you'll need later.

- App settings (via `Properties`): `targetTimeSec`, `raceDistanceM`.
- Data field shows three numbers, updating each `compute()` tick:
  - planned pace (target / distance)
  - current pace (`Activity.Info.currentSpeed`, smoothed with a small EMA)
  - cumulative ahead/behind (s)
- *Skills earned*: `compute()` lifecycle, `Activity.Info`, `Properties`, layout XML, simulator debugger, sideloading, log output.

### Phase 2 — Grade-Adjusted Pace Field (1 week)

Adds the first real signal-processing step.

- Sample altitude every **5 metres travelled** (not every second) into a 10-entry circular buffer → 50 m window regardless of pace. A time-based window (e.g. 10 s) gives fast runners ~27 m and slow runners ~11 m, making grade noise-to-signal ~2× worse for slow runners. Distance-based sampling keeps accuracy consistent for all paces.
- Compute grade from oldest→newest buffer endpoints: `Δaltitude / Δdistance`. Clamp to ±0.30 to prevent formula blowup on sensor spikes.
- Apply Minetti (2002) GAP correction: `C(i) = 155.4i⁵ − 30.4i⁴ − 43.3i³ + 46.3i² + 19.5i + 3.6`; `GAP = rawPace × (3.6 / C(grade))`.
- Display: target pace (top), GAP pace (middle / hero metric), raw pace + grade + ahead/behind (bottom row).
- *Skills earned*: distance-triggered circular buffers, filtering, numerical math, dealing with sensor jitter and dropouts.

### Phase 3 — On-Watch Static Planner (PacePro Clone) (2–3 weeks)

This is the first version of the actual product. **Still no live re-planning**; just proves the data path end-to-end.

- Load a course onto the watch the normal way (sync from Garmin Connect).
- On data field init, read the course's elevation profile via `Toybox.PersistedContent.Course` (or, if that proves limited, ship the profile as a separate JSON via the companion app — see Phase 5).
- Pre-compute split targets using the same gradient-adjusted approach PacePro uses.
- Display: current split target pace, ahead/behind cumulative, next-split preview.
- **Validate**: run a real workout (or simulate via the Connect IQ simulator's FIT replay) and confirm targets match a hand-computed expectation.

### Phase 4 — Live Re-planner, Rule-Based (3–4 weeks)

The first version that's actually adaptive.

- Add the heuristic engine described above (HR safeguard, drift, lookahead, bank/debt, thermal).
- Re-run the planner every ~10 s (not every second — too jittery for the user).
- Add visible cues: a chevron ▲▼= for push/ease/hold; an alert banner for upcoming hills.
- Wire `Toybox.Weather.CurrentConditions` for temp/humidity at activity start (and refresh hourly via phone).
- **Validate** by replaying your past FIT files in the simulator and inspecting recommendations vs. what actually happened. Then run a real medium-effort workout.

### Phase 5 — Companion Phone App (optional, 1–2 weeks)

Only needed if Phase 3 hits the wall on reading raw course elevation. Build a minimal Android/iOS companion using Garmin's Mobile SDK that:
- Pre-processes the GPX/course file into a compact per-100m elevation array.
- Pulls weather forecasts for the race start time.
- Pushes a JSON blob to the watch via `Communications.makeWebRequest` / `transmit`.

Skip if `PersistedContent.Course` turns out to expose enough.

### Phase 6 — Learned Correction Model (2–4 weeks, mostly Python)

- Export your last ~50–100 runs as FIT files from Garmin Connect (you said you have these).
- Python pipeline (pandas + fitparse): turn each run into rows of `(features_at_t, pace_in_next_500m)`.
- Filter for "successful pacing" runs (finished within X% of an implied goal).
- Train **LightGBM** (depth 4, 50 trees) predicting *correction-vs-rule-baseline* (the hybrid framing — strongly recommended).
- Cross-validate with leave-one-run-out.
- Codegen script: emit each tree as nested Monkey C if/else.
- Drop the generated `.mc` into the project. Gate behind a "use learned model" setting so you can A/B against rule-based on real runs.

### Phase 7 — UX polish (ongoing)

Vibration patterns for cues, configurable units, audio prompts, post-run summary screen. Save for last.

---

## Critical APIs to Know (bookmark these)

- `Toybox.WatchUi.DataField` — the app type you're building. `compute(info)` and `onUpdate(dc)`.
- `Toybox.Activity.Info` — currentSpeed, currentHeartRate, elapsedDistance, elapsedTime, altitude, currentLocation, totalAscent.
- `Toybox.Sensor.Info` — secondary sensors (cadence on a footpod, etc.) if needed.
- `Toybox.Weather.CurrentConditions` — temperature, windSpeed, windBearing, relativeHumidity, precipitationChance.
- `Toybox.Communications.makeWebRequest` — phone-bridged HTTP, for weather refresh or companion-app sync.
- `Toybox.PersistedContent.Course` — to read the active loaded course (verify in Phase 3 how much you can extract).
- `Toybox.Application.Properties` — settings storage; keep payload <8 KB.
- `Toybox.System.println` — your printf debugger.

---

## Verification

End-to-end, repeatable check that exercises the full stack:

1. **Simulator FIT replay**: Connect IQ simulator can replay a `.fit` file as live activity input. Take one of your past runs, replay it, and watch the field react. Save the recommendations stream to a log; verify by hand on a few key timestamps.
2. **Property fuzz**: vary `targetTime`, run the same FIT replay, confirm recommendations scale sensibly (faster goal → push earlier; slower goal → conservative).
3. **Rule-vs-model A/B**: with the v2 model gated, replay 5 held-out FIT runs through both modes; compare predicted pace to actually-run pace. Surface MAE per split.
4. **Live workout**: a tempo or progression run on a known route. Real ground truth.
5. **Memory check**: simulator's "Active Memory" view — keep peak under ~32 KB headroom on the data-field budget.

---

## Risks & Open Questions (revisit at each phase)

- **Course elevation extraction on-device**: not certain `PersistedContent.Course` exposes a full per-meter elevation array. If it doesn't, Phase 5 (companion app) becomes mandatory rather than optional. Verify in Phase 3.
- **Body Battery / Stamina / HRV**: these higher-level Garmin metrics may not be exposed via Connect IQ even on Fenix 7/8 — `Activity.Info` does not list them. Check the `Toybox.UserProfile` and `Toybox.SensorHistory` modules during Phase 1; if exposed, they're great inputs to the rule engine.
- **Training data quality**: 50–100 of your own runs is enough for LightGBM but only learns *your* pacing. That's fine for v2. Cross-athlete generalization would need much more data and is out of scope.
- **Battery**: per-second `compute()` plus weather refresh plus periodic re-planning should be cheap, but verify after Phase 4 with a long run — Connect IQ apps can drain noticeably if poorly written.
- **Audio/vibration prompts**: confirm `Toybox.Attention.vibrate` and tone APIs work mid-activity from a data field; some prompt types are restricted to widget/app contexts.
