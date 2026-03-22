# Phase 9: Recording Resilience - Context

**Gathered:** 2026-03-22
**Status:** Ready for planning

<domain>
## Phase Boundary

Handle device disconnection mid-recording gracefully and clean up stale aggregate device UIDs on app launch.

</domain>

<decisions>
## Implementation Decisions

### Claude's Discretion
All implementation choices are at Claude's discretion.

Key constraints:
- REC-05: CoreAudio device disconnection detected mid-recording with graceful stop and user notification
- REC-06: Stale aggregate device UIDs cleaned up on app launch
- Use kAudioDevicePropertyDeviceIsAlive property listener for disconnect detection
- RecordingCoordinator manages recording lifecycle (Phase 4)
- SystemAudioCapture.swift handles CoreAudio aggregate devices

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- SystemAudioCapture.swift — CoreAudio integration, aggregate device creation
- RecordingCoordinator.swift — lifecycle management with state machine
- AudioRecorder.swift — coordinates system + mic capture

### Established Patterns
- CoreAudio C API wrapped in Swift
- AudioObjectAddPropertyListener for device monitoring
- RecordingState state machine for lifecycle transitions

### Integration Points
- SystemAudioCapture aggregate device creation/destruction
- RecordingCoordinator.handle(.meetingEnded) for graceful stop
- AppState.initialize() for startup cleanup

</code_context>

<specifics>
## Specific Ideas

No specific requirements beyond REC-05 and REC-06.

</specifics>

<deferred>
## Deferred Ideas

None.

</deferred>
