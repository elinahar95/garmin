# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A **Connect IQ data field** (Monkey C) for the Garmin Fenix line — a live race pacer that goes beyond Garmin's offline-only PacePro by recomputing targets from live sensor + course + weather inputs. Currently a personal project of one user, new to Monkey C.

`plan.md` is the **authoritative design doc** and roadmap. Read it before suggesting any architectural change. The plan encodes deliberate decisions (rule-based v1 → learned-correction v2; HR-zone safeguard always wins over learned model output; phone-companion app is a fallback, not the default; LightGBM-codegen-to-Monkey-C is the chosen model deployment path) that shouldn't be relitigated casually.

A higher-level workspace CLAUDE.md lives at `/Users/lina/coding_projects/CLAUDE.md` and covers cross-project conventions and the parent `garmin_project/` layout (including the `developer_key` file, which is a Garmin signing key — don't commit changes to it or echo its contents).

## Current implementation state

The Connect IQ project lives in `gene/` and corresponds roughly to **Phase 2** of `plan.md` (grade-adjusted pace data field). Phases 3+ (course planner, live re-planner with HR/weather rules, learned model) are not yet built.

What's actually implemented in `gene/source/`:

- `geneApp.mc` — minimal `Application.AppBase` boilerplate; entry point returns a single `geneView`.
- `geneView.mc` — the data field. Three concerns inside `compute()`:
  1. **EMA-smoothed pace** (`alpha=0.2`) from `info.currentSpeed`. Gated on `speed > 0.5` m/s to avoid divide-by-near-zero on stops.
  2. **Ahead/behind plan** in seconds, derived from `elapsedDistance` vs `timerTime * raceDistanceM/targetTimeSec`.
  3. **Grade + GAP pace** via a 10-entry circular buffer of `(altitude, distance)` samples, sampled **every 5 m of distance travelled** (not every second — see plan.md Phase 2 for the rationale: distance-triggered sampling keeps the noise-to-signal ratio consistent across paces). Grade clamped to ±0.30. GAP applies the **Minetti (2002)** energy-cost polynomial: `C(i) = 155.4i^5 − 30.4i^4 − 43.3i^3 + 46.3i^2 + 19.5i + 3.6`, then `GAP = pace × 3.6 / C`.

**Unit gotcha**: configuration is metric (`raceDistanceM` in metres, `targetTimeSec` in seconds, stored in `Properties`), but the displayed pace strings are **min/mile** — `paceStr()` is fed `secPerMile`, and the planned-pace conversion multiplies by `1609.344`. If you change units, change both the conversion at init and `paceStr`'s parameter name.

**Manifest currently targets `fenix7s` only** (`gene/manifest.xml`), even though `plan.md` discusses Fenix 7/8 broadly. Add other products via the VS Code "Monkey C: Edit Products" command rather than hand-editing the XML — the manifest is marked as generated.

## Build / run

There is no shell-driven build. The project was scaffolded with the **VS Code Monkey C extension** (the manifest comments reference its commands), which is the supported toolchain alongside the **Connect IQ SDK** simulator. Common commands are exposed via the VS Code command palette:

- `Monkey C: Build for Device` — produces `gene/bin/gene.prg` (currently checked in; there is no `.gitignore`, so build artifacts can pollute commits — verify what you're staging).
- `Monkey C: Run in Simulator` — launches the simulator targeting the products listed in `manifest.xml`.
- `Monkey C: Edit Application` / `Edit Products` / `Edit Permissions` — the right way to mutate `manifest.xml`.

For verification, prefer the simulator's **FIT replay** feature using `../sample_run_activity.fit` (a real activity, kept as a fixture for exactly this purpose). Per `plan.md` the validation loop is: replay a known FIT, capture the recommendations stream, hand-check a few key timestamps. Memory headroom should stay roughly under 32 KB peak in the simulator's "Active Memory" view; the app envelope is ~128 KB total and `Properties` storage is capped at ~8 KB — design with both in mind.

## Adding new functionality

When extending the data field, follow the plan's phased structure rather than reaching for the end state:

- New rules belong in the **rule engine** (Phase 4 in plan.md), even once a learned model exists. The HR-zone safeguard and other rule-based safety floors are designed to outrank model output — preserve that ordering.
- Don't introduce TF Lite, matrix libs, or runtime model parsers. The agreed deployment path for any model is **offline-trained → codegen to Monkey C source** (LightGBM trees as nested if/else, or a tiny MLP with weights as a static `Array<Float>` and a hand-written forward pass).
- Course elevation profile extraction (`Toybox.PersistedContent.Course`) is an **open question** in the plan — verify what it actually exposes before designing around it; the companion-app fallback (Phase 5) only becomes mandatory if the on-device API is insufficient.
- The `gene/resources/` tree (`settings.xml`, `properties.xml`, `strings.xml`, `drawables/`) is the standard Connect IQ resource layout; any new user-facing setting needs entries in **both** `properties.xml` (default + type) and `settings.xml` (UI), plus a label in `strings.xml`.

## Loose files in this directory

- `start.py` — empty placeholder. Don't read into the name; no Python is part of the data field. The plan reserves a Python pipeline for **Phase 6** (offline LightGBM training from FIT files) but it doesn't exist yet.
- `sample_run_activity.fit` — fixture for FIT replay verification (above).
- `README.md` — one-line stub.
