---
phase: 19
slug: recording-lifecycle-integration
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-07-31
---

# Phase 19 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | XCTest (xcodebuild, XcodeGen project) |
| **Config file** | `project.yml` (run `make setup` / `xcodegen generate` after adding any file) |
| **Quick run command** | `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -configuration Debug -destination 'platform=macOS' -only-testing:CaddieTests/<ClassName>` |
| **Full suite command** | `make test` (require `** TEST SUCCEEDED **`) |
| **Baseline** | 304 tests green at end of Phase 18 (18-VERIFICATION.md) |
| **Estimated runtime** | quick ~60–90 s (project build dominates) · full ~5–10 min |

**Honest note on the coordinator rig:** `RecordingCoordinatorTests.makeCoordinator()` injects a REAL `AudioRecorder` — there is no AudioRecorder mock in the project, so coordinator tests already depend on the dev machine's audio hardware. Phase 19 does not fix that (out of scope) and must not make it worse: the video seam is mock-only, so `make test` can never capture the screen or need a TCC grant. "Audio still recording" assertions are made against coordinator state / the DB row, not against real sample data.

---

## Sampling Rate

- **After every task commit:** the targeted `-only-testing` quick command for the touched test class
- **After every plan (wave merge):** `make test` (full suite)
- **Before `/gsd:verify-work`:** full suite green + the 19-05 manual gate passed
- **Max feedback latency:** ~600 seconds (full suite)

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 19-01-T1 | 19-01 | 1 | VID-03 | unit | `-only-testing:CaddieTests/ScreenRecordingSettingsTests` (key pin, default OFF, videoPath layout) | ❌ W0 | ⬜ pending |
| 19-01-T2 | 19-01 | 1 | VID-03 | unit | `-only-testing:CaddieTests/ProtocolDITests` (ScreenRecorder conforms; factory vends distinct instances) | ✅ (extend) | ⬜ pending |
| 19-01-T3 | 19-01 | 1 | VID-04 | unit (compile) | `-only-testing:CaddieTests/ProtocolDITests` (mock + factory compile into the test target) | ❌ W0 | ⬜ pending |
| 19-02-T1 | 19-02 | 2 | VID-03 | unit | `-only-testing:CaddieTests/RecordingCoordinatorScreenCaptureTests` (manual start, meetingDetected start, .mov path, nil factory, anchor pair, isVideoActive) | ❌ W0 | ⬜ pending |
| 19-02-T2 | 19-02 | 2 | VID-04 | unit | `-only-testing:CaddieTests/RecordingCoordinatorScreenCaptureTests` (start throw degrades, stream death surfaces, never enters .error) | ❌ W0 | ⬜ pending |
| 19-03-T1 | 19-03 | 3 | VID-03 | unit | `-only-testing:CaddieTests/RecordingCoordinatorScreenCaptureTeardownTests` (manualStop / meetingEnded / deviceDisconnected / error path / app-quit stop / second meeting / stop-before-start) | ❌ W0 | ⬜ pending |
| 19-03-T2 | 19-03 | 3 | VID-04 | unit | `-only-testing:CaddieTests/RecordingCoordinatorScreenCaptureTeardownTests/testSlowVideoStopDoesNotBlockPipeline` | ❌ W0 | ⬜ pending |
| 19-04-T1 | 19-04 | 4 | VID-04 | unit | `-only-testing:CaddieTests/AppStateVideoErrorTests` (lastVideoError set/clear/replace) | ❌ W0 | ⬜ pending |
| 19-04-T2 | 19-04 | 4 | VID-04 | build + grep gate | `make test` + MenuBarView/README grep criteria in the plan | n/a | ⬜ pending |
| 19-05-T1 | 19-05 | 5 | VID-03/04 | env prep | `defaults read com.caddie.app screenRecordingEnabled` → `1`; `make build` | n/a | ⬜ pending |
| 19-05-T2 | 19-05 | 5 | VID-03/04 | manual gate | `Caddie --validate-mov <path>` exit 0 for each recorded file | n/a | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Requirement → Behavior Coverage

| Req | Behavior (roadmap success criterion) | Covered by |
|-----|--------------------------------------|------------|
| VID-03 | Video begins after audio starts, manual trigger (criterion 1) | 19-02-T1 `testManualStartStartsVideo` |
| VID-03 | Video begins after audio starts, calendar-prompted trigger (criterion 1) | 19-02-T1 `testMeetingDetectedStartsVideo` |
| VID-03 | Video stops when the meeting stops, all reducer paths (criterion 1) | 19-03-T1 `testManualStopStopsVideo` / `testMeetingEndedStopsVideo` / `testDeviceDisconnectStopsVideo` |
| VID-03 | Both stop paths finalize cleanly (criterion 2) | 19-03-T1 `testManualStopStopsVideo` + `testErrorPathStopsVideo` |
| VID-03 | App quit finalizes (criterion 2, 4) | 19-03-T1 `testShutdownStopFinalizesVideo` + 19-05 check 5 |
| VID-03 | Meeting #2 in one session records video (single-use engine regression) | 19-03-T1 `testSecondMeetingStartsVideoAgain` + 19-05 check 3 |
| VID-03 | Feature is OFF unless opted in | 19-01-T1 `testIsEnabledIsFalseWhenKeyAbsent`; 19-02-T1 `testRecordingWorksWithoutScreenRecorder` |
| VID-04 | Forced start failure degrades to audio-only, logged + surfaced (criterion 3) | 19-02-T2 `testVideoStartFailureDegradesToAudioOnly` + 19-05 check 4 |
| VID-04 | Mid-meeting stream death surfaced; audio unaffected (criterion 3) | 19-02-T2 `testStreamDeathMidMeetingSurfacesAndKeepsAudio` |
| VID-04 | A video failure never produces `.error` | 19-02-T2 `testVideoFailureNeverEntersErrorState` |
| VID-04 | A wedged stop never strands the meeting before enqueue | 19-03-T2 `testSlowVideoStopDoesNotBlockPipeline` |
| VID-04 | The failure is visible to the user | 19-04-T1 `AppStateVideoErrorTests` + 19-04-T2 grep gates + 19-05 check 4 |
| VID-03/04 | No video file left open or corrupted at meeting end (criterion 4) | 19-03-T1 `testStopBeforeStartCompletesStillStopsVideo` + 19-05 checks 1/3/5 (`--validate-mov`) |
| STOR-04 (in-memory leg) | Anchor pair captured and logged | 19-02-T1 `testAnchorPairCapturedInMemory` + 19-05 check 2 |

---

## Wave 0 Requirements

- [ ] `Tests/Mocks/MockScreenRecorder.swift` — NSLock-guarded `ScreenRecording` double + `MockScreenRecorderFactory` (`startError`, `stopDelay`, `simulateStreamDeath`, instance ledger)
- [ ] `Tests/ScreenRecordingSettingsTests.swift` — key pinned against a raw literal, default OFF, `videoPath(for:)` layout
- [ ] `Tests/RecordingCoordinatorScreenCaptureTests.swift` — VID-03 start path + VID-04 containment
- [ ] `Tests/RecordingCoordinatorScreenCaptureTeardownTests.swift` — every teardown path, second-meeting regression, reentrancy, stop timeout
- [ ] `Tests/AppStateVideoErrorTests.swift` — observable set/clear
- [ ] `#if DEBUG` accessors on `RecordingCoordinator` (`isVideoActive`, `videoAnchorPair`, `videoOutputURL`)
- [ ] `make setup` (xcodegen) after adding each new file
- *(No framework install needed — XCTest is already wired; zero new SPM packages in this phase.)*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Real capture through the real coordinator yields a playable `.mov` of ≈ wall-clock duration | VID-03 | ScreenCaptureKit needs a TCC grant + a real display; running it in `make test` would record the developer's screen | 19-05 check 1 — `--validate-mov` exit 0, duration ≈ elapsed |
| Second meeting in the same app session also records | VID-03 | The single-use-engine defect is only fully provable against the real engine | 19-05 check 3 |
| TCC-denied start degrades to audio-only end to end | VID-04 | Requires revoking a real OS grant | 19-05 check 4 — audio + transcript complete, menu-bar warning visible, no growing `.mov` |
| Quit during recording leaves a playable file | VID-03 criterion 2/4 | Requires killing a real app mid-capture | 19-05 check 5 — `--validate-mov` exit 0, ≤ ~10 s tail loss acceptable |
| Anchor offset in the real pipeline | STOR-04 | `.info` logs are memory-only; needs `log stream` | 19-05 check 2 — record the measured offset (18-04 measured ~215 ms setup latency) |

`Scripts/kill9-recovery-gate.sh` is NOT re-run in Phase 19 — it gates the engine and already passed in 18-03/18-04. Only the `--validate-mov` mode of the same harness is reused.

---

## Manual Gate Results

*(Filled in by 19-05. Every row needs a measured value, not a bare "pass".)*

| # | Check | Expected | Measured | Result |
|---|-------|----------|----------|--------|
| 1 | Real ~30 s capture | `.mov` beside `.m4a`, `isPlayable=true`, duration ≈ elapsed | — | ⬜ |
| 2 | Anchor logged | `Video anchor for <id>` with offset in the low hundreds of ms | — | ⬜ |
| 3 | Second meeting, same session | second distinct `.mov`, `isPlayable=true` | — | ⬜ |
| 4 | TCC revoked | audio + transcript complete, menu-bar warning, no open `.mov` | — | ⬜ |
| 5 | Quit mid-recording | `isPlayable=true`, ≤ ~10 s tail loss | — | ⬜ |
