# Phase 2: Test Infrastructure - Context

**Gathered:** 2026-03-22
**Status:** Ready for planning

<domain>
## Phase Boundary

Create protocol-based DI for ML engines so tests run without FluidAudio. Add database migration tests. Add pipeline error path tests. This enables TDD for all subsequent hardening phases.

</domain>

<decisions>
## Implementation Decisions

### Claude's Discretion
All implementation choices are at Claude's discretion — pure infrastructure phase.

Key constraints from research:
- Define ASREngineProtocol and DiarizationEngineProtocol
- TranscriptionPipeline takes protocols, not concrete types
- Test target provides mock implementations returning canned results
- This also breaks the FluidAudio linker dependency for tests (if CaddieTests doesn't import FluidAudio directly)
- Database migration tests use in-memory GRDB DatabaseQueue
- Pipeline error path tests cover: enqueue failure, transcription failure, concurrent enqueue rejection, state transitions

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- ASREngine (Sources/Transcription/ASREngine.swift) — concrete type to abstract
- DiarizationEngine (Sources/Transcription/DiarizationEngine.swift) — concrete type to abstract
- TranscriptionPipeline (Sources/Transcription/TranscriptionPipeline.swift) — actor consuming engines
- AppDatabase (Sources/Storage/Database.swift) — DB setup with migrations
- Migrations.swift (Sources/Storage/Migrations.swift) — migration definitions
- 10 existing test files all passing (49 tests)

### Established Patterns
- Swift 6.0 with strict concurrency
- XCTest framework for tests
- Actor-based TranscriptionPipeline
- GRDB for database with WAL mode

### Integration Points
- TranscriptionPipeline.swift — takes ASREngine and DiarizationEngine
- AppState.swift — creates engines and pipeline
- Tests/ directory — add new test files here

</code_context>

<specifics>
## Specific Ideas

No specific requirements — infrastructure phase.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>
