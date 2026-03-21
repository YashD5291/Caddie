# Phase 3: Audio Thread Safety - Context

**Gathered:** 2026-03-22
**Status:** Ready for planning

<domain>
## Phase Boundary

Fix memory safety bugs in the CoreAudio render callback: replace NSLock with a lock-free ring buffer, and fix the use-after-free risk from Unmanaged.passUnretained(self).

</domain>

<decisions>
## Implementation Decisions

### Claude's Discretion
All implementation choices are at Claude's discretion — pure infrastructure phase.

Key constraints from research:
- CoreAudio render callbacks MUST NOT block (no locks, no allocations, no Obj-C dispatch)
- NSLock does not support priority inheritance — causes priority inversion on real-time thread
- Replace with lock-free ring buffer (power-of-2 sized, atomic read/write indices)
- Unmanaged.passUnretained(self) is a use-after-free if SystemAudioCapture is deallocated during callback
- Fix: use Unmanaged.passRetained or a separate context object that outlives the callback
- Ensure stop() is synchronous and waits for in-flight callbacks before returning

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- SystemAudioCapture.swift (Sources/Recording/SystemAudioCapture.swift) — 431 lines, CoreAudio integration
- MicrophoneCapture.swift (Sources/Recording/MicrophoneCapture.swift) — mic recording
- AudioRecorder.swift (Sources/Recording/AudioRecorder.swift) — coordinates system + mic capture

### Established Patterns
- CoreAudio C API wrapped in Swift
- AudioUnit render callbacks with UnsafeMutableRawPointer context
- NSLock currently used for buffer synchronization (the bug)
- Ring buffer pattern needed (not currently implemented)

### Integration Points
- SystemAudioCapture render callback — the hot path
- AudioRecorder.start() / stop() — lifecycle management
- MicrophoneCapture — may also have buffer issues

</code_context>

<specifics>
## Specific Ideas

No specific requirements — infrastructure phase.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>
