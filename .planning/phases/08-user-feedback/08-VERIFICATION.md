---
phase: 08-user-feedback
verified: 2026-03-22T12:30:00Z
status: human_needed
score: 9/9 must-haves verified
human_verification:
  - test: "Menu bar icon changes during recording modes"
    expected: "record.circle.fill (red circle) for system+mic, mic.fill for mic-only"
    why_human: "Icon rendering is visual and cannot be verified programmatically"
  - test: "Menu bar status text shows recording mode label and updates live"
    expected: "Recording state shows 'System Audio + Mic' or warning 'Microphone Only' below meeting title"
    why_human: "SwiftUI view rendering and layout require visual inspection"
  - test: "Menu bar shows transcription step during processing"
    expected: "Sequentially shows 'Mixing down audio...', 'Transcribing speech...', 'Identifying speakers...', 'Compressing audio...'"
    why_human: "Step sequencing requires a live transcription run to observe"
  - test: "macOS notification fires on recording auto-start"
    expected: "'Recording Started' notification appears with meeting title and mode within seconds of detection"
    why_human: "UNUserNotificationCenter delivery requires a running app with granted permission"
  - test: "macOS notification fires on transcription complete"
    expected: "'Transcription Complete' notification appears with meeting title after pipeline finishes"
    why_human: "Requires a complete end-to-end recording and transcription run"
  - test: "macOS notification fires on transcription error"
    expected: "'Transcription Failed' notification appears with meeting title and error description"
    why_human: "Requires triggering a real pipeline failure"
  - test: "macOS notification fires on system audio fallback"
    expected: "'System Audio Unavailable' notification fires when Screen Recording permission is revoked"
    why_human: "Requires manually revoking permission and starting a recording"
---

# Phase 08: User Feedback Verification Report

**Phase Goal:** Users always know what Caddie is doing -- recording status, transcription progress, and completion are visible
**Verified:** 2026-03-22T12:30:00Z
**Status:** human_needed
**Re-verification:** No -- initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|---------|
| 1 | AppState exposes whether recording uses system+mic or mic-only | VERIFIED | `AppState.recordingMode: RecordingMode` at line 23; wired via `setOnRecordingModeChange` callback in `AppState.initialize()` lines 122-127 |
| 2 | AppState exposes current transcription pipeline step | VERIFIED | `AppState.pipelineStep: PipelineStep` at line 24; wired via `setOnPipelineStepChange` callback in `AppState.initialize()` lines 130-135 |
| 3 | System audio fallback is propagated from AudioRecorder through coordinator to AppState | VERIFIED | `AudioRecorder.start()` sets `recordingMode = .micOnly` at line 95 on system capture failure; `RecordingCoordinator.executeStartRecording()` reads `recorder.recordingMode` and calls `onRecordingModeChange?(mode)` at line 200 |
| 4 | Menu bar shows system+mic vs mic-only when recording | VERIFIED | `MenuBarView.statusSection` checks `appState.recordingMode == .micOnly` at line 34, renders warning text or "System Audio + Mic" |
| 5 | Menu bar shows current transcription step | VERIFIED | `MenuBarView.statusSection` calls `pipelineStepLabel(appState.pipelineStep)` at line 48; helper at lines 121-129 maps all 5 PipelineStep cases to human-readable strings |
| 6 | macOS notification fires on recording auto-start | VERIFIED | `RecordingCoordinator.executeStartRecording()` calls `NotificationManager.recordingStarted(title:mode:)` at line 201 after recorder starts |
| 7 | macOS notification fires on transcription complete | VERIFIED | `RecordingCoordinator.executeNotifyComplete()` calls `NotificationManager.transcriptionComplete(title:)` at line 300 |
| 8 | macOS notification fires on transcription error | VERIFIED | `RecordingCoordinator.executeNotifyError()` calls `NotificationManager.transcriptionError(title:error:)` at line 319 |
| 9 | macOS notification fires when system audio falls back to mic-only | VERIFIED | `RecordingCoordinator.executeStartRecording()` calls `NotificationManager.systemAudioFallback()` at line 203 when `mode == .micOnly` |

**Score:** 9/9 truths verified

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `Sources/Recording/AudioRecorder.swift` | RecordingMode enum + property set on capture success/failure | VERIFIED | `enum RecordingMode` at line 5; `private(set) var recordingMode` at line 21; `.systemAndMic` set at line 85, `.micOnly` set at line 95; reset to `.systemAndMic` in `stop()` at line 134 |
| `Sources/App/AppState.swift` | PipelineStep enum + observable recordingMode and pipelineStep | VERIFIED | `enum PipelineStep` at lines 11-17; `var recordingMode: RecordingMode` at line 23; `var pipelineStep: PipelineStep` at line 24; both reset on `.idle` transition at lines 108-109 |
| `Sources/Coordinator/RecordingCoordinator.swift` | Forwards recordingMode and pipelineStep via callbacks | VERIFIED | `onRecordingModeChange` callback at line 24; `onPipelineStepChange` callback at line 25; `setOnRecordingModeChange` at line 50; `setOnPipelineStepChange` at line 54; pipeline step forwarding wired in `start()` at lines 79-82 |
| `Sources/Transcription/TranscriptionPipeline.swift` | Reports current step via onStepChange callback | VERIFIED | `onStepChange` at line 39; `setOnStepChange` at line 41; called before mixdown (line 135), ASR (line 141), diarization (line 147), compression (line 194); reset to `.idle` at lines 213 and 234 |
| `Sources/Utilities/NotificationManager.swift` | 4 notification methods + requestAuthorization | VERIFIED | `enum NotificationManager` with `requestAuthorization`, `recordingStarted`, `transcriptionComplete`, `transcriptionError`, `systemAudioFallback`; all backed by `UNUserNotificationCenter.current().add(request)` |
| `Sources/UI/MenuBar/MenuBarView.swift` | Recording mode label and transcription step display | VERIFIED | `recordingMode == .micOnly` check at line 34; `pipelineStepLabel` helper at lines 121-129; `appState.pipelineStep` read at line 48 |
| `Sources/App/CaddieApp.swift` | Menu bar icon differentiation and notification auth | VERIFIED | `appState.recordingMode == .micOnly` branch at line 18 yields `mic.fill` icon; `NotificationManager.requestAuthorization()` called at line 50 in `AppDelegate.applicationDidFinishLaunching` |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `AudioRecorder.swift` | `RecordingCoordinator.swift` | `recorder.recordingMode` property read after `recorder.start()` | WIRED | Line 199: `let mode = recorder.recordingMode` immediately after successful `recorder.start()` call |
| `TranscriptionPipeline.swift` | `RecordingCoordinator.swift` | `onStepChange` callback | WIRED | `start()` sets `pipeline.setOnStepChange { _, step in stepCallback?(step) }` at lines 79-82; pipeline calls `onStepChange?(meetingId, .step)` before each major step |
| `RecordingCoordinator.swift` | `AppState.swift` | `onRecordingModeChange` and `onPipelineStepChange` callbacks | WIRED | AppState wires both in `initialize()` at lines 122-135; coordinator calls `onRecordingModeChange?(mode)` at line 200 |
| `MenuBarView.swift` | `AppState.swift` | `@Environment` observation | WIRED | `@Environment(AppState.self) private var appState`; reads `appState.recordingMode` and `appState.pipelineStep` in `statusSection` |
| `NotificationManager.swift` | `UNUserNotificationCenter` | `add(UNNotificationRequest)` | WIRED | `send()` private method calls `UNUserNotificationCenter.current().add(request)` at line 57; all 4 public methods call `send()` |
| `RecordingCoordinator.swift` | `NotificationManager.swift` | static method calls | WIRED | `NotificationManager.recordingStarted` at line 201; `NotificationManager.systemAudioFallback` at line 203; `NotificationManager.transcriptionComplete` at line 300; `NotificationManager.transcriptionError` at line 319 |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|-------------|--------|---------|
| UX-01 | 08-01, 08-02 | Menu bar shows system audio capture status (recording system+mic vs mic-only) | SATISFIED | `MenuBarView` reads `appState.recordingMode` and shows "System Audio + Mic" or warning "Microphone Only"; CaddieApp icon also differentiates |
| UX-02 | 08-01, 08-02 | Menu bar shows transcription progress steps (mixdown -> transcribing -> diarizing -> compressing) | SATISFIED | `pipelineStepLabel()` maps all PipelineStep cases; `TranscriptionPipeline` fires `onStepChange` before each step |
| UX-03 | 08-02 | macOS notification sent on recording auto-start, transcription complete, and transcription error | SATISFIED | `NotificationManager.recordingStarted`, `transcriptionComplete`, `transcriptionError` all wired into `RecordingCoordinator` side effects |
| UX-04 | 08-01, 08-02 | User notified when system audio capture fails and falls back to mic-only | SATISFIED | `NotificationManager.systemAudioFallback()` called in `executeStartRecording` when `mode == .micOnly` |

### Anti-Patterns Found

None. No TODOs, FIXMEs, placeholders, empty implementations, or stub patterns found in any phase 08 modified files.

### Human Verification Required

### 1. Menu Bar Icon Visual Differentiation

**Test:** Trigger a recording in both system+mic mode and mic-only mode (revoke Screen Recording permission for the second test).
**Expected:** `record.circle.fill` (filled red circle) appears for system+mic; `mic.fill` (plain mic) appears for mic-only.
**Why human:** Icon rendering is visual; cannot verify SF Symbol display programmatically.

### 2. Recording Mode Label in Menu

**Test:** Click the menu bar icon during an active recording.
**Expected:** Under the meeting title, one of two labels appears: "System Audio + Mic" (normal) or the warning "Microphone Only" (fallback mode).
**Why human:** SwiftUI menu rendering requires a running app to observe.

### 3. Transcription Step Progression

**Test:** After a meeting ends, watch the menu bar during transcription.
**Expected:** Status text cycles through "Mixing down audio...", "Transcribing speech...", "Identifying speakers...", "Compressing audio..." in order, each updating live.
**Why human:** Requires a real end-to-end recording and ML pipeline run to observe step changes.

### 4. Recording Auto-Start Notification

**Test:** Allow notification permission when prompted, then let Caddie auto-detect a meeting.
**Expected:** A "Recording Started" macOS notification appears with the meeting title and capture mode within seconds of detection.
**Why human:** UNUserNotificationCenter delivery requires a running app with granted permission; cannot simulate.

### 5. Transcription Complete Notification

**Test:** Let a recording complete and run through the full pipeline.
**Expected:** A "Transcription Complete" notification appears with the meeting title once the pipeline finishes.
**Why human:** Requires a full end-to-end run through the ML pipeline.

### 6. Transcription Error Notification

**Test:** Trigger a pipeline failure (e.g., corrupt WAV file or model error).
**Expected:** A "Transcription Failed" notification appears with the meeting title and error description.
**Why human:** Requires reproducing a real failure condition.

### 7. System Audio Fallback Notification

**Test:** Revoke Screen Recording permission in System Settings, then trigger a meeting detection.
**Expected:** Two notifications fire: "System Audio Unavailable" (silent) and "Recording Started" showing "microphone only".
**Why human:** Requires permission manipulation and a live recording start.

---

## Commits Verified

| Commit | Description | Files |
|--------|-------------|-------|
| `5e794f6` | Add RecordingMode and PipelineStep enums | `AudioRecorder.swift`, `AppState.swift` |
| `bd2bc75` | Thread recording mode and pipeline step through coordinator | `AppState.swift`, `RecordingCoordinator.swift`, `TranscriptionPipeline.swift` |
| `5e95e09` | Create NotificationManager and update MenuBarView | `CaddieApp.swift`, `MenuBarView.swift`, `NotificationManager.swift` |
| `dd5b4b1` | Wire notifications into RecordingCoordinator side effects | `RecordingCoordinator.swift` |

All 4 commits confirmed in git history.

---

_Verified: 2026-03-22T12:30:00Z_
_Verifier: Claude (gsd-verifier)_
