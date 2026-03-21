# Phase 5: Pipeline Data Integrity - Context

**Gathered:** 2026-03-22
**Status:** Ready for planning

<domain>
## Phase Boundary

Eliminate all transcript data loss paths: DB write gating on recording start, transcript persistence as blocking step, safe temp file lifecycle, orphaned cleanup, retry fixes, idempotent pipeline, bounded queue.

</domain>

<decisions>
## Implementation Decisions

### Claude's Discretion
All implementation choices are at Claude's discretion — data integrity hardening.

Key constraints:
- DATA-01: Recording must abort with user notification if DB insert fails
- DATA-02: Transcript DB write failure = pipeline failure, preserve source files
- DATA-03: Mono file deleted only after BOTH ASR and diarization complete (no defer)
- DATA-04: WAV deleted only after ALAC compression succeeds AND transcript persisted
- DATA-05: Clean caddie_mono_* from temp on app startup
- DATA-06: Retry refreshes DB connection, verifies WAV exists
- DATA-07: Reject duplicate enqueue for .transcribing/.done meetings
- DATA-08: Queue bounded at 50 with logged rejection
- TranscriptionPipeline now has onComplete callback (Phase 4)
- RecordingCoordinator manages lifecycle (Phase 4)

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- TranscriptionPipeline.swift — actor with protocol-based DI and onComplete callback
- RecordingCoordinator.swift — actor state machine
- AudioFileManager.swift — file operations
- AppDatabase.swift — GRDB wrapper

### Integration Points
- RecordingCoordinator.executeStartRecording() — DB insert happens here
- TranscriptionPipeline.processNext() — file deletion and DB writes here
- AppState init — startup cleanup hook

</code_context>

<specifics>
## Specific Ideas

No specific requirements beyond the 8 DATA requirements.

</specifics>

<deferred>
## Deferred Ideas

None.

</deferred>
