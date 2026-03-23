---
phase: 10
slug: bundle-ml-models-in-app-instead-of-runtime-download
status: draft
nyquist_compliant: true
wave_0_complete: true
created: 2026-03-23
---

# Phase 10 -- Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | XCTest (Swift 6.0) |
| **Config file** | project.yml (CaddieTests target) |
| **Quick run command** | `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -configuration Debug -destination 'platform=macOS'` |
| **Full suite command** | `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -configuration Debug -destination 'platform=macOS'` |
| **Estimated runtime** | ~30 seconds |

---

## Sampling Rate

- **After every task commit:** Run `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -configuration Debug -destination 'platform=macOS'`
- **After every plan wave:** Run full suite
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 30 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 10-01-01 | 01 | 1 | Model loading | unit | `xcodebuild test -only-testing:CaddieTests/ModelManagerTests` | Needs update | pending |
| 10-01-02 | 01 | 1 | Error handling | unit | `xcodebuild test -only-testing:CaddieTests/ModelManagerTests` | Needs update | pending |
| 10-02-01 | 02 | 1 | Download script | integration | `bash scripts/download-models.sh && bash scripts/download-models.sh` | Wave 0 | pending |
| 10-03-01 | 03 | 2 | Onboarding text | manual | N/A | N/A | pending |
| 10-04-01 | 04 | 2 | CI release build | e2e | GitHub Actions release workflow | Existing | pending |

*Status: pending / green / red / flaky*

---

## Wave 0 Requirements

Wave 0 is satisfied by 10-02 Task 1, Step 1 (TDD RED phase), which rewrites `Tests/ModelManagerTests.swift` with:
- Tests for `ModelLoadError` error descriptions (bundleNotFound, modelsNotFound, loadFailed)
- Test for `ModelManager` initial state (isLoading, loadProgress, loadError, modelsReady)

These tests are written first (RED), then ModelManager is rewritten to make them pass (GREEN). No separate Wave 0 step is needed.

- [x] Update `Tests/ModelManagerTests.swift` -- handled by 10-02 Task 1 Step 1 (TDD RED phase)
- [x] Add test for `ModelLoadError` error descriptions -- handled by 10-02 Task 1 Step 1 (TDD RED phase)
- [ ] Add test stub for download script idempotency -- verified by integration test command in Per-Task Verification Map

*Existing infrastructure covers most phase requirements -- Wave 0 test updates are embedded in 10-02 Task 1's TDD cycle.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| OnboardingView shows "Loading" not "Downloading" | D-08 | UI text verification | Launch app fresh, observe onboarding model step text |
| DMG size ~711MB-1.2GB | D-10 | Build artifact check | Build release DMG, verify size in Finder |

---

## Validation Sign-Off

- [x] All tasks have `<automated>` verify or Wave 0 dependencies
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all MISSING references (via 10-02 Task 1 TDD RED phase)
- [x] No watch-mode flags
- [x] Feedback latency < 30s
- [x] `nyquist_compliant: true` set in frontmatter

**Approval:** ready
