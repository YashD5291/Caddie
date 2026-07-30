---
phase: 19-recording-lifecycle-integration
plan: 03
subsystem: recording
tags: [screencapturekit, swift6, region-isolation, task-group, timeout, tdd, vid-03, vid-04]

# Dependency graph
requires:
  - phase: 19-01
    provides: ScreenRecording seam, ScreenRecorderFactory, MockScreenRecorder/Factory (stopDelay, totalStopCount)
  - phase: 19-02
    provides: videoContext (meetingId/outputURL/recorder/anchor/streamDied), videoStartTask, surfaceVideoError, DEBUG accessors
provides:
  - RecordingCoordinator.stopVideo() — start-task join + bounded engine stop, called on all four teardown paths
  - RecordingCoordinator.stop() is now async (app-quit finalize; call site unchanged)
  - CaptureEngineBox — Sendable single-owner holder that lets the actor call the engine's nonisolated stop()
  - CompletionLatch — cancellation-aware wait primitive for a fire-and-forget task
  - Bounded stop (videoStopTimeout = 5 s) with an honest non-fatal message on timeout
affects: [19-04 AppState factory injection + menu-bar video-error surface, 20 anchor persistence and video deletion]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Sendable single-owner box so an actor can call a non-Sendable dependency's nonisolated async method without a region-isolation send"
    - "Bounded external call: race a fire-and-forget task against a timeout, never cancelling the task itself"
    - "Cancellation-aware latch poll instead of Task.value inside a task group (a group awaits ALL children)"

key-files:
  created:
    - Tests/RecordingCoordinatorScreenCaptureTeardownTests.swift
  modified:
    - Sources/Coordinator/RecordingCoordinator.swift

key-decisions:
  - "The engine is stored boxed in a Sendable holder (CaptureEngineBox) that owns the stop call — storing it bare makes it 'self'-isolated, and region isolation then rejects awaiting its nonisolated stop(); nonisolated(unsafe) on a local does NOT clear self-isolation"
  - "The research's compile-verified task-group race is behaviorally wrong on the timeout path: withTaskGroup awaits ALL children and Task<Void, Never>.value ignores cancellation, so the group still waits out the wedged stop (measured 10.5 s against a 1 s bound in an isolated repro)"
  - "The stop task is never cancelled on timeout — we stop waiting, we do not abort the engine's finalize"
  - "Teardown is gated on nothing: not the engine's still-capturing flag, not streamDied. The engine's own state guard is authoritative and a dead stream still owns a partial file to finalize"
  - "The box's method is named stopEngine() so the plan's `func stop() async` grep gate keeps measuring the shutdown helper alone"

patterns-established:
  - "Pattern: join-then-teardown — an unstructured start task is awaited before the matching stop, closing the stop-races-start window"
  - "Pattern: bounded subordinate teardown — a subsystem that cannot be allowed to stall the senior path gets a timeout plus a surfaced message, never a cancellation"

requirements-completed: [VID-03, VID-04]

# Metrics
duration: 16 min
completed: 2026-07-31
---

# Phase 19 Plan 03: Video Teardown on Every Path Summary

**Every way a meeting can end — manual stop, meeting end, device disconnect, error teardown, app quit — now finalizes its video exactly once, joins any in-flight start so no capture is orphaned, records video again for meeting #2 in the same session, and gives up after 5 seconds if ScreenCaptureKit wedges rather than stranding the meeting in "Processing…".**

## Performance

- **Duration:** 16 min
- **Started:** 2026-07-30T19:58Z
- **Completed:** 2026-07-30T20:14Z
- **Tasks:** 2 (both TDD, RED → GREEN, no REFACTOR needed)
- **Files modified:** 2 (1 created, 1 modified)

## Accomplishments

- **All four teardown paths close the file.** `stopVideo()` is called from `executeStopAndTranscribe` (line 561, well above `pipeline.enqueue` at 582), `executeNotifyError`, and the app-quit `stop()` — and because `.meetingEnded`, `.manualStop`, and `.deviceDisconnected` all reduce to the same `.stopAndTranscribe` effect, one call site covers three of the four. Each path is covered by its own test rather than assumed from the reducer.
- **The start/stop race is genuinely closed.** `testStopBeforeStartCompletesStillStopsVideo` issues `.manualStop` with no sleep after `.manualStart`, so the stop lands while the ~215 ms video-start task is still in flight. Before the join it stopped nothing (`stopCallCount == 0`, capture still active — the RED run proved it); now the engine is vended, started, and stopped exactly once with no orphan.
- **Meeting #2 records video again.** The regression the per-meeting factory exists to prevent is now locked down: two distinct engines, `totalStartCount == 2`, `totalStopCount == 2`, `first !== second`.
- **A wedged stop costs 5 seconds, not the meeting.** With a 30-second stop delay the meeting reaches `.transcribing` immediately and `handle(.manualStop)` returns in ~5 s instead of 30.04 s (measured, RED vs GREEN), with an honest message surfaced on the non-fatal video channel. Transcription is never blocked by video.
- **Found and fixed a real bug in the planned concurrency shape.** The research verified the task-group race *compiles*; it does not *work*. A standalone repro under `-swift-version 6 -strict-concurrency=complete` measured 10.5 s for a 1-second bound, because `withTaskGroup` awaits all children and `Task<Void, Never>.value` is not cancellation-aware. The shipped version polls a lock-guarded latch in the waiting child instead (repro: 1.01 s bounded, 0.056 s happy path, stop task still running afterwards).
- **Full suite green: 336 tests, 0 failures** (19-02 baseline 326 — 10 net new tests, no regressions). `AppState.swift`, `RecordingState.swift`, and `ScreenRecorder.swift` have zero diff: the `stop()` → `stop() async` change was source-compatible exactly as predicted.

## Task Commits

Each task was committed atomically:

1. **Task 1: stopVideo() joined to the start task, wired into every teardown path** — `3b78867` (test, RED: 8 tests / 14 failures) → `61783e0` (feat, GREEN)
2. **Task 2: Bounded video stop** — `d0f6757` (test, RED: measured 30.04 s > 15 s bound) → `bdd930f` (feat, GREEN)

Both RED runs were genuine measured failures, not compile errors.

## Files Created/Modified

- `Sources/Coordinator/RecordingCoordinator.swift` (modified) — `CaptureEngineBox` + `CompletionLatch` private helpers; `VideoContext.recorder` retyped to the box; `stopVideo()`; `videoStopTimeout` + `stopEngineBounded(_:)`; `await stopVideo()` in `executeStopAndTranscribe`, `executeNotifyError`, and `stop()`; `stop()` became `async`.
- `Tests/RecordingCoordinatorScreenCaptureTeardownTests.swift` (new) — 10 tests: four teardown paths, app-quit shutdown, meeting-#2 regression, start/stop race, stream-death finalize, bounded stop, and clean-stop silence, plus a lock-guarded `TeardownErrorCollector`.

## Decisions Made

- **`CaptureEngineBox` instead of a bare stored engine.** 19-02 had already discovered that storing the engine before `start()` breaks region isolation; this plan hit the mirror image on the way out. Reading the engine back out of `videoContext` makes it `self`-isolated, and `await engine.stop()` is then rejected: *"sending 'self'-isolated value of non-Sendable type 'any ScreenRecording' to nonisolated instance method 'stop()'"*. `nonisolated(unsafe)` on the local does not help — it does not clear self-isolation. A `Sendable` box that owns the call does, and it keeps `ScreenRecording` itself non-Sendable, which is correct: the engine really is single-owner. The `@unchecked` claim is narrow and documented at the type.
- **Polling latch over `await stopTask.value` inside the group.** Documented in full at the call site because the naive version looks obviously right and is silently useless. Verified both ways with a standalone binary before shipping.
- **Never cancel the stop task.** On timeout the coordinator stops waiting; the engine's `finishWriting` continues in the background. Cancelling would trade a bounded wait for a genuinely truncated file.
- **`stopVideo()` clears `videoContext` before stopping**, so the reentrancy window during the bounded wait (the actor is suspended and fully reentrant for up to 5 s) cannot produce a second stop for the same meeting or expose a stale in-flight context to `isVideoActive`.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] `await ctx.recorder?.stop()` does not compile from actor state**
- **Found during:** Task 1 (first GREEN build)
- **Issue:** `Sources/Coordinator/RecordingCoordinator.swift:531: error: sending value of non-Sendable type 'any ScreenRecording' risks causing data races` — *"sending 'self'-isolated value … to nonisolated instance method 'stop()'"*. The plan's `stopVideo()` reads the engine out of `videoContext` and awaits it directly, which region isolation rejects. An intermediate attempt using `nonisolated(unsafe) let engine = ctx.recorder` failed identically (the diagnostic is about the value being self-isolated, not about the local's own isolation).
- **Fix:** `private final class CaptureEngineBox: @unchecked Sendable` holding the engine and exposing `stopEngine() async`. `VideoContext.recorder` is now `CaptureEngineBox?`, assigned as `CaptureEngineBox(recorder)` immediately after `start()` returns (the same instant 19-02 attached the bare engine). The engine is still stopped exactly once, by exactly one owner.
- **Files modified:** `Sources/Coordinator/RecordingCoordinator.swift`
- **Commit:** `61783e0`

**2. [Rule 1 - Bug] The planned task-group race never times out**
- **Found during:** Task 2 (before writing the implementation, from the RED test's 30 s runtime)
- **Issue:** The plan (following the research) specified `group.addTask { await stopTask.value; return false }` racing a sleep child, then `group.next()` + `group.cancelAll()`. That compiles — which is all the research verified — but does not bound anything: `withTaskGroup` waits for **all** children before returning, and `Task<Void, Never>.value` ignores cancellation, so the group sits on the wedged stop anyway. A standalone `-swift-version 6 -strict-concurrency=complete` repro measured **10.5 s for a 1-second bound**; in the real test that would have been the full 30 s, i.e. the exact "stuck in Processing…" failure the timeout exists to prevent.
- **Fix:** the stop runs in a fire-and-forget `Task` that signals a lock-guarded `CompletionLatch`; the waiting child polls `latch.isDone` with cancellation-aware `Task.sleep(for: .milliseconds(25))`, so `group.cancelAll()` actually releases it. Repro after the fix: 1.01 s bounded, 0.056 s on the happy path, stop task confirmed still running. The plan's required shape (`withTaskGroup(of: Bool.self)`, `group.cancelAll()`, no cancellation of the stop task) is preserved; only the waiting child changed. The reasoning is comment-documented so nobody "simplifies" it back.
- **Files modified:** `Sources/Coordinator/RecordingCoordinator.swift`
- **Commit:** `bdd930f`

**3. [Rule 3 - Blocking] Grep gates were matching prose and the helper method**
- **Found during:** Task 1 acceptance checks
- **Issue:** `grep -c 'isRecording'` returned 2 (both hits were doc comments explaining that the engine's flag lies, not code — the gate exists to prove teardown is not gated on it), and `grep -c 'func stop() async'` returned 2 once `CaptureEngineBox` existed.
- **Fix:** reworded two doc comments to say "still-capturing flag", and named the box's method `stopEngine()`. No behavior change; the gates now measure exactly what they were written to measure. (Same class of issue as 19-02 deviation 3.)
- **Files modified:** `Sources/Coordinator/RecordingCoordinator.swift`
- **Commit:** `61783e0`

**4. [Rule 1 - Bug, test-only] Two assertions raced the mock pipeline**
- **Found during:** Task 1 GREEN
- **Issue:** `testManualStopStopsVideo` and `testStopAfterStreamDeathStillFinalizes` asserted `.transcribing` *after* a 150 ms settle. With mock ASR/diarization the whole pipeline finishes in under a millisecond, so the coordinator was already back at `.idle` — the tests failed on a correct implementation.
- **Fix:** read the state immediately after `handle(...)` returns (it is set synchronously by the reducer before the side effect), then settle before asserting stop counts. Commented so the ordering is not "cleaned up" later.
- **Files modified:** `Tests/RecordingCoordinatorScreenCaptureTeardownTests.swift`
- **Commit:** `61783e0`

**Total deviations:** 4 (2 blocking, 1 real concurrency bug in the planned shape, 1 test-only)
**Impact on plan:** None to scope or contracts. Every symbol and grep gate the plan specified exists; `VideoContext.recorder`'s type changed from the (private) bare existential to a private box, and the bounded stop's waiting child is implemented correctly rather than as written.

## Issues Encountered

Two compile/behaviour failures, each resolved in one iteration; no fix-cycle limits approached. The behavioural one (deviation 2) was caught only because the RED test measured wall-clock time rather than asserting that a timeout "happened" — worth keeping in mind for future timeout work.

## Known Stubs

None. Every symbol added is fully implemented and exercised.

One intentional non-wiring carried forward from 19-02: `setOnVideoError` still has no production caller (19-04 wires it into `AppState`/`MenuBarView`), so the timeout message added here reaches an unset channel until then. `AppState` also still passes no factory, so every video path remains inert in production.

## Threat Flags

None. No network endpoint, auth path, or schema change. The plan's threat-register mitigations landed as specified:

- **T-19-08 (DoS):** bounded stop shipped and measured — a 30 s wedge costs 5 s and the meeting still enqueues (`testSlowVideoStopDoesNotBlockPipeline`).
- **T-19-09 (Tampering / data integrity):** `stopVideo()` runs unconditionally on all four teardown paths and joins the start task first (`testStopBeforeStartCompletesStillStopsVideo`, `testStopAfterStreamDeathStillFinalizes`).
- **T-19-10 (Repudiation, accepted):** documented honestly in the `stop()` doc comment — `NSApp.terminate` does not await AppState's shutdown `Task`, so finalize may not complete on quit; the fragmented `.mov` stays playable minus at most ~10 s. Quit is not blocked on `finishWriting`.
- **T-19-11 (accepted):** video deletion remains Phase 20's; unchanged here.
- **T-19-SC:** zero package installs; `project.yml` unchanged.

## Verification

| Check | Result |
|-------|--------|
| `make test` full suite | `** TEST SUCCEEDED **` — 336 tests, 0 failures (baseline 326, +10, no regressions) |
| `-only-testing:CaddieTests/RecordingCoordinatorScreenCaptureTeardownTests` | `** TEST SUCCEEDED **` — 10/10 in 10.2 s |
| `grep -c 'private func stopVideo() async'` | 1 |
| `grep -c 'await videoStartTask?.value'` | 1 |
| `grep -c 'await stopVideo()'` | 3 |
| `grep -c 'func stop() async'` | 1 |
| `grep -c 'isRecording'` (coordinator) | 0 |
| `await stopVideo()` (561) before `pipeline.enqueue` (582) in `executeStopAndTranscribe` | PASS |
| `grep -c 'videoStopTimeout'` / `'withTaskGroup(of: Bool.self)'` / `'group.cancelAll()'` / `'did not finish cleanly'` | 4 / 1 / 1 / 1 |
| `git diff --name-only -- Sources/App/AppState.swift Sources/Coordinator/RecordingState.swift Sources/Recording/ScreenRecorder.swift` | empty |
| `grep -rn "await coordinator?.stop()" Sources/App/AppState.swift` | single pre-existing call site at `:369` |

## Success Criteria

- Video finalized on normal stop, meeting end, device disconnect, error teardown, and app quit — **proven** by `testManualStopStopsVideo`, `testMeetingEndedStopsVideo`, `testDeviceDisconnectStopsVideo`, `testErrorPathStopsVideo`, `testShutdownStopFinalizesVideo`
- A second meeting in the same session records video — **proven** by `testSecondMeetingStartsVideoAgain`
- A stop racing an in-flight start still finalizes the capture — **proven** by `testStopBeforeStartCompletesStillStopsVideo`
- A wedged stop is bounded, surfaced, and non-blocking for transcription — **proven** by `testSlowVideoStopDoesNotBlockPipeline`, with `testNormalStopSurfacesNoVideoError` proving the bound is invisible on the happy path

## User Setup Required

None. The feature stays unreachable in production until 19-04 injects a factory. README documentation is deferred to the plan that makes video user-observable.

## Next Phase Readiness

Ready for **19-04**. What it consumes is in place:

- `RecordingCoordinator.stop()` is `async`; `AppState.shutdown()` needs no edit.
- `setOnVideoError(_:)` is the single channel for every video failure, including the new stop-timeout message ("Screen recording did not finish cleanly — the video may be incomplete. Audio was saved.").
- `screenRecorderFactory` is still nil in production — 19-04 owns the settings gate and the `ScreenRecorder()` factory injection, which is the point at which any of this becomes reachable.

**Carried-forward limitation (Phase 20's):** `AudioFileManager.deleteAudio(meetingId:)` still ignores `.mov`, so deleting a meeting between now and Phase 20 orphans its video file.

**Carried-forward concern (unchanged):** coordinator tests inject a real `AudioRecorder` and therefore depend on dev-Mac audio hardware. The video seam remains mock-only by construction.

## Self-Check: PASSED

Both files verified present on disk. All 4 task commits verified in `git log`.

---
*Phase: 19-recording-lifecycle-integration*
*Completed: 2026-07-31*
