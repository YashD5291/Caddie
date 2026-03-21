# Phase 4: Recording Coordinator - Context

**Gathered:** 2026-03-22
**Status:** Ready for planning

<domain>
## Phase Boundary

Extract recording lifecycle management from AppState into a dedicated RecordingCoordinator actor with explicit state machine. Eliminate the initialization race condition where pipeline is nil when meetings end during init.

</domain>

<decisions>
## Implementation Decisions

### Claude's Discretion
All implementation choices are at Claude's discretion — architectural refactor phase.

Key constraints from research:
- Actor-based state machine with enum states: idle → recording → transcribing → done/error
- Synchronous state transitions (reduce function), async side effects dispatched after transition
- AppState becomes thin @Observable wrapper delegating to RecordingCoordinator
- Pipeline guaranteed ready before meeting lifecycle events fire
- State transitions must be unit testable (every valid and invalid transition)
- GRDB async writes respect Task cancellation — critical writes must survive cancellation
- Prior phase decisions: TranscriptionPipeline now uses protocol-based DI (Phase 2), ring buffers in AudioRecorder (Phase 3)

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- AppState.swift (Sources/App/AppState.swift) — current god object to refactor
- TranscriptionPipeline (Sources/Transcription/TranscriptionPipeline.swift) — actor, protocol-based DI
- AudioRecorder (Sources/Recording/AudioRecorder.swift) — uses SPSCRingBuffer now
- MeetingDetector (Sources/Detection/MeetingDetector.swift) — fires meeting lifecycle events

### Established Patterns
- @Observable macro for SwiftUI state
- Actor isolation for concurrency safety
- Protocol-based DI for testability (from Phase 2)

### Integration Points
- CaddieApp.swift — creates AppState
- All UI views — observe AppState properties
- MeetingDetector callbacks — onMeetingStarted/onMeetingEnded

</code_context>

<specifics>
## Specific Ideas

No specific requirements — architectural refactor.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>
