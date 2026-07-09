---
phase: 18
slug: screen-capture-engine
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-07-09
---

# Phase 18 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | XCTest (xcodebuild, XcodeGen project) |
| **Config file** | `project.yml` (regenerate with `xcodegen generate` after adding files) |
| **Quick run command** | `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -only-testing:CaddieTests/ScreenRecorderTests` (class name per plan) |
| **Full suite command** | `make test` (require `** TEST SUCCEEDED **`) |
| **Estimated runtime** | quick ~60s · full ~5–10 min |

---

## Sampling Rate

- **After every task commit:** Run the targeted `-only-testing` quick command for the touched test class
- **After every plan wave:** Run `make test` (full suite)
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** ~600 seconds (full suite)

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 18-01-T3 | 18-01 | 1 | VID-05 | unit | `-only-testing:CaddieTests/ScreenRecorderFilterTests` (filter-selection/Caddie-exclusion) | ❌ W0 | ⬜ pending |
| 18-01-T2 | 18-01 | 1 | VID-06 | unit | `-only-testing:CaddieTests/ScreenRecorderConfigTests` (preset fps/bitrate/dimension) | ❌ W0 | ⬜ pending |
| 18-01-T2 | 18-01 | 1 | STOR-04 | unit | `-only-testing:CaddieTests/ScreenRecorderConfigTests` (hostTicksToSeconds) | ❌ W0 | ⬜ pending |
| 18-01-T3 | 18-01 | 1 | — | unit | `-only-testing:CaddieTests/ScreenRecorderStateTests` (state machine/idempotent stop/frameAction) | ❌ W0 | ⬜ pending |
| 18-02-T1 | 18-02 | 2 | VID-05/06/STOR-04 | build+impl | SCStream+writer setup, first-frame anchor, filter (build green) | ❌ W0 | ⬜ pending |
| 18-02-T2 | 18-02 | 2 | VID-07 | build+impl | .mov + movieFragmentInterval, keepalive, async finalize (build green) | ❌ W0 | ⬜ pending |
| 18-03-T2 | 18-03 | 3 | VID-07 | scripted gate | `bash Scripts/kill9-recovery-gate.sh` | ❌ W0 | ⬜ pending |
| 18-04-T1 | 18-04 | 4 | VID-05/06/07/STOR-04 | manual gate | human-verify: real capture, exclusion, static duration, anchor | n/a | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] Concurrency spike compiles green under `SWIFT_STRICT_CONCURRENCY=complete` before the public API is committed
- [ ] Test stubs for preset math, filter selection, anchor computation (pure static functions, per RESEARCH.md testability seams)
- [ ] `Scripts/kill9-recovery-gate.sh` + minimal recording harness for the VID-07 gate

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Real display/window capture produces playable HEVC .mov | VID-06 | ScreenCaptureKit needs Screen Recording permission + real display; cannot run in CI/unit tests | Run harness for ~30 s on each preset; open output in QuickTime; verify duration ≈ elapsed and bitrate ≤ preset cap (ffprobe/mdls) |
| Caddie windows absent from capture | VID-05 | Visual check of recorded content | Record display with a Caddie window visible; scrub output; Caddie windows must not appear |
| kill -9 fragment recovery on the macOS 14.2 floor | VID-07 | Local machine is macOS 26; floor behavior must be verified empirically before ship | Re-run `Scripts/kill9-recovery-gate.sh` on a 14.2 machine/VM before milestone release |
| Static-screen duration correctness | VID-07/VID-06 | Requires a real static screen over minutes | Record ~2 min of static screen; output duration must be ~2 min, not seconds |
