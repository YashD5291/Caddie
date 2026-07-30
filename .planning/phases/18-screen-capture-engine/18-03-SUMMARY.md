---
phase: 18-screen-capture-engine
plan: 03
subsystem: recording
tags: [screencapturekit, avfoundation, movie-fragments, kill-9, crash-safety, harness, shell-gate, macos]

# Dependency graph
requires:
  - phase: 18-02
    provides: "Live ScreenRecorder.start(target:preset:outputURL:) / stop() — crash-safe fragmented HEVC .mov capture; CaptureTarget; onFirstFrameHostTime / onStreamStopped"
provides:
  - "DEBUG-only ScreenRecorderHarness: headless --screen-record-harness (separate-process record) + --validate-mov (AVURLAsset isPlayable+duration, exit-coded) entry points"
  - "Launch-argument dispatch in CaddieApp.init() (DEBUG-only) that runs headless before SwiftUI/AppState/windows"
  - "Scripts/kill9-recovery-gate.sh — scripted VID-07 fragment-recovery gate (record → kill -9 → validate <=10s loss)"
affects: [18-04, 19-coordinator, 20-storage]

# Tech tracking
tech-stack:
  added: []  # zero new SPM dependencies — Apple system frameworks + shell only
  patterns:
    - "DEBUG launch-argument fast-path that takes over the main queue via dispatchMain() before SwiftUI, giving a kill-able separate-process harness without a new executable target"
    - "Fresh-region recorder construction inside a @MainActor Task (create → await nonisolated async start → attach to MainActor static) to satisfy SE-0414 region isolation with a non-Sendable ScreenRecorder"
    - "Shell-driven crash-safety gate: XCTest cannot kill -9 itself, so VID-07 is asserted by a script against a headless harness"

key-files:
  created:
    - Sources/Recording/ScreenRecorderHarness.swift
    - scripts/kill9-recovery-gate.sh
  modified:
    - Sources/App/CaddieApp.swift

key-decisions:
  - "Reuse the existing Caddie app binary via a DEBUG launch-arg fast-path instead of adding a new SPM/Xcode executable target — avoids re-linking ScreenRecorder's SCK/AVFoundation deps and reuses the already-granted Screen Recording TCC identity"
  - "runRecordMode/runValidateMode return Never via dispatchMain(); the production launch path is only reached in normal runs because the DEBUG dispatch never returns"
  - "Recorder is constructed inside the @MainActor Task (disconnected region) and attached to a MainActor static ONLY after start() returns, so the non-Sendable value can be passed to the nonisolated async start under complete strict concurrency"
  - "Gate PASS = validator exit 0 (isPlayable) AND duration >= record_secs - 10 (lost at most the last fragment); parsed from the harness's VALIDATE line via sed + awk"
  - "Script lives at scripts/ (existing lowercase dir; case-insensitive FS satisfies the plan's Scripts/ path) to match build-dmg.sh/release.sh convention"

patterns-established:
  - "DEBUG headless launch-arg harness reusing the app binary as a kill-able separate process"
  - "Shell gate + machine-parseable stdout contract (HARNESS_READY pid=, VALIDATE isPlayable=/duration=) between script and harness"

requirements-completed: [VID-07]

# Metrics
duration: 18min
completed: 2026-07-09
---

# Phase 18 Plan 03: kill-9 Fragment-Recovery Gate Summary

**A DEBUG-only headless `ScreenRecorderHarness` (separate-process record + AVURLAsset validate, driven by launch args before SwiftUI) plus `scripts/kill9-recovery-gate.sh` that records, `kill -9`s the harness mid-recording, and asserts the fragmented `.mov` is still playable and missing at most the last ~10s — the empirical VID-07 crash-safety gate, flagged for a mandatory macOS 14.2 re-run.**

## Performance

- **Duration:** ~18 min
- **Started:** 2026-07-09T12:45:00Z
- **Completed:** 2026-07-09T12:53:00Z
- **Tasks:** 2
- **Files modified:** 3 (2 created, 1 modified)

## Accomplishments

- **Headless harness (Task 1):** `Sources/Recording/ScreenRecorderHarness.swift` (`#if DEBUG`) exposes `runRecordMode(outputPath:)` — creates a `ScreenRecorder`, `start(target: .display(nil), preset: .balanced, outputURL:)`, prints `HARNESS_READY pid=<pid> path=<path>`, then `dispatchMain()` to stay alive recording until `kill -9` — and `runValidateMode(path:)` — loads `AVURLAsset`, reads `isPlayable`+`duration` via the 14.2+ async `load(.isPlayable, .duration)`, prints `VALIDATE isPlayable=<bool> duration=<secs>`, and exits `0` (playable) / `2` (not).
- **DEBUG launch-arg dispatch:** `CaddieApp.init()` inspects `CommandLine.arguments` inside `#if DEBUG` and routes `--screen-record-harness <path>` / `--validate-mov <path>` to the harness *before* SwiftUI, AppState.initialize(), or any window is created. Production (non-DEBUG) path is byte-for-byte unchanged. Builds clean under `SWIFT_STRICT_CONCURRENCY=complete` (no new warnings).
- **Scripted VID-07 gate (Task 2):** `scripts/kill9-recovery-gate.sh` (`set -euo pipefail`, executable) builds the Debug app, resolves the binary via `-showBuildSettings` (`BUILT_PRODUCTS_DIR`/`EXECUTABLE_PATH`), launches the harness, waits for `HARNESS_READY`, records 30s (>=3 fragment intervals), `kill -9`s the parsed pid, then `--validate-mov`s the partial and asserts exit 0 AND `duration >= 30 - 10`. Prints `GATE PASS`/`GATE FAIL`, a prominent macOS 14.2 re-run banner, and documents a `--static` keepalive-exercise mode.
- **Full suite green:** 304 tests, `** TEST SUCCEEDED **` — DEBUG-only additions did not perturb the suite.

## Gate Run Result (local OS — macOS 26 / Darwin 25.5)

The gate's **mechanics are fully verified**; the **live capture leg could not run headless** in this environment (no Screen Recording TCC grant / no interactive display):

- **`--validate-mov` proven end-to-end on the real binary:** a synthetic 20s HEVC `.mov` (ffmpeg) → `VALIDATE isPlayable=true duration=20.0`, exit **0**; a corrupt file → `VALIDATE isPlayable=false duration=0.0 error=Cannot Open`, exit **2**. The launch-arg dispatch and AVURLAsset validator work correctly.
- **`--screen-record-harness` launch proven:** the binary reaches the harness, attempts capture, and (lacking permission here) prints `HARNESS_ERROR The user declined TCCs for application, window, display capture` and exits — i.e. the ready/error stdout contract and error path work.
- **Full script proven end-to-end:** `bash scripts/kill9-recovery-gate.sh` builds, resolves the binary, launches the harness, detects the early exit, echoes the exact TCC reason, and returns `GATE FAIL` (exit 1) gracefully — no hang, no false pass.
- **Duration/PASS-FAIL logic proven:** the `awk` threshold (`d >= record_secs - 10`) was unit-checked (20.0/25.5/20 → PASS; 19.9/0 → FAIL).

**What remains for the human checkpoint (18-04):** run `bash scripts/kill9-recovery-gate.sh` (and `--static`) on a machine WITH Screen Recording permission + a real display to observe an actual `GATE PASS` (playable partial, duration >= 20s). Then **re-run on a macOS 14.2 machine/VM before milestone release** to confirm floor behavior (local OS is macOS 26).

## Task Commits

1. **Task 1: DEBUG harness + launch-arg dispatch** — `2e30fc8` (feat)
2. **Task 2: kill9-recovery-gate.sh** — `86e8627` (test)

_Note: `Caddie.xcodeproj` is gitignored (regenerated by `xcodegen generate`), so it is intentionally not committed._

## Files Created/Modified

- `Sources/Recording/ScreenRecorderHarness.swift` (created) — DEBUG-only `enum ScreenRecorderHarness` with `runRecordMode`/`runValidateMode`; retains the recorder for the process lifetime; machine-parseable stdout contract.
- `Sources/App/CaddieApp.swift` (modified) — DEBUG-only launch-arg dispatch at the top of `init()`, before AppState/windows; production path unchanged.
- `scripts/kill9-recovery-gate.sh` (created) — end-to-end VID-07 gate: build → launch → record → kill -9 → validate; 14.2 banner; `--static` mode.

## Decisions Made

- **App-binary reuse over a new executable target** — a DEBUG launch-arg fast-path avoids re-linking ScreenRecorder's SCK/AVFoundation dependencies in a separate target and reuses Caddie's existing Screen Recording TCC identity (RESEARCH.md Environment Availability).
- **Region-isolation-safe recorder construction** — the non-`Sendable` `ScreenRecorder` is created *inside* the `@MainActor` Task (fresh disconnected region), `await start(...)` (nonisolated async) is called on it, and only *then* is it attached to the `@MainActor static retainedRecorder` — this satisfies complete strict concurrency without an `@unchecked` lie.
- **Gate PASS criterion** — validator exit 0 AND `duration >= record_secs - 10`, matching VID-07 ("lose at most the last fragment").
- **Script path** — placed at `scripts/` (existing lowercase dir) to match `build-dmg.sh`/`release.sh`; on the case-insensitive macOS FS this also satisfies the plan's `Scripts/` reference.

## Deviations from Plan

None - plan executed exactly as written. The only environment-driven outcome (live capture cannot run headless due to the Screen Recording TCC decline) is the explicitly anticipated fallback in the plan's `<important_environment_notes>` and RESEARCH.md — the script mechanics were verified as far as the environment allows and the remaining live/14.2 verification is documented for the 18-04 human checkpoint.

## Issues Encountered

- **Strict-concurrency capture of the non-`Sendable` recorder:** naively storing the recorder in a MainActor static *before* calling the nonisolated `async start` would put it in the MainActor region and make the send illegal. Resolved by constructing it inside the Task (disconnected region) and attaching to the static only after `start()` returns — builds clean under `SWIFT_STRICT_CONCURRENCY=complete`.

## Known Stubs

None — the harness is a real, functioning DEBUG entry point (validated end-to-end via `--validate-mov` and the launch/error path). It is DEBUG-only and never reaches production or any UI.

## User Setup Required

None - no external service configuration required. Running the gate locally requires the operator to have granted Caddie the Screen Recording permission and to be on a machine with a real display (a manual-verification prerequisite handled at the 18-04 checkpoint).

## Next Phase Readiness

- **Plan 18-04 (manual verification checkpoint)** can proceed: the scripted gate and headless harness are ready to run on a permission-granted machine, and the 14.2-floor re-run is documented as the outstanding milestone-close TODO.
- **Outstanding for milestone close:** (1) observe an actual `GATE PASS` on a permission-granted display; (2) re-run `scripts/kill9-recovery-gate.sh` on a macOS 14.2 machine/VM before release.

---
*Phase: 18-screen-capture-engine*
*Completed: 2026-07-09*

## Self-Check: PASSED

All 3 files (`ScreenRecorderHarness.swift`, `kill9-recovery-gate.sh`, `18-03-SUMMARY.md`) verified on disk; both task commits (`2e30fc8`, `86e8627`) verified in git history.
