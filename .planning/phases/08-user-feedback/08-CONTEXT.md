# Phase 8: User Feedback - Context

**Gathered:** 2026-03-22
**Status:** Ready for planning

<domain>
## Phase Boundary

Make recording status, transcription progress, and system audio capture state visible to the user through menu bar UI and macOS notifications.

</domain>

<decisions>
## Implementation Decisions

### Claude's Discretion
All implementation choices are at Claude's discretion.

Key constraints:
- UX-01: Menu bar shows system+mic vs mic-only recording status
- UX-02: Menu bar shows transcription progress steps (mixdown → transcribing → diarizing → compressing)
- UX-03: macOS notifications on recording auto-start, transcription complete, transcription error
- UX-04: Notification when system audio capture fails and falls back to mic-only
- RecordingCoordinator has onStateChange callback (Phase 4)
- AudioRecorder already has system audio fallback logic (Phase 3)
- Use UNUserNotificationCenter for macOS notifications
- Menu bar UI is in MenuBarView.swift

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- MenuBarView.swift (Sources/UI/MenuBar/MenuBarView.swift) — existing menu bar UI
- AppState.swift — thin @Observable wrapper with status, currentMeetingTitle
- RecordingCoordinator.swift — onStateChange callback
- AudioRecorder.swift — system audio capture with fallback

### Established Patterns
- SwiftUI for all UI
- @Observable for state management
- RecordingState enum for lifecycle states

### Integration Points
- MenuBarView observes AppState
- AppState.status drives menu bar display
- AudioRecorder.start() has try/catch for system audio

</code_context>

<specifics>
## Specific Ideas

No specific requirements beyond the 4 UX requirements.

</specifics>

<deferred>
## Deferred Ideas

None.

</deferred>
