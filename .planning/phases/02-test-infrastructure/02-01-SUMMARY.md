---
phase: 02-test-infrastructure
plan: 01
subsystem: testing
tags: [swift-protocols, dependency-injection, mocks, xctest]

requires:
  - phase: 01-test-target-revival
    provides: "Working test target with 49+ passing tests"
provides:
  - "ASREngineProtocol and DiarizationEngineProtocol for protocol-based DI"
  - "MockASREngine and MockDiarizationEngine with stubbable results and call tracking"
  - "TranscriptionPipeline accepting protocol types instead of concrete engines"
  - "FluidAudio removed from CaddieTests dependencies"
affects: [02-03, pipeline-testing, transcription-refactoring]

tech-stack:
  added: []
  patterns: [protocol-based-di, existential-types, mock-engine-pattern]

key-files:
  created:
    - Sources/Transcription/ASREngineProtocol.swift
    - Sources/Transcription/DiarizationEngineProtocol.swift
    - Tests/Mocks/MockASREngine.swift
    - Tests/Mocks/MockDiarizationEngine.swift
    - Tests/ProtocolDITests.swift
  modified:
    - Sources/Transcription/ASREngine.swift
    - Sources/Transcription/DiarizationEngine.swift
    - Sources/Transcription/TranscriptionPipeline.swift
    - project.yml

key-decisions:
  - "Used 'any ASREngineProtocol' (existential) not 'some' (opaque) -- actors require existential types for stored protocol properties"
  - "Protocols require Sendable conformance since TranscriptionPipeline is an actor"

patterns-established:
  - "Mock engine pattern: stubbable results, error injection, call counting, URL tracking"
  - "Protocol-based DI: production code depends on protocols, tests inject mocks"

requirements-completed: [BUILD-03]

duration: 4min
completed: 2026-03-22
---

# Phase 02 Plan 01: Protocol-Based DI Summary

**Engine protocols with existential types enabling mock injection into TranscriptionPipeline without FluidAudio in tests**

## Performance

- **Duration:** 4 min
- **Started:** 2026-03-21T21:46:47Z
- **Completed:** 2026-03-21T21:50:47Z
- **Tasks:** 2
- **Files modified:** 9

## Accomplishments
- Extracted ASREngineProtocol and DiarizationEngineProtocol from concrete engine classes
- Refactored TranscriptionPipeline to depend on protocol types (any ASREngineProtocol)
- Created MockASREngine and MockDiarizationEngine with full test doubles (stubbing, errors, call tracking)
- Removed FluidAudio from CaddieTests dependencies in project.yml
- All 59 tests pass including 3 new ProtocolDI tests

## Task Commits

1. **Task 1: Define engine protocols and refactor pipeline** - `196c931` (feat)
2. **Task 2: Create mock engines, remove FluidAudio from test target** - `7d0d94d` (feat)

## Files Created/Modified
- `Sources/Transcription/ASREngineProtocol.swift` - Protocol defining ASR engine contract with Sendable
- `Sources/Transcription/DiarizationEngineProtocol.swift` - Protocol defining diarization engine contract with Sendable
- `Sources/Transcription/ASREngine.swift` - Added ASREngineProtocol conformance
- `Sources/Transcription/DiarizationEngine.swift` - Added DiarizationEngineProtocol conformance
- `Sources/Transcription/TranscriptionPipeline.swift` - Changed to protocol-typed stored properties and init
- `Tests/Mocks/MockASREngine.swift` - Test mock with stubbable results and call tracking
- `Tests/Mocks/MockDiarizationEngine.swift` - Test mock with stubbable results and call tracking
- `Tests/ProtocolDITests.swift` - Verifies mock conformance and protocol-based pipeline init
- `project.yml` - Removed FluidAudio from CaddieTests dependencies

## Decisions Made
- Used `any ASREngineProtocol` (existential types) instead of `some` (opaque types) because actors require existential types for stored protocol-typed properties
- Protocols require Sendable conformance since they're stored inside an actor (TranscriptionPipeline)
- AppState needed no changes -- concrete engines already conform to protocols via structural subtyping

## Deviations from Plan
None - plan executed exactly as written.

## Issues Encountered
None.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Protocol-based DI foundation ready for Plan 03 (TranscriptionPipeline tests)
- MockASREngine and MockDiarizationEngine available for error injection testing
- All 59 tests passing, test target no longer directly depends on FluidAudio

---
*Phase: 02-test-infrastructure*
*Completed: 2026-03-22*
