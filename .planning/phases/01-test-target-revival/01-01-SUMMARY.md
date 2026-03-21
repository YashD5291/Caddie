---
phase: 01-test-target-revival
plan: 01
subsystem: testing
tags: [xcodegen, swift6, concurrency, yyjson, linker, code-coverage]

# Dependency graph
requires: []
provides:
  - Working test target with 49 tests executing successfully
  - Swift 6.0 language mode with complete strict concurrency checking
  - Selective code coverage excluding yyjson C target
affects: [02-crash-risk-elimination, 03-error-handling-overhaul, 04-race-condition-and-timing, 05-resource-management]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "@MainActor annotation on Observable UI state classes (AppState, ModelManager)"
    - "@unchecked Sendable for actor-owned engine types (ASREngine, DiarizationEngine)"
    - "nonisolated(unsafe) for transferring non-Sendable FluidAudio types across actor boundaries"
    - "String literal for C global variables to avoid Swift 6 concurrency errors (kAXTrustedCheckOptionPrompt)"

key-files:
  created: []
  modified:
    - project.yml
    - Sources/App/AppState.swift
    - Sources/App/CaddieApp.swift
    - Sources/Detection/CalendarMonitor.swift
    - Sources/Models/ModelManager.swift
    - Sources/Transcription/ASREngine.swift
    - Sources/Transcription/DiarizationEngine.swift
    - Sources/Utilities/Permissions.swift
    - Tests/CaddieTests.swift

key-decisions:
  - "Swift 6.0 language mode with SWIFT_STRICT_CONCURRENCY: complete -- full data race checking as errors"
  - "CLANG_ENABLE_CODE_COVERAGE: NO on CaddieTests target to prevent yyjson linker crash"
  - "Scheme-level gatherCoverageData: false as additional coverage disable"
  - "@MainActor on AppState and ModelManager -- formalizes existing main-thread-only usage"

patterns-established:
  - "@MainActor: Applied to Observable UI state classes that are bound to SwiftUI views"
  - "@unchecked Sendable: Applied to engine classes owned exclusively by actors"
  - "nonisolated(unsafe): Used for transferring non-Sendable third-party types across isolation boundaries"

requirements-completed: [BUILD-01, BUILD-02]

# Metrics
duration: 26min
completed: 2026-03-22
---

# Phase 01 Plan 01: Test Target Revival Summary

**Fixed yyjson linker error via selective code coverage, upgraded to Swift 6.0 with complete strict concurrency, and resolved 7 concurrency errors across the codebase -- 49 tests now execute with 0 failures**

## Performance

- **Duration:** 26 min
- **Started:** 2026-03-21T21:00:20Z
- **Completed:** 2026-03-21T21:27:08Z
- **Tasks:** 2
- **Files modified:** 9

## Accomplishments

- Resolved the yyjson `___llvm_profile_runtime` linker error that blocked all test execution
- Upgraded from Swift 5.9 to Swift 6.0 with `SWIFT_STRICT_CONCURRENCY: complete`
- Fixed 7 Swift 6 concurrency errors across app, detection, transcription, and test code
- All 49 tests across all test files now compile, link, and pass (0 failures)

## Task Commits

Each task was committed atomically:

1. **Task 1: Update project.yml** - `b6651e7` (chore)
2. **Task 2: Verify tests compile, link, and execute** - `7c34958` (fix)

## Files Created/Modified

- `project.yml` - Swift 6.0, strict concurrency: complete, CLANG_ENABLE_CODE_COVERAGE: NO for tests, scheme with coverage disabled
- `Sources/App/AppState.swift` - Added @MainActor, nonisolated(unsafe) for FluidAudio type transfers
- `Sources/App/CaddieApp.swift` - @unchecked Sendable on AppDelegate, Task{@MainActor} replacing DispatchQueue.main.async
- `Sources/Detection/CalendarMonitor.swift` - @unchecked Sendable conformance, Task{@MainActor} for callback dispatch
- `Sources/Models/ModelManager.swift` - Added @MainActor annotation
- `Sources/Transcription/ASREngine.swift` - Added @unchecked Sendable conformance
- `Sources/Transcription/DiarizationEngine.swift` - Added @unchecked Sendable conformance
- `Sources/Utilities/Permissions.swift` - String literal for kAXTrustedCheckOptionPrompt to avoid C global concurrency error
- `Tests/CaddieTests.swift` - Added @MainActor to test accessing MainActor-isolated AppState

## Decisions Made

1. **Swift 6.0 with complete concurrency (not targeted):** The plan suggested downgrading to `targeted` if `complete` caused failures. Instead, fixed the concurrency errors directly since they were all straightforward annotation fixes. This gives the strongest data race checking from the start.

2. **CLANG_ENABLE_CODE_COVERAGE: NO (fallback approach):** The primary fix (scheme-level `coverageTargets`) did not prevent yyjson from being coverage-instrumented. Applied the fallback from STACK.md research, which directly disables Clang coverage on the test target, preventing the profiling runtime symbol from being required.

3. **@MainActor on AppState/ModelManager:** These Observable classes were already used exclusively from the main thread via SwiftUI views. The annotation formalizes this contract for Swift 6 type checking.

4. **@unchecked Sendable on engine/delegate types:** ASREngine, DiarizationEngine, CalendarMonitor, and AppDelegate are single-owner types that don't need full Sendable proofs. Using @unchecked Sendable is the correct pattern for types owned by a single actor or main thread.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] coverageTargets scheme fix insufficient, applied CLANG_ENABLE_CODE_COVERAGE fallback**
- **Found during:** Task 2 (test verification)
- **Issue:** XcodeGen's scheme-level `coverageTargets` did not prevent yyjson C target from receiving `-fprofile-instr-generate` during build-for-testing
- **Fix:** Added `CLANG_ENABLE_CODE_COVERAGE: NO` to CaddieTests target settings and set `gatherCoverageData: false` in scheme
- **Files modified:** project.yml
- **Verification:** `xcodebuild build-for-testing` succeeds, no `___llvm_profile_runtime` errors
- **Committed in:** 7c34958 (Task 2 commit)

**2. [Rule 3 - Blocking] Swift 6 concurrency error in Permissions.swift (kAXTrustedCheckOptionPrompt)**
- **Found during:** Task 2 (build-for-testing)
- **Issue:** `kAXTrustedCheckOptionPrompt` is a C global variable flagged by Swift 6 as not concurrency-safe
- **Fix:** Replaced with string literal `"AXTrustedCheckOptionPrompt" as CFString`
- **Files modified:** Sources/Utilities/Permissions.swift
- **Committed in:** 7c34958

**3. [Rule 3 - Blocking] Swift 6 concurrency errors in AppState, ModelManager, engines, delegates**
- **Found during:** Task 2 (build-for-testing)
- **Issue:** Swift 6 language mode enforces region-based isolation as hard errors -- AppState, ModelManager, ASREngine, DiarizationEngine, CalendarMonitor, AppDelegate, and CaddieTests all had `sending` violations
- **Fix:** Added @MainActor (AppState, ModelManager), @unchecked Sendable (ASREngine, DiarizationEngine, CalendarMonitor, AppDelegate), nonisolated(unsafe) (FluidAudio type transfers), Task{@MainActor} (replacing DispatchQueue.main.async), and @MainActor on test methods
- **Files modified:** 7 source files + 1 test file
- **Committed in:** 7c34958

---

**Total deviations:** 3 auto-fixed (all Rule 3 - blocking)
**Impact on plan:** All fixes were necessary to achieve the plan's goal of tests executing. The concurrency fixes formalize existing main-thread usage patterns and are correct annotations, not workarounds.

## Issues Encountered

- The plan's primary fix for the yyjson linker error (scheme-level `coverageTargets`) was insufficient. XcodeGen applies the scheme coverage setting at build time, but the coverage instrumentation is injected at the project level during build-for-testing, affecting all targets including SPM C dependencies. The fallback approach (disabling Clang coverage on the test target) worked correctly.

- Swift 6.0 language mode enforces region-based isolation as hard errors regardless of `SWIFT_STRICT_CONCURRENCY` setting. The `SWIFT_STRICT_CONCURRENCY` flag only controls additional warnings beyond what's already enforced by the language mode. Setting it to `targeted` or `complete` didn't change the `sending` errors. The fix was to annotate the affected types correctly.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Test infrastructure is fully operational -- all future phases can verify their work via `xcodebuild test`
- Swift 6.0 with complete strict concurrency is enforced -- new code must be concurrency-safe
- No blockers for Phase 02 (crash risk elimination)

## Self-Check: PASSED

All 9 modified files verified on disk. Both task commits (b6651e7, 7c34958) verified in git log. SUMMARY.md exists at expected path.

---
*Phase: 01-test-target-revival*
*Completed: 2026-03-22*
