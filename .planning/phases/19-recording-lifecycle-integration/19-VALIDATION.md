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

---

## Manual Gate Results (2026-07-10, executed by agent via AX automation + tccutil; user granted TCC once beforehand)

Build: `~/Library/Developer/Xcode/DerivedData/Caddie-gaujkvsybzcmwgepbihhspvvoeyo/Build/Products/Debug/Caddie.app` (729 MB, ML models bundled). Feature enabled via `defaults write com.caddie.app screenRecordingEnabled -bool true`; deleted after the gate. Log stream captured to scratchpad (`caddie-19gate.log`).

| # | Check | Result | Measured |
|---|-------|--------|----------|
| 1 | Real capture through real coordinator | ✅ PASS | Meeting 30 (`884dbf89-a39`): `VALIDATE isPlayable=true duration=303.99` exit 0; 94,581,489 B / 304 s ≈ 2.49 Mbps (balanced cap 2.5); transcript 3,860 chars, status `done`; `.mov` beside `.m4a`. Duration = true meeting length (stop was delayed by the confirm modal, see finding F1) |
| 2 | Anchor logged (STOR-04 in-memory leg) | ✅ PASS | `Video anchor for <meetingId>: audioTicks=3364479915878 firstFrameTicks=3364486458157 offset=0.273s` — within expected setup-latency band (18-04 measured 0.215 s) |
| 3 | Second meeting, same session (single-use regression) | ✅ PASS | Meeting 31 (`68d4c389-96d`): distinct `.mov`, `VALIDATE isPlayable=true duration=24.01` exit 0; 5,273,362 B ≈ 1.76 Mbps |
| 5 | Quit mid-recording | ✅ PASS | Meeting 32 (`24204cea-ff5`): quit at ~23 s elapsed; `VALIDATE isPlayable=true duration=20.24` exit 0 — 2.8 s tail loss, within ≤10 s fragment window |
| 4 | TCC-denied degrade (run LAST via `tccutil reset ScreenCapture com.caddie.app`) | ✅ PASS | Meeting 33 (`d784b771-9fb`): audio recorded + transcribed (`done`, no error); menu bar showed "⚠️ Screen recording stopped — audio was saved … The user declined TCCs …" + Dismiss action during recording; log has `Screen capture failed to start` + `Video error surfaced`; NO `.mov` created (no orphan) |

Reorder note: check 4 was run last so the single unavoidable human action (re-granting Screen Recording in System Settings) happens once, after the gate. Grant re-request is pending with the user.

### Finding F1 (pre-existing defect, NOT Phase 19 — logged for follow-up)
`MenuBarView.confirmStopRecording()` uses `NSAlert.runModal()`. While the modal waits, the main thread is blocked → the audio drain `DispatchSourceTimer` (main queue) starves and the ~2 s SPSC ring buffer discards samples. Evidence: meeting 30 ran 304 s but its `.m4a` contains 63.2 s of audio — everything while the dialog sat open was silently dropped. Video (own queue) recorded the full 304 s. This violates the no-lost-audio core value independent of v3.0 and should be fixed (non-modal confirm, or drain off the main queue). Also caused three historic "why is my recording short?" risk. Surfaced only because this gate drove the UI exactly like a distracted human would.
