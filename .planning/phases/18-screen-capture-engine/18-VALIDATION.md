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
| (filled by planner) | | | VID-05 | unit | filter-selection/exclusion logic tests | ❌ W0 | ⬜ pending |
| (filled by planner) | | | VID-06 | unit | preset math (fps/bitrate/dimension) tests | ❌ W0 | ⬜ pending |
| (filled by planner) | | | VID-07 | scripted gate | `Scripts/kill9-recovery-gate.sh` | ❌ W0 | ⬜ pending |
| (filled by planner) | | | STOR-04 | unit | host-clock anchor computation tests | ❌ W0 | ⬜ pending |

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
