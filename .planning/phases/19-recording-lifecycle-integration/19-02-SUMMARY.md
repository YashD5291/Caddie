---
phase: 19-recording-lifecycle-integration
plan: 02
subsystem: recording
tags: [screencapturekit, swift6, actor-isolation, region-isolation, tdd, vid-03, vid-04, stor-04]

# Dependency graph
requires:
  - phase: 19-01
    provides: ScreenRecording protocol seam, ScreenRecorderFactory typealias, AudioFileManager.videoPath(for:), MockScreenRecorder/MockScreenRecorderFactory
provides:
  - RecordingCoordinator.init(..., screenRecorderFactory:) optional trailing dependency
  - Per-meeting video start after audio, for manual AND calendar-prompted triggers
  - VideoContext (in-flight meeting id, .mov URL, engine, STOR-04 anchor pair, streamDied)
  - videoStartTask — the handle 19-03's stopVideo() joins before stopping
  - RecordingCoordinator.setOnVideoError — dedicated non-fatal video error channel
  - DEBUG accessors isVideoActive / videoAnchorPair / videoOutputURL
affects: [19-03 teardown + stop timeout, 19-04 AppState construction + menu-bar surface, 20 anchor persistence]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Unstructured Task created in actor context to defer slow framework setup off the hot path, with the Task handle stored for later join"
    - "Publish in-flight context BEFORE the async start so an early callback has somewhere to land"
    - "Dedicated non-fatal error channel (callback setter) separate from the fatal state machine"

key-files:
  created:
    - Tests/RecordingCoordinatorScreenCaptureTests.swift
  modified:
    - Sources/Coordinator/RecordingCoordinator.swift

key-decisions:
  - "VideoContext.recorder is var/optional, attached the instant start() returns rather than at context creation — Swift 6 region isolation rejects storing the non-Sendable engine into actor state before the await start(...) call (it makes the call an illegal cross-domain send)"
  - "startVideo is synchronous and schedules startVideoInner in videoStartTask — awaiting SCK setup inline stalls the coordinator actor ~215 ms (18-04 measurement), long enough for a .manualStop to run teardown before the start lands"
  - "A start that completes after teardown (context meetingId no longer matches) stops its own orphan engine rather than leaking a running capture"
  - "handleVideoStreamStopped keeps the context (streamDied = true) rather than nilling it, so 19-03's teardown still finalizes the playable partial .mov (VID-07)"
  - "A stream death arriving with no in-flight context is logged at .info, not silently dropped — the user-facing error was already surfaced by the start failure"
  - "Doc comments avoid the literal tokens `lastRecordingError` and `handle(.recordingFailed` so the plan's grep gates measure code, not prose"

patterns-established:
  - "Pattern: publish-context-then-start — the in-flight record exists before the async call that can fire callbacks into it"
  - "Pattern: subordinate subsystem with its own error channel — a failure logs, surfaces, and returns; it never reaches the state machine"

requirements-completed: [VID-03, VID-04]

# Metrics
duration: 13 min
completed: 2026-07-31
---

# Phase 19 Plan 02: Coordinator Video Start Wiring Summary

**`RecordingCoordinator` now vends a fresh capture engine per meeting, starts it only after audio is genuinely running, writes to the meeting's canonical `<meetingId>.mov`, holds both halves of the STOR-04 anchor in memory, and routes every video failure to a dedicated non-fatal channel that can never reach `.error` or abort the audio recording.**

## Performance

- **Duration:** 13 min
- **Started:** 2026-07-31T01:06Z (local +05:30)
- **Completed:** 2026-07-31T01:19Z (local +05:30)
- **Tasks:** 2 (both TDD, RED → GREEN, no REFACTOR needed)
- **Files modified:** 2 (1 created, 1 modified)

## Accomplishments

- **One wiring point covers both trigger types.** `.manualStart` and `.meetingDetected` converge on the single `.startRecording` side effect, so a single `startVideo(...)` call in `executeStartRecording` satisfies VID-03 for manual and calendar-prompted meetings alike — proven by two separate tests, with zero branching on trigger type and zero reducer changes.
- **Audio is unambiguously the senior partner.** `mach_absolute_time()` is sampled on the line immediately after `try recorder.start(...)` returns, and `startVideo` is called after the live-transcriber block and before the recording notification. Nothing in the video path can precede, gate, or fail the audio start. With no factory injected the behavior is byte-for-byte unchanged (`testRecordingWorksWithoutScreenRecorder`).
- **The start never stalls the actor.** `startVideo` is synchronous: it stores `videoStartTask = Task { … }` and returns. The measured ~215 ms SCK setup (18-04) no longer suspends the coordinator between audio start and `NotificationManager.recordingStarted`, and 19-03 has the handle it needs to join the start before stopping.
- **Anchor pair captured with no race.** The `VideoContext` is published *before* `start()`, so the first-frame callback — which the mock fires synchronously inside `start` — always finds somewhere to record into. `testAnchorPairCapturedInMemory` asserts a non-zero audio tick and a non-nil first-frame tick, which doubles as proof that both callbacks were assigned before `start()` (assigning after is a silent no-op against `WriterSink`).
- **Every VID-04 failure mode is contained and honest.** A start throw and a mid-meeting stream death each surface exactly one message on `onVideoError`, leave the coordinator in `.recording` with the DB row still `recording`, mark video inactive, and still transcribe normally on stop. `grep -c 'lastRecordingError'` on the coordinator is 0 — the misleading "Last recording failed" surface is untouched.
- **Full suite green: 326 tests, 0 failures** (19-01 baseline was 315 — 11 net new tests, no regressions). All four pre-existing `RecordingCoordinator(` construction sites compile with zero edits, proving the new parameter is source-compatible.

## Task Commits

Each task was committed atomically:

1. **Task 1: Per-meeting video start + in-memory anchor pair** — `460f19b` (test, RED) → `a7f4a7e` (feat, GREEN)
2. **Task 2: Non-fatal video error channel + containment** — `b3869f9` (test, RED) → `94348cc` (feat, GREEN)

Both tasks produced a genuine RED: Task 1 failed with `extra argument 'screenRecorderFactory' in call` plus three `has no member` errors for the DEBUG accessors; Task 2 with `value of type 'RecordingCoordinator' has no member 'setOnVideoError'`.

## Files Created/Modified

- `Sources/Coordinator/RecordingCoordinator.swift` (modified) — `screenRecorderFactory` dependency + trailing init parameter; `onVideoError` + `setOnVideoError`; `private struct VideoContext`; `videoContext` / `videoStartTask`; `startVideo`, `startVideoInner`, `recordFirstFrameAnchor`, `handleVideoStreamStopped`, `surfaceVideoError`; anchor capture in `executeStartRecording`; three `#if DEBUG` accessors beside `isLiveTeeAttached`.
- `Tests/RecordingCoordinatorScreenCaptureTests.swift` (new) — 11 tests: 6 for the VID-03 start path and the anchor, 5 for VID-04 containment, plus a lock-guarded `ErrorCollector`.

`Sources/Coordinator/RecordingState.swift` and `Sources/Recording/ScreenRecorder.swift` have zero diff across this plan — no new reducer state or event, and the hardware-verified Phase 18 engine remains untouched.

## Decisions Made

- **`VideoContext.recorder` is optional, populated after `start()` returns.** The plan specified `let recorder: ScreenRecording` assigned at context creation. That does not compile: storing the non-Sendable existential into actor state merges it into the actor's isolation region, after which `await recorder.start(...)` is rejected as `sending value of non-Sendable type 'any ScreenRecording' risks causing data races`. Keeping the engine in a disconnected local across the `await` and attaching it immediately afterwards preserves the plan's real requirement (context published before start, so an early first frame lands) while satisfying Swift 6. 19-03 is unaffected: `stopVideo()` joins `videoStartTask` first, so the engine is always non-nil by the time teardown needs it.
- **An orphan-stop guard on the late-start path.** If `videoContext?.meetingId` no longer matches when `start()` returns, the coordinator stops that engine itself instead of leaving a capture running with no owner. 19-03's task-join makes this unreachable in normal flow, but a running SCStream writing forever is not an acceptable failure mode to leave unguarded (Rule 2).
- **Stream deaths with no in-flight context are logged, not dropped.** `handleVideoStreamStopped` returns early when there is no context (start already failed, or the meeting already ended), but logs the detail first so the log sequence stays readable. The user-facing message was already surfaced by whichever failure cleared the context.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] `VideoContext.recorder` could not be stored before `await start(...)`**
- **Found during:** Task 1 (first GREEN build)
- **Issue:** The plan's `let recorder: ScreenRecording` assigned at `VideoContext` construction (before `start`) fails to compile under Swift 6 strict concurrency: `Sources/Coordinator/RecordingCoordinator.swift:409: error: sending value of non-Sendable type 'any ScreenRecording' risks causing data races`. Region isolation merges the engine into the actor's region on the store, making the subsequent nonisolated `await start(...)` an illegal send. (The research's compile check placed the context assignment *after* `start`, so it never exercised this ordering.)
- **Fix:** `VideoContext.recorder` became `var recorder: ScreenRecording?`, assigned via `videoContext?.recorder = recorder` immediately after `start()` returns. The context itself is still published before `start()`, so the anchor-capture ordering guarantee the plan actually cared about is preserved. Doc-commented at the field with the exact reason.
- **Files modified:** `Sources/Coordinator/RecordingCoordinator.swift`
- **Commit:** `a7f4a7e`

**2. [Rule 2 - Missing safety] Orphan capture on a start that outlives teardown**
- **Found during:** Task 1
- **Issue:** With the recorder attached only after `start()` returns, a teardown that raced ahead would leave a started engine unreachable — a capture writing forever with no stop path.
- **Fix:** A `guard videoContext?.meetingId == meetingId` after `start()`; on mismatch the coordinator logs a warning and calls `await recorder.stop()` on the local before returning.
- **Files modified:** `Sources/Coordinator/RecordingCoordinator.swift`
- **Commit:** `a7f4a7e`

**3. [Rule 3 - Blocking] Grep gates were matching doc-comment prose**
- **Found during:** Task 1 and Task 2 acceptance checks
- **Issue:** `grep -c 'mach_absolute_time()'` returned 2 and `grep -c 'lastRecordingError'` returned 2 — in both cases the extra hits were doc comments explaining the design, not code. The gates exist to measure code, and a comment that trips a safety gate makes the gate useless.
- **Fix:** Reworded three doc comments to describe the same facts without the literal tokens (`Mach host ticks sampled…`, `AppState's fatal recording-error surface`, `must never raise the recording-failed event`). No behavior change.
- **Files modified:** `Sources/Coordinator/RecordingCoordinator.swift`
- **Commits:** `a7f4a7e`, `94348cc`

**Total deviations:** 3 (2 blocking, 1 safety addition)
**Impact on plan:** None to scope or contracts. Every interface this plan promised 19-03/19-04 exists with the declared name and signature; only `VideoContext`'s internal (private) recorder field differs from the plan's wording.

## Issues Encountered

One real compile failure (deviation 1), resolved in a single iteration. No fix-cycle limits approached.

## Known Stubs

None. Every symbol added is fully implemented.

Two intentional non-wirings, both owned by later plans and both documented in source doc-comments:
- `videoStartTask` is stored but never joined in this plan — 19-03's `stopVideo()` is its consumer. Nothing stops video yet, so a meeting started with a factory injected currently leaves the capture running until the process exits. That is 19-03's entire scope (this plan is explicitly the "start half").
- `setOnVideoError` has no production caller yet — 19-04 wires it into `AppState`/`MenuBarView`. Until then a video failure is logged and reaches the (unset) channel with no UI.

Neither is reachable in production today: `AppState` does not yet pass a factory, so `screenRecorderFactory` is nil and every video path is inert.

## Threat Flags

None. No network endpoint, auth path, or schema change. The plan's threat-register mitigations landed as specified:
- **T-19-04 (DoS):** video start runs in `videoStartTask`, so SCK setup cannot stall the actor — verified by construction (`startVideo` is synchronous and returns immediately).
- **T-19-05 (Repudiation):** every video failure calls `surfaceVideoError`; there is no silent catch in any video path. `grep -c 'audio is still recording'` returns exactly 2 (start failure + stream death), and no `handle(.recordingFailed` appears in any video method.
- **T-19-06 (Information disclosure):** the coordinator vends an engine only when a factory was injected; tests inject mocks exclusively, so `make test` can never capture the screen.
- **T-19-07 (Tampering):** `git diff --name-only -- Sources/Coordinator/RecordingState.swift` is empty.
- **T-19-SC:** zero package installs; `project.yml` unchanged.

## Verification

| Check | Result |
|-------|--------|
| `make test` full suite | `** TEST SUCCEEDED **` — 326 tests, 0 failures (baseline 315, +11, no regressions) |
| `-only-testing:CaddieTests/RecordingCoordinatorScreenCaptureTests` | `** TEST SUCCEEDED **` — 11/11 |
| `git diff --name-only -- Sources/Coordinator/RecordingState.swift Sources/Recording/ScreenRecorder.swift` | empty (no reducer change, engine untouched) |
| 4 pre-existing `RecordingCoordinator(` construction sites | compile with zero edits (source-compatible trailing parameter) |
| Task 1 acceptance criteria (11) | PASS — all greps return their required counts; callback assignments at lines 398/401 precede `start(target:` at line 418 |
| Task 2 acceptance criteria (9) | PASS — `lastRecordingError` count 0, `audio is still recording` count 2, no `handle(.recordingFailed` in any video method |

## Success Criteria

- Manual and calendar-prompted starts both begin video exactly once, after audio, at `<meetingId>.mov` — **proven** by `testManualStartStartsVideo`, `testMeetingDetectedStartsVideo`, `testVideoOutputPathIsMeetingMov`
- The anchor pair is held in memory and logged for the in-flight meeting — **proven** by `testAnchorPairCapturedInMemory`
- A start throw or a mid-meeting stream death leaves the meeting in `.recording` with a surfaced message — **proven** by `testVideoStartFailureDegradesToAudioOnly`, `testStreamDeathMidMeetingSurfacesAndKeepsAudio`, `testStreamDeathMarksVideoInactive`
- No video code path can reach `.error` — **proven** by `testVideoFailureNeverEntersErrorState` plus the grep gate that no video method raises the recording-failed event

## User Setup Required

None. The feature remains unreachable in production until 19-04 injects a factory; there is still nothing for a user to set. README documentation is deferred to the plan that makes the feature user-observable.

## Next Phase Readiness

Ready for **19-03**. Every contract it consumes exists verbatim:

- `videoContext` (with `outputURL`, `recorder`, `streamDied`) and `videoStartTask` — join the task, then `await videoContext?.recorder?.stop()`, then clear the context.
- `surfaceVideoError(_:)` — the channel a stop failure or stop timeout reports through.
- `MockScreenRecorderFactory.stopDelay` / `totalStopCount` — already exercised by 19-01; untouched here.

**Carried-forward gap for 19-03 (by design, not a defect):** nothing stops video yet. `executeStopAndTranscribe`, `executeNotifyError`, and the shutdown `stop()` are all unmodified by this plan.

**Carried-forward concern (unchanged):** coordinator tests inject a real `AudioRecorder` and therefore depend on dev-Mac audio hardware. This plan does not worsen it — the video seam is mock-only by construction.

## Self-Check: PASSED

Both files verified present on disk. All 4 task commits verified in `git log`.

---
*Phase: 19-recording-lifecycle-integration*
*Completed: 2026-07-31*
