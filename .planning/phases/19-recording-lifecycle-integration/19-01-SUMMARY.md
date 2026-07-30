---
phase: 19-recording-lifecycle-integration
plan: 01
subsystem: recording
tags: [screencapturekit, swift6, protocol-di, userdefaults, xctest, tdd]

# Dependency graph
requires:
  - phase: 18-screen-capture-engine
    provides: ScreenRecorder (hardware-verified SCStream -> AVAssetWriter engine) with onFirstFrameHostTime / onStreamStopped / isRecording / start(target:preset:outputURL:) / stop()
provides:
  - ScreenRecording protocol seam over the Phase 18 engine (mockable, no TCC, no display)
  - ScreenRecorderFactory typealias for per-meeting engine instances
  - ScreenRecordingSettings feature gate (pinned UserDefaults key, default OFF)
  - AudioFileManager.videoPath(for:) canonical <meetingId>.mov layout
  - MockScreenRecorder / MockScreenRecorderFactory test doubles with forced-failure hooks
affects: [19-02 coordinator start wiring, 19-03 teardown + failure containment, 19-04 AppState construction, 20 storage/retention, 21 settings toggle]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Protocol seam via retroactive conformance (extension ScreenRecorder: ScreenRecording {}) — engine file stays byte-identical"
    - "Factory typealias (@Sendable () -> ScreenRecording) for single-use engines"
    - "Settings enum shape: static key + static default + object(forKey:) reader (MeetingPromptSettings precedent)"
    - "@unchecked Sendable + single NSLock test double (MockStreamingEngine precedent)"

key-files:
  created:
    - Sources/Recording/ScreenRecording.swift
    - Sources/Recording/ScreenRecordingSettings.swift
    - Tests/ScreenRecordingSettingsTests.swift
    - Tests/Mocks/MockScreenRecorder.swift
  modified:
    - Sources/Storage/AudioFileManager.swift
    - Tests/ProtocolDITests.swift

key-decisions:
  - "Feature gate reads UserDefaults via object(forKey:) as? Bool ?? default, not bool(forKey:), so 'never set' stays distinguishable from 'explicitly false' (VID-01 opt-in semantics)"
  - "The persisted key is pinned in tests against the raw literal \"screenRecordingEnabled\", never against the constant itself — a production rename must fail the suite, not silently pass"
  - "ScreenRecording is deliberately non-Sendable: a conformer is owned by exactly one isolation domain (the RecordingCoordinator actor), matching AudioRecorder's ownership model"
  - "ScreenRecorder gains the protocol by retroactive conformance in the new file, so the hardware-verified Phase 18 engine file has zero diff"
  - "The settings-key save/restore in setUpWithError/tearDownWithError preserves the developer's real preference — the suite never leaves a mutated UserDefaults domain"

patterns-established:
  - "Pattern: seam-in-a-new-file — abstract an existing verified type without touching it (protocol + retroactive conformance colocated in one new file)"
  - "Pattern: factory-per-use for single-use engines whose restart is a silent no-op"
  - "Pattern: mock factory records every vended instance (instances/latest/totalStartCount) so cross-meeting assertions are possible"

requirements-completed: [VID-03]

# Metrics
duration: 17 min
completed: 2026-07-30
---

# Phase 19 Plan 01: Screen Recording Seams Summary

**`ScreenRecording` protocol seam over the Phase 18 engine (retroactive conformance, engine file untouched), a default-OFF `screenRecordingEnabled` feature gate, `AudioFileManager.videoPath(for:)` yielding `<meetingId>.mov`, and NSLock-guarded mock/factory doubles that make VID-04's forced-failure paths testable with no TCC grant and no real display.**

## Performance

- **Duration:** 17 min
- **Started:** 2026-07-30T19:17:32Z
- **Completed:** 2026-07-30T19:34:49Z
- **Tasks:** 3
- **Files modified:** 6 (4 created, 2 modified)

## Accomplishments

- **Feature gate with honest tri-state semantics.** `ScreenRecordingSettings.isEnabled` reads `object(forKey:) as? Bool ?? defaultEnabled`, so an absent key can never read as enabled. Proven by three separate tests (absent / explicit true / explicit false).
- **Canonical video layout landed before any writer exists.** `AudioFileManager.videoPath(for:)` sits beside `wavPath`/`alacPath` and is asserted to share a directory with `alacPath(for:)` for the same meeting id — one meeting id, exactly one `.mov`.
- **Test seam with a zero-diff engine.** `extension ScreenRecorder: ScreenRecording {}` lives entirely in the new `ScreenRecording.swift`; `git diff --name-only -- Sources/Recording/ScreenRecorder.swift` is empty across the whole plan. The hardware-verified 18-04 engine was never edited.
- **Per-meeting factory contract pinned by a test.** `testScreenRecorderFactoryVendsFreshInstances` asserts two calls return non-identical objects — the guard against the research-verified silent failure where meeting #2 records nothing because `transition(.stopped, .started) == .stopped`.
- **Forced-failure doubles ready for 19-02/19-03.** `MockScreenRecorder` drives start success, start throw, mid-meeting stream death (`simulateStreamDeath`), and slow stop (delay applied *before* the stop counter increments, which is what makes a stop-timeout test meaningful). The real engine is unreachable from tests, so `make test` can never capture the developer's screen.
- **Full suite green: 315 tests, 0 failures** (Phase 18 baseline was 304 — 11 net new tests, no regressions).

## Task Commits

Each task was committed atomically:

1. **Task 1: Feature gate + canonical video path** — `53c9dfc` (test, RED) → `d32eb23` (feat, GREEN)
2. **Task 2: ScreenRecording protocol seam + conformance** — `eb42dd7` (test, RED) → `258c3bc` (feat, GREEN)
3. **Task 3: MockScreenRecorder + MockScreenRecorderFactory** — `9182dcf` (test)

Both TDD tasks produced a genuine RED: Task 1 failed with `cannot find 'ScreenRecordingSettings' in scope` / `type 'AudioFileManager' has no member 'videoPath'`, Task 2 with `cannot find type 'ScreenRecording' in scope` / `cannot find type 'ScreenRecorderFactory' in scope`. No REFACTOR step was needed — both implementations are 20–40 lines with no duplication to extract.

## Files Created/Modified

- `Sources/Recording/ScreenRecording.swift` (new) — `protocol ScreenRecording: AnyObject` (settable `onFirstFrameHostTime` / `onStreamStopped`, get-only `isRecording`, `start(target:preset:outputURL:)`, `stop()`), `typealias ScreenRecorderFactory = @Sendable () -> ScreenRecording`, and `extension ScreenRecorder: ScreenRecording {}`. Doc-comments record why it is non-Sendable and why the factory exists.
- `Sources/Recording/ScreenRecordingSettings.swift` (new) — `enabledKey` / `defaultEnabled` / `isEnabled` feature gate.
- `Sources/Storage/AudioFileManager.swift` (modified) — `videoPath(for:)` added immediately after `alacPath(for:)`, doc-commented that Phase 20 owns deletion.
- `Tests/ScreenRecordingSettingsTests.swift` (new) — 7 tests: key literal pinning, default OFF, absent/true/false reads, `.mov` naming, directory colocation. Saves and restores the developer's real `screenRecordingEnabled` value.
- `Tests/Mocks/MockScreenRecorder.swift` (new) — `MockScreenRecorderError`, `MockScreenRecorder`, `MockScreenRecorderFactory`.
- `Tests/ProtocolDITests.swift` (modified) — 2 tests for the seam and the factory contract.

## Decisions Made

None beyond the plan — every decision listed in frontmatter was specified by the plan or the research it cites. Two implementation choices worth recording:

- **`MockScreenRecorderError` is a new non-private type** rather than a reuse. The three existing test error types (`TestError` in `RecordingStateTests`/`TranscriptionPipelineTests`, `CoordinatorTestError` in `RecordingCoordinatorTests`) are all `private` to their files, so none was reachable. The new struct is file-internal-but-not-private precisely so 19-02/19-03 can assert on its surfaced message.
- **`MockScreenRecorderFactory.startError`/`stopDelay` apply to instances vended from that point on**, not retroactively to already-vended ones — a test that wants meeting #1 to succeed and meeting #2 to fail sets the property between meetings.

## Deviations from Plan

None - plan executed exactly as written.

**Total deviations:** 0
**Impact on plan:** None. All three tasks' acceptance criteria passed on the first verification run.

## Issues Encountered

None.

## Known Stubs

None. Every symbol added is fully implemented; nothing returns a placeholder. The one intentional non-wiring is by design and owned by later plans: `ScreenRecordingSettings.isEnabled` and `videoPath(for:)` have no production callers yet (19-02 wires the coordinator, 19-04 wires `AppState`), and `deleteAudio(meetingId:)` deliberately does not remove `.mov` files — Phase 20 owns video deletion, so a meeting deleted between Phases 19 and 20 leaves an orphaned video. Both are documented in source doc-comments.

## Threat Flags

None. This plan adds no network endpoint, no auth path, and no schema change. The two threat-register mitigations that land here were both implemented as specified: T-19-01 (`defaultEnabled = false` + `object(forKey:)` read, so capture is opt-in) and T-19-02 (`videoPath` composes an app-generated meeting id via `appendingPathComponent` under the app-support directory — no user-supplied path input). T-19-03 holds by construction: no test touches ScreenCaptureKit. T-19-SC is satisfied — `git diff project.yml` is empty, zero package installs.

## Verification

| Check | Result |
|-------|--------|
| `make test` full suite | `** TEST SUCCEEDED **` — 315 tests, 0 failures (baseline 304, +11, no regressions) |
| `-only-testing:CaddieTests/ScreenRecordingSettingsTests` | `** TEST SUCCEEDED **` — 7/7 |
| `-only-testing:CaddieTests/ProtocolDITests` | `** TEST SUCCEEDED **` — 5/5 |
| `git diff --name-only -- Sources/Recording/ScreenRecorder.swift` | empty (engine untouched — hard constraint held) |
| `git diff project.yml` | empty (no package changes; directory globs picked up all 3 new files via `make setup`) |
| All 22 task acceptance criteria (8 + 7 + 7) | PASS, first run, no fix cycles |

## Success Criteria

- `ScreenRecordingSettings.isEnabled` is `false` on a machine that never set the key — **proven** by `testIsEnabledIsFalseWhenKeyAbsent`
- Every meeting id maps to exactly one `.mov` URL beside its audio — **proven** by `testVideoPathIsMovBesideAudio` + `testVideoPathSharesDirectoryWithAlacPath`
- `ScreenRecorder` and `MockScreenRecorder` are interchangeable behind `ScreenRecording` — **proven** by both types compiling as `ScreenRecording` in the test target
- A `ScreenRecorderFactory` vends a distinct instance per call — **proven** by `testScreenRecorderFactoryVendsFreshInstances`

## User Setup Required

None - no external service configuration required. (The `screenRecordingEnabled` key has no toggle UI until Phase 21 and no production reader until 19-04, so there is nothing for a user to set yet. README documentation of the feature is deliberately deferred to the plan that makes it user-observable.)

## Next Phase Readiness

Ready for **19-02**. All three seams it consumes exist verbatim as declared in this plan's `<interfaces>` block:

- `RecordingCoordinator` can now take a `ScreenRecorderFactory?` dependency and be tested against `MockScreenRecorderFactory` with no TCC grant.
- `AudioFileManager.videoPath(for:)` supplies the output URL for `executeStartRecording`.
- `MockScreenRecorder.startError` / `simulateStreamDeath(_:)` / `stopDelay` cover VID-04's three failure modes; `MockScreenRecorderFactory.instances` covers the meeting-#2 regression test.

No blockers. Carried-forward concern (unchanged from research, not introduced here): existing coordinator tests inject a **real** `AudioRecorder`, so they depend on dev-Mac audio hardware. This plan does not worsen that — the video seam is mock-only by construction.

## Self-Check: PASSED

All 4 created files and 2 modified files verified present on disk. All 5 task commits verified in `git log`.

---
*Phase: 19-recording-lifecycle-integration*
*Completed: 2026-07-30*
