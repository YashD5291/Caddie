# Stack Research: Production Hardening

**Domain:** macOS native app hardening (CoreAudio + on-device ML pipeline)
**Researched:** 2026-03-22
**Confidence:** MEDIUM-HIGH

This is NOT a greenfield stack recommendation. The core stack (Swift/SwiftUI/GRDB/FluidAudio/CoreAudio) is already shipped. This research covers the tooling, patterns, and configuration changes needed to harden the existing app for production reliability.

## Recommended Stack Changes

### Testing Infrastructure

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| Swift Testing | Built-in (Xcode 16+) | Unit test framework | Parallel by default, native async/await support, parameterized tests via `@Test` macro. XCTest lacks built-in parameterization and requires `XCTestExpectation` boilerplate for async tests. Use Swift Testing for all new tests, keep XCTest only for existing tests that work. |
| XcodeGen `coverageTargets` | 2.42+ | Selective code coverage | Solves the yyjson linker crash. Set `coverageTargets: [Caddie]` to exclude FluidAudio's C dependency (yyjson) from coverage instrumentation. Without this, `CLANG_ENABLE_CODE_COVERAGE` causes `___llvm_profile_runtime` undefined symbol errors in C targets. |
| GRDB in-memory testing | 7.10.0 (current) | Migration and DB testing | Already have `init(inMemory:)` in Database.swift. Use `DatabaseQueue()` for isolated test databases. GRDB's `DatabaseMigrator` supports `migrate(upTo:)` for version-specific migration testing. |

### Concurrency Hardening

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| Swift 6.1+ strict concurrency | Xcode 16.3+ | Compile-time data race detection | Enable `-strict-concurrency=complete` build setting. The TranscriptionPipeline is already an actor but AppState is `@Observable final class` with `[weak self]` closures crossing isolation boundaries. Strict concurrency will surface these at compile time. |
| `withTaskCancellationHandler` | Swift stdlib | Cooperative cancellation for ML pipeline | The transcription pipeline has no cancellation support. Long-running ASR/diarization tasks (minutes) should check `Task.isCancelled` between steps and use `withTaskCancellationHandler` to propagate cancellation to the underlying FluidAudio operations. |
| `withThrowingTaskGroup` timeout | Swift stdlib | Model download timeout | Replace unbounded `await modelManager.downloadModelsIfNeeded()` with a task group race pattern: one task does the download, another sleeps for 300s and throws `TimeoutError`. First completion wins, `group.cancelAll()` cleans up the loser. |

### Error Handling & Logging

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| `os.Logger` (already in use) | macOS 14+ | Structured logging | Already set up in CaddieLogger.swift with subsystem/category. The issue is not the logger itself but the 14 `try?` call sites that suppress errors without logging. Every `try?` should become `do/catch` with a `logger.warning()` or `logger.error()`. No new library needed. |
| Custom `OSStatus` extension | N/A | CoreAudio error translation | Add a `fourCharCode` extension on `OSStatus` to translate numeric error codes to human-readable strings (e.g., `1852797029` -> `'kAHD'`). CoreAudio returns opaque OSStatus codes that are useless without translation. |

### Data Integrity

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| GRDB 7.10.0 | 7.10.0 | Already in use | Pinned at 7.10.0 which is current as of Feb 2026. Requires Swift 6.1+/Xcode 16.3+. Includes FTS5 cancellation fix. No version bump needed. |
| `URLResourceValues.volumeAvailableCapacityForImportantUsage` | Foundation (macOS 14+) | Disk space checking | Apple's recommended API for checking available storage. Returns `Int64?` of bytes available for "important" usage (accounts for purgeable space). Use before recording starts and before ALAC compression. No external dependency needed. |
| GRDB `DatabaseMigrator.eraseDatabaseOnSchemaChange` | 7.10.0 | Dev-only migration reset | Wrap in `#if DEBUG` to auto-recreate DB when migrations change during development. Must NOT ship in release builds. |

### CoreAudio Resilience

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| `AudioObjectAddPropertyListenerBlock` | CoreAudio (macOS 14+) | Device change monitoring | Register for `kAudioHardwarePropertyDevices` changes to detect when the tapped process's audio device disappears mid-recording. SimplyCoreAudio wraps this via `deviceListChanged` notification, which is already a dependency. |
| Aggregate device UID tracking | N/A (pattern, not library) | Cleanup on crash recovery | Store the aggregate device UID in UserDefaults. On app launch, check if a stale aggregate device exists and destroy it. Error code `1852797029` from `AudioHardwareCreateAggregateDevice` means a device with that UID already exists. |

## Supporting Libraries (No Changes)

These are already correct and should stay:

| Library | Version | Purpose | Status |
|---------|---------|---------|--------|
| GRDB | 7.10.0 | SQLite with WAL, FTS5, migrations | Keep. Current version. |
| FluidAudio | 0.12.4 | ASR (Parakeet) + diarization (Sortformer) | Keep. ML backbone. |
| SimplyCoreAudio | 4.1.1 | Microphone capture | Keep. Also useful for device change notifications. |
| AXSwift | 0.3.2 | Window title monitoring | Keep. Stable. |
| Sparkle | 2.9.0 | Auto-updates | Keep. Standard for non-App Store macOS distribution. |

## Build System Configuration Changes

### XcodeGen project.yml changes needed:

```yaml
# Fix: Test target code coverage (solves yyjson linker crash)
schemes:
  CaddieTests:
    build:
      targets:
        Caddie: [test]
    test:
      gatherCoverageData: true
      coverageTargets:
        - Caddie  # Only instrument the app target, not SPM C dependencies
      targets:
        - CaddieTests

# Fix: Enable strict concurrency checking
settings:
  base:
    SWIFT_STRICT_CONCURRENCY: complete  # or 'targeted' as stepping stone
```

### Alternative: If XcodeGen scheme-level coverage doesn't resolve the yyjson issue

The root cause is `CLANG_ENABLE_CODE_COVERAGE=YES` being applied to the yyjson C target. If `coverageTargets` doesn't prevent this (XcodeGen applies coverage at scheme level, not build-setting level), the fallback is:

```yaml
# In the test target settings:
CaddieTests:
  settings:
    base:
      CLANG_ENABLE_CODE_COVERAGE: NO  # Disable Clang coverage, keep Swift coverage
```

This disables C-level coverage instrumentation while Swift coverage still works through the Swift compiler's own profiling.

## Alternatives Considered

| Recommended | Alternative | Why Not |
|-------------|-------------|---------|
| Swift Testing | XCTest only | XCTest works but lacks parameterized tests, requires XCTestExpectation for async, runs tests serially by default. Swift Testing is Apple's direction. |
| `os.Logger` (keep) | SwiftyBeaver, CocoaLumberjack | External logging libraries add dependency for something Apple's framework handles well. `os.Logger` integrates with Console.app and Xcode console filtering. The app already uses it. |
| GRDB (keep) | SwiftData | SwiftData lacks FTS5 support, migration control, and raw SQL escape hatches. GRDB is the right choice for a data-intensive app with custom schema. |
| `URLResourceValues` disk check | `FileManager.attributesOfFileSystem` | `attributesOfFileSystem` returns raw free space without accounting for purgeable storage. Apple recommends `volumeAvailableCapacityForImportantUsage` for accurate estimates. |
| `withThrowingTaskGroup` timeout | `DispatchWorkItem` + timer | Mixing GCD with structured concurrency creates cancellation leaks. Stay within Swift Concurrency for timeouts. |
| Strict concurrency (`complete`) | `targeted` mode | `targeted` only checks code you've explicitly annotated. `complete` catches all violations. Since we're hardening, catch everything. Start with `targeted` if `complete` produces too many warnings. |

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| `DispatchQueue` / GCD for new async work | Mixing GCD with Swift Concurrency actors causes subtle data race bugs. The TranscriptionPipeline is an actor; CalendarMonitor uses `DispatchQueue.main.async`. These should not be mixed in new code. | `Task { @MainActor in ... }` for main-thread work. Actor isolation for serialization. |
| `try?` without logging | 14 instances currently suppress errors silently. This directly violates the core value of "no silent failures." Every `try?` is a potential lost recording or corrupted state. | `do { try ... } catch { logger.warning(...) }` or `do { try ... } catch { throw PipelineError.wrapping(error) }` for critical paths. |
| `Unmanaged.passUnretained(self)` without safety net | Used in SystemAudioCapture.swift:287 for the render callback. If `self` is deallocated while the audio unit is running, this is a use-after-free crash on the real-time audio thread. | Set `onBuffer = nil` and stop the audio unit BEFORE releasing the SystemAudioCapture instance. The `deinit` calls `stop()` but verify stop completes synchronously. |
| Global mutable state for audio device IDs | `aggregateDeviceID` and `tapObjectID` are instance vars on a non-Sendable class accessed from the render callback thread. | Keep current pattern (the render callback only reads `audioUnit` and `onBuffer`), but ensure `stop()` is called from the same thread or add `@unchecked Sendable` with a documented safety argument. |
| `precondition` in production database init | `Database.swift:28` uses `precondition(inMemory)` which will crash in release builds if called wrong. | Use `assert` (debug-only) or throw an error. Precondition is appropriate here since it's an API contract, but flag it in code review. |

## Swift 6.2 Consideration

Swift 6.2 (Xcode 17, expected mid-2026) introduces `@concurrent` and `defaultIsolation(MainActor.self)`. Key implications:

- **`@concurrent`**: Marks functions that explicitly run off-actor. Nonisolated async functions will run on the caller's actor by default (behavior change from Swift 6.1).
- **`defaultIsolation MainActor`**: New projects default to MainActor isolation. Existing projects opt in. This would eliminate many of the `[weak self]` + `DispatchQueue.main.async` patterns in AppState.
- **Recommendation**: Do NOT adopt Swift 6.2 features yet. The hardening milestone should target Swift 6.1 with `strict-concurrency=complete`. Migrate to 6.2 patterns in a subsequent milestone once the concurrency model is clean.

## Version Compatibility

| Component | Requires | Notes |
|-----------|----------|-------|
| GRDB 7.10.0 | Swift 6.1+, Xcode 16.3+, macOS 10.15+ | Currently using Swift 5.9. GRDB 7.10 bumped its minimum to Swift 6.1. Verify the project builds with Xcode 16.3+ or pin to GRDB 7.9.0 (which supports Swift 5.9). |
| Swift Testing | Xcode 16+, macOS 13+ | Ships with Xcode, no SPM dependency needed. Import `Testing` instead of `XCTest`. |
| `coverageTargets` | XcodeGen 2.38+ | Available since PR #700 merged. Verify installed XcodeGen version with `xcodegen version`. |
| macOS 14.2 deployment target | Xcode 15+ | Already set. CATapDescription API requires macOS 14.2+. |
| FluidAudio 0.12.4 | yyjson 0.12.0 (transitive) | The C dependency causing test linker issues. Cannot be removed, must be excluded from coverage. |

**CRITICAL COMPATIBILITY NOTE**: GRDB 7.10.0 requires Swift 6.1+, but project.yml specifies `SWIFT_VERSION: "5.9"`. Either:
1. Update `SWIFT_VERSION` to `"6.0"` or `"6.1"` (recommended -- enables strict concurrency)
2. Pin GRDB to `~> 7.8.0` which supports Swift 5.9

Option 1 is strongly recommended since strict concurrency checking is a core goal of this hardening milestone.

## Sources

- [Apple Developer: Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps) -- CoreAudio tap patterns
- [CoreAudio Tap reference implementation by sudara](https://gist.github.com/sudara/34f00efad69a7e8ceafa078ea0f76f6f) -- Error handling, aggregate device gotchas
- [GRDB.swift GitHub](https://github.com/groue/GRDB.swift) -- v7.10.0 release, migration testing, Swift 6.1 requirement
- [GRDB migration testing issue #648](https://github.com/groue/GRDB.swift/issues/648) -- In-memory DB testing patterns, snapshot approach
- [Swift SR-14788: Linker error with code coverage on C/ObjC packages](https://github.com/apple/swift/issues/57137) -- Root cause of yyjson linker issue
- [XcodeGen coverageTargets PR #700](https://github.com/yonaskolb/XcodeGen/pull/700) -- onlyGenerateCoverageForSpecifiedTargets
- [XcodeGen ProjectSpec docs](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md) -- coverageTargets YAML syntax
- [Swift 6.2 concurrency changes](https://www.donnywals.com/exploring-concurrency-changes-in-swift-6-2/) -- @concurrent, defaultIsolation
- [Apple Developer: volumeAvailableCapacityForImportantUsage](https://developer.apple.com/documentation/foundation/urlresourcevalues/volumeavailablecapacityforimportantusage) -- Disk space API
- [Donnywals: Task timeout with Swift Concurrency](https://www.donnywals.com/implementing-task-timeout-with-swift-concurrency/) -- withThrowingTaskGroup timeout pattern
- [HackingWithSwift: Actor reentrancy](https://www.hackingwithswift.com/quick-start/concurrency/what-is-actor-reentrancy-and-how-can-it-cause-problems) -- Reentrancy patterns
- [SwiftLee: os.Logger unified logging](https://www.avanderlee.com/debugging/oslog-unified-logging/) -- Structured logging best practices
- [Swift Testing vs XCTest](https://blog.micoach.itj.com/swift-testing-vs-xctest) -- Framework comparison
- [SwiftwithMajid: Task cancellation](https://swiftwithmajid.com/2025/02/11/task-cancellation-in-swift-concurrency/) -- Cooperative cancellation patterns

---
*Stack research for: macOS app production hardening (CoreAudio + on-device ML)*
*Researched: 2026-03-22*
