---
phase: 20-video-storage-retention
plan: 05
subsystem: coordinator
tags: [disk-guard, stor-03, d-01, d-02, d-03, video, coordinator, seam]

# Dependency graph
requires:
  - phase: 19-recording-lifecycle-integration
    provides: "ScreenRecorderFactory 'inert by absence' gate, non-fatal setOnVideoError channel, startVideo/startVideoInner, MockScreenRecorderFactory"
  - phase: 18-screen-capture-engine
    provides: "ScreenRecorder.QualityPreset with default and bitrate caps"
provides:
  - "RecordingCoordinator.DiskSpaceTier { belowAudioFloor, belowVideoThreshold, sufficient } - only belowAudioFloor blocks"
  - "RecordingCoordinator.videoDiskThreshold(for:) - 500 MiB floor + 2 h at the preset bitrate cap (1,874,288,000 / 2,774,288,000 / 4,124,288,000 bytes)"
  - "RecordingCoordinator.diskSpaceTier(available:videoPreset:) - pure decision; nil preset = floor only"
  - "RecordingCoordinator.lowDiskVideoMessage(availableBytes:requiredBytes:) - copy for the non-fatal video channel"
  - "RecordingCoordinator.DiskSpaceProvider + trailing init param availableDiskSpace (default systemAvailableDiskSpace)"
  - "private static videoPreset - one preset source for capture and threshold"
affects: [20-06 coordinator finalize/verify funnel (shares the init seam list and the startVideo call site), 20-07 docs (README low-disk audio-only fallback, STOR-03 wording), 21 settings (preset picker changes videoPreset)]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Pre-start guard as a pure static decision over one injected capacity snapshot"
    - "Video-leg conditions are surfaced from inside the .startRecording side effect, after onStateChange(.recording), so AppState's clear-on-recording never erases them"

key-files:
  created:
    - Tests/DiskSpaceTierTests.swift
    - Tests/RecordingCoordinatorDiskGuardTests.swift
  modified:
    - Sources/Coordinator/RecordingCoordinator.swift

key-decisions:
  - "20-05: The D-01 tier decision lives in the coordinator precondition (evaluateDiskSpace in executeStartRecording): one capacity read decides both tiers, and the video tier is gated on screenRecorderFactory != nil, the same inert-by-absence gate as startVideo"
  - "20-05: The low-disk skip runs at the startVideo call site after audio has started, so the message lands after .recording; it never calls handle(.recordingFailed) and never touches state"

patterns-established:
  - "Capacity seam: typealias DiskSpaceProvider = @Sendable () throws -> Int64?; throw propagates to .recordingFailed, nil maps to 0 and blocks"
  - "Scripted provider in tests throws once its script runs out, so an extra capacity read fails loudly"

requirements-completed: [STOR-03]

# Metrics
duration: 9min
completed: 2026-11-19
---

# Phase 20 Plan 05: Two-Tier Disk Guard Summary

**The disk guard now has two tiers. Below the 500 MiB audio floor, recording is blocked exactly as before. With screen recording on and free space below the preset-derived video threshold (2.77 GB for the default balanced preset), the meeting records audio only and a "not enough free disk space" message goes to the non-fatal video channel. Free space comes from one injectable provider read.**

## Performance

- **Duration:** ~9 min
- **Started:** 2026-11-19T13:49:43Z
- **Completed:** 2026-11-19T13:59:23Z
- **Tasks:** 2 (each RED + GREEN commit)
- **Files modified:** 3 (2 created, 1 modified)

## Accomplishments
- Pure statics on the actor: `DiskSpaceTier`, the internal `minimumDiskSpaceBytes` (same 500 MiB value), `videoHeadroomSeconds = 2 * 60 * 60`, `videoDiskThreshold(for:)` (Int64 multiply before the divide), `diskSpaceTier(available:videoPreset:)` with inclusive `>=` boundaries, and `lowDiskVideoMessage`
- `checkDiskSpace()` is replaced by `evaluateDiskSpace()`. It calls the injected provider once, maps nil to 0, and throws `insufficientDiskSpace(available:required:)` only for `.belowAudioFloor`. The caller keeps the old `do { … } catch { …; handle(.recordingFailed) }` shape
- `systemAvailableDiskSpace()` is the default provider and does the same important-usage capacity read as before. All existing construction sites, AppState included, compile unchanged
- `private static let videoPreset = .default` replaces the hard-coded `.balanced` at the capture start, so capture and threshold share one source. `.default` is `.balanced`, so capture behavior is unchanged
- `skipVideoForLowDisk` logs a warning with the meeting id and both byte counts, then calls `surfaceVideoError(lowDiskVideoMessage(...))`
- 9 `DiskSpaceTierTests` (exact thresholds and boundaries) and 9 `RecordingCoordinatorDiskGuardTests` (injected capacity, ordering, single read)

## Task Commits

1. **Task 1: pure two-tier decision and preset-derived threshold** - `c1cbc43` (test, RED), `48ad389` (feat, GREEN)
2. **Task 2: wire the tier through an injectable capacity seam** - `14259d4` (test, RED), `4401356` (feat, GREEN)

## Files Created/Modified
- `Sources/Coordinator/RecordingCoordinator.swift` - tier enum and statics, `DiskSpaceProvider` seam and init param, `systemAvailableDiskSpace`, `evaluateDiskSpace`, `videoPreset`, `skipVideoForLowDisk`, branch at the `startVideo` call site
- `Tests/DiskSpaceTierTests.swift` - constants, per-preset thresholds, threshold above floor for every preset, floor and threshold boundaries, non-positive and max capacity, feature off at 600 MiB, copy names both sizes
- `Tests/RecordingCoordinatorDiskGuardTests.swift` - below floor with and without video (no row, factory never called, no video message), thrown read, nil read, 1 GB audio-only (row is `recording`, no engine, one "disk space" message), exactly at threshold starts video, feature off at 600 MiB records with no warning, `.recording` event precedes the message, one read per attempt across a blocked attempt and an audio-only attempt

## Verification
- RED confirmed for both tasks: compile failures on the missing statics, then on the missing `DiskSpaceProvider` / `availableDiskSpace`
- Task 1 command (`DiskSpaceTierTests`): 9 tests, `** TEST SUCCEEDED **`
- Task 2 command (`RecordingCoordinatorDiskGuardTests` + `DiskSpaceTierTests` + both screen-capture suites + `RecordingCoordinatorTests`): 56 tests, `** TEST SUCCEEDED **`
- `make test`: **409 tests, 0 failures**, `** TEST SUCCEEDED **` (391 baseline + 18 new)
- All acceptance greps pass. `checkDiskSpace` and `preset: .balanced` appear 0 times, `preset: Self.videoPreset` appears once, no `skipVideoForLowDisk` line mentions `recordingFailed`, and `git diff --stat` on `AppState.swift` and `RecordingState.swift` is empty

## Decisions Made
- The tier decision lives in the coordinator precondition, as the plan chose under Claude's discretion. It is the one place that has a single capacity snapshot for both tiers and the factory gate
- `diskCheck` is declared before the `do` and assigned inside it. This keeps the existing do/catch shape and still makes the tier available at the `startVideo` call site
- `CoordinatorError.insufficientDiskSpace` copy is unchanged. "required: 500 MB" is still correct, because that error now fires only for the floor tier

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Test capacity constants marked `nonisolated`**
- **Found during:** Task 2 GREEN
- **Issue:** In the `@MainActor` test class, `private static let` constants are main-actor isolated. Swift 6 rejected referencing them from the `@Sendable` provider closures
- **Fix:** Changed them to `nonisolated private static let` (Int64 is Sendable). Test logic is unchanged
- **Files modified:** Tests/RecordingCoordinatorDiskGuardTests.swift
- **Commit:** 4401356

**2. [Test strength] The single-read test spans two attempts**
- **Found during:** Task 2 RED
- **Issue:** One start would only show that the provider is read at least once on one path
- **Fix:** A scripted provider gives 400 MiB (blocked, `.error`) and then 1 GB (audio-only, recording from `.error`). The test asserts the count is 1 and then 2. The script throws if it runs out, so an extra read fails the test
- **Files modified:** Tests/RecordingCoordinatorDiskGuardTests.swift
- **Commit:** 14259d4

## Issues Encountered
- The coordinator rig the plan prescribes uses a real `AudioRecorder`. Tests that reach `.recording` therefore create a WAV at `AudioFileManager.wavPath(for:)` in the real audio directory, as every existing coordinator suite already does. The four blocked-start tests never reach the recorder. This plan adds no deletion or cleanup against that directory, so D-15's cleanup and deletion isolation rule holds. Making the coordinator's audio directory injectable would be a separate change

## Known Stubs
None.

## TDD Gate Compliance
Each task has a `test(20-05)` RED commit followed by a `feat(20-05)` GREEN commit. No refactor commit was needed.

## Next Phase Readiness
- 20-06 adds its `videoInspector` init parameter next to `availableDiskSpace`. It also wires `onFinalized` inside `startVideoInner`, which the low-disk branch never reaches, so a skipped meeting has no `.mov` to link or verify
- 20-07 docs: the README should describe the audio-only fallback and the 2.77 GB threshold for the default preset. STOR-03 and ROADMAP wording should be updated per D-01
- No blockers

## Self-Check: PASSED
- FOUND: Tests/DiskSpaceTierTests.swift, Tests/RecordingCoordinatorDiskGuardTests.swift, Sources/Coordinator/RecordingCoordinator.swift
- FOUND commits: c1cbc43, 48ad389, 14259d4, 4401356

---
*Phase: 20-video-storage-retention*
*Completed: 2026-11-19*
