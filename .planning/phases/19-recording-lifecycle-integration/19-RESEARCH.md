# Phase 19: Recording Lifecycle Integration - Research

**Researched:** 2026-07-31
**Domain:** Swift 6 actor wiring of an existing capture engine into an existing recording state machine (no new dependencies)
**Confidence:** HIGH (every load-bearing claim verified against the actual source and/or compiled with the project's exact toolchain and flags)

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Injection pattern (locked — mirrors LiveTranscriber)**
- `ScreenRecorder` is an optional constructor dependency of `RecordingCoordinator`, exactly like `liveTranscriber: LiveTranscriber?`. Constructed in `AppState.initialize()` only when screen recording is enabled.
- Enablement gate: a shared settings enum (MeetingPromptSettings pattern — static key + default) with **default OFF**; Phase 21 builds the visible toggle over the same key. VID-01's "off by default" semantic starts here.

**Lifecycle (locked by roadmap success criteria)**
- Video starts ONLY AFTER `recorder.start(...)` (audio) succeeds — audio is always the senior partner.
- Video stops/finalizes in BOTH stop paths: `executeStopAndTranscribe` (normal) and `executeNotifyError` (error teardown), plus the device-disconnect path if it tears down separately. No video file may be left open or corrupted when a meeting ends (Phase 18's finalize paths are proven — wiring must call them).
- Graceful degradation (VID-04, core-value safety net): ANY video failure — start throw, mid-recording `onStreamStopped`, stop failure — is logged with context and surfaced (existing error-surfacing path), and the audio recording continues/completes normally. Never abort or fail the meeting because of video.

**File placement (locked)**
- Video writes to the canonical storage layout NOW: `<meetingId>.mov` beside the audio files (AudioFileManager conventions — add `videoPath(for:)`). Phase 20 adds the DB column, deletion, and disk guard. Transient limitation (acceptable, documented): between Phases 19 and 20, deleting a meeting won't remove its video file.

**Timing anchor plumbing (locked)**
- Coordinator captures the audio-start host time and subscribes to `onFirstFrameHostTime`, holding both values with the in-flight recording (in-memory) and logging them. Persistence to the meetings row is Phase 20 (STOR-04 storage leg). Note from 18-04: first frame lands ~200 ms after the start call (setup latency) — alignment uses the anchor, which is exact.

**Phase 18 facts the plan must respect**
- `ScreenRecorder` is a non-Sendable `final class` designed to be owned by one isolation domain (the coordinator actor) — same ownership model as `AudioRecorder`.
- `start(target:preset:outputURL:)` is async throws; `stop()` finalizes async without blocking; `onStreamStopped` fires on SCK-initiated stops (window closed, error -3821) leaving a playable partial.
- `CaptureTarget` is NOT Sendable (SCWindow) — mind actor boundaries when passing it.
- Phase 19 uses `.display(nil)` + `.balanced` as the interim target/preset (user-facing choice is Phase 21); read from the settings enum if trivially available.

**Conventions (project)**
- TDD mandatory. Protocol seam + mock for the recorder in coordinator tests (project precedent: engine protocols enabling mock injection into TranscriptionPipeline; MockStreamingEngine with NSLock). Swift 6 strict concurrency. No silent failures. XcodeGen regen for new files. `make test` gates.

### Claude's Discretion
- Exact protocol shape for the test seam (e.g. `ScreenRecording` protocol with start/stop/callbacks) vs closure injection.
- Where the settings enum lives (Sources/Recording/ vs Sources/Storage/) and its exact key strings.
- Whether device-disconnect teardown needs distinct handling or flows through executeNotifyError already.
- How the anchor pair is held in-memory (struct on the coordinator vs fields).

### Deferred Ideas (OUT OF SCOPE)
- `video_file` column, deletion with meeting, disk-guard raise, anchor persistence → Phase 20
- Settings toggle UI, capture-target + preset pickers, permission request UX → Phase 21
- Playback/export → Phase 21
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| VID-03 | When enabled, video capture starts and stops automatically with the meeting recording lifecycle (manual and calendar-prompted recordings alike) | Integration Surface Map (§ every start/stop path with file:line) + Pattern 1 (start wiring) + Pattern 2 (teardown wiring). Manual and calendar-prompted starts converge on ONE side effect (`.startRecording`), so a single wiring point covers both — verified in `RecordingState.reduce` (`Sources/Coordinator/RecordingState.swift:81-106`). |
| VID-04 | Video capture failure never aborts the audio recording — recording degrades to audio-only with the error logged and surfaced | Pattern 3 (graceful degradation), Pitfalls 1/2/3/5, Error-Surfacing Options (§ Open Question 1), Validation Architecture forced-failure test rows. |

**Also touched (not owned):** STOR-04 in-memory leg — the anchor pair is captured and logged here; persistence is Phase 20.
</phase_requirements>

---

## Summary

Phase 19 is pure wiring: no new dependencies, no new reducer states, no new files in the hot path — the engine (`ScreenRecorder`, Phase 18, hardware-verified) and the integration surface (`RecordingCoordinator`, an actor with 5 side effects) both already exist. The work is (a) an optional dependency + protocol seam on the coordinator, (b) start-after-audio in `executeStartRecording`, (c) stop-on-every-teardown-path, (d) a non-fatal error channel to the UI, (e) a settings key + `AudioFileManager.videoPath(for:)`, and (f) the mock/test infrastructure that makes forced-failure paths honestly unit-testable.

Three findings change the shape of the plan and are all verified against source (not assumed):

1. **`ScreenRecorder` is single-use, and its restart failure is SILENT.** `start()` guards `state == .idle` (`ScreenRecorder.swift:80`); `stop()` moves state to `.stopped` and `transition(.stopped, .started) == .stopped` (verified by executing the pure function: see § Verification Evidence). A second `start()` on the same instance logs a warning and **returns normally — it does not throw**. A single instance constructed once in `AppState.initialize()` (the literal reading of the locked injection decision) would record video for the FIRST meeting of each app launch and silently produce nothing thereafter. This is exactly the class of silent failure CLAUDE.md forbids. Two viable fixes are documented below; the plan MUST pick one and cover it with a test.
2. **There are exactly TWO teardown side effects, not three.** Device-disconnect reduces to `.stopAndTranscribe` (`RecordingState.swift:120-124`) — the same effect as normal stop — so `executeStopAndTranscribe` + `executeNotifyError` cover every reducer-driven teardown. The third, non-reducer path is `RecordingCoordinator.stop()` (`RecordingCoordinator.swift:105-110`), the app-quit/shutdown helper, which today bypasses live-transcriber teardown by design and currently would leave video running.
3. **Swift 6 is a non-issue here — verified by compiling, not by reasoning.** The real `Sources/Recording/ScreenRecorder.swift` was type-checked together with a faithful model of the Phase 19 wiring under `-swift-version 6 -strict-concurrency=complete` on Xcode 26.2's toolchain (the project's exact settings). An actor storing a non-Sendable `ScreenRecording?` existential, calling `await rec.start(target: .display(nil), …)` and `await rec.stop()`, setting `@Sendable` callbacks that hop back via `Task { await self.… }`, a `Task {}`-wrapped stop, a task-group timeout race, an `@unchecked Sendable` NSLock mock, and a `@Sendable () -> ScreenRecording` factory injection **all compile with zero errors**. The `CaptureTarget` non-Sendable concern does not bite: `.display(nil)` constructed at the call site is a disconnected region.

**Primary recommendation:** Inject a `ScreenRecording?` protocol existential into `RecordingCoordinator` (extension-conform `ScreenRecorder` to it, mock it in tests). Set both callbacks then `await start(...)` immediately after `try recorder.start(...)` succeeds in `executeStartRecording`; call `await screenRecorder?.stop()` unconditionally (it is idempotent by construction) at the top of `executeStopAndTranscribe`, `executeNotifyError`, and the shutdown `stop()`. Wrap every video call in a catch that logs + surfaces and never rethrows into the audio path. Solve the single-use problem with a per-meeting instance (factory injection) or a 2-line restart transition in the engine — do not ship without a test for meeting #2.

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Deciding *when* video starts/stops | `RecordingCoordinator` (actor) | — | It already owns the meeting lifecycle and every teardown path; video is subordinate to audio (ARCHITECTURE Anti-Pattern 2: no new reducer states) |
| Capturing/encoding/finalizing video | `ScreenRecorder` (non-Sendable class + writerQueue) | `WriterSink` | Phase 18 engine; SCK callbacks arrive on framework queues and are confined to `writerQueue` |
| Deciding *whether* video exists at all | `AppState.initialize()` (MainActor) | `ScreenRecordingSettings` (UserDefaults) | Mirrors `liveTranscriber` construction (`AppState.swift:132-141`); UserDefaults reads are MainActor-friendly there |
| Video file path/layout | `AudioFileManager` (static enum) | — | `wavPath`/`alacPath` conventions live there (`AudioFileManager.swift:29-36`) |
| Surfacing non-fatal video errors to the user | `AppState` (@Observable, MainActor) | `MenuBarView` | Existing pattern: coordinator callback → `Task { @MainActor }` → observable → SwiftUI (`AppState.swift:153-188`) |
| Persisting video path + anchor | **Phase 20** (Storage) | — | Explicitly deferred; Phase 19 holds the anchor in memory and logs it |

---

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| ScreenCaptureKit | macOS 14.2 SDK (system) | Already used by `ScreenRecorder` | Phase 18; no change in 19 |
| AVFoundation / VideoToolbox | system | HEVC writer | Phase 18; no change in 19 |
| Foundation (`mach_absolute_time`, `mach_timebase_info`) | system | Audio-start host tick for the anchor pair | Same clock family SCK PTS uses (`CMClockGetHostTimeClock`); conversion helper already exists: `ScreenRecorder.hostTicksToSeconds(_:timebase:)` (`ScreenRecorder.swift:316-318`) |
| XCTest (via `xcodebuild`) | Xcode 26.2 | Unit tests | Project standard, `make test` |

**Installation:** none — **zero new SPM packages**. `project.yml` `packages:` block is untouched. XcodeGen regen (`xcodegen generate`, i.e. `make setup`, which `make build`/`make test` already invoke) is still required for any NEW source/test files.

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Protocol seam (`ScreenRecording`) | Closure injection (`start:`/`stop:` closures on the coordinator) | Closures are lighter but lose the callback-assignment surface (`onStreamStopped` must be settable by the coordinator) and don't match the project's engine-protocol precedent (`StreamingTranscriptionEngine`, `ASREngineProtocol`) |
| Concrete `ScreenRecorder?` dependency | Protocol existential | Concrete type compiles fine (verified) but makes forced-failure unit tests impossible without real TCC + a real display — unacceptable for VID-04's three failure modes |

## Package Legitimacy Audit

**Not applicable — this phase installs zero external packages.** All frameworks are Apple system frameworks already linked by the target; no npm/PyPI/crates/SPM additions. No slopcheck run needed. `project.yml:packages` remains: GRDB, SimplyCoreAudio, AXSwift, Sparkle, FluidAudio (unchanged).

---

## Integration Surface Map (verified, file:line)

Every code path that starts or tears down a recording, with isolation context and where video belongs.

| # | Path | Location | Isolation | Video action |
|---|------|----------|-----------|--------------|
| 1 | `execute(_:)` dispatcher — 5 side effects | `RecordingCoordinator.swift:193-210` | actor | none (dispatch only) |
| 2 | **START** `executeStartRecording` | `:212-290` | actor | After `try recorder.start(...)` at **`:259`** succeeds and after the LiveTranscriber block (`:271-282`), before `NotificationManager.recordingStarted` (`:284`) |
| 3 | **STOP (normal + manualStop + deviceDisconnected)** `executeStopAndTranscribe` | `:292-327` | actor | Stop/finalize video alongside `recorder.stop()` (`:295`) and `liveTranscriber?.stop()` (`:296`), BEFORE `pipeline.enqueue` (`:317`) |
| 4 | **ERROR teardown** `executeNotifyError` | `:386-404` | actor | Stop/finalize video alongside `recorder.onSamples = nil` (`:387`) / `liveTranscriber?.stop()` (`:388`) |
| 5 | **SHUTDOWN / app quit** `stop()` | `:105-110` | actor, **sync** | Currently only `recorder.stop()`. Must also finalize video, else quit-during-recording leaves the writer open (mitigated but not cured by fragmented `.mov`). Requires making it `async` (source-compatible: sole caller is `AppState.shutdown()` at `AppState.swift:368-371`, already inside a `Task`) |
| 6 | `executeRetryTranscription` | `:331-364` | actor | **none** — retry re-runs transcription on an existing WAV; no recording lifecycle |
| 7 | `executeNotifyComplete` | `:366-381` | actor | none |
| 8 | `switchInputDevice` | `:159-171` | actor | none — audio-source-only change; video is unaffected by mid-recording device switches |
| 9 | `AudioRecorder.onDeviceDisconnected` callback | set at `:260-262`; fires `.deviceDisconnected` | @Sendable → `Task` → actor | Reduces to `.stopAndTranscribe` (see below) → covered by #3 |

**Device-disconnect is NOT a distinct teardown path** — `RecordingState.reduce` maps `(.recording, .deviceDisconnected)` to `(.transcribing, .stopAndTranscribe(...))` (`RecordingState.swift:120-124`), the exact same side effect as `.meetingEnded` and `.manualStop` (`:108-118`). This resolves Claude's-Discretion item 3: **no distinct handling needed** — but the plan should still assert it with a test (the LiveTranscriber suite already does exactly this: `RecordingCoordinatorLiveTranscriptionTests.swift:84-95`).

**Manual vs calendar-prompted starts converge.** `manualStart` (`RecordingState.swift:88-94`), `manualStart` from `.error` recovery (`:100-106`), and `meetingDetected` (`:81-87`, the calendar-prompt path via `NotificationManager.recordAction` → `AppState.startManualRecording`) ALL emit the single `.startRecording` side effect. One wiring point in `executeStartRecording` satisfies VID-03 for both trigger types — no per-trigger branching.

### Where in-flight recording context lives today

The coordinator holds **no per-recording struct** — the only in-flight state is `state: RecordingState` (`:12`), which carries just `meetingId`. Dependencies are `let`s (`:16-25`); callbacks are `var`s (`:29-30`). So the anchor pair and video health flags need NEW private `var`s (or one small private struct) on the coordinator. Recommended (Claude's Discretion item 4):

```swift
/// In-flight video context for the current meeting. nil when no video is active.
private struct VideoContext {
    let meetingId: String
    let outputURL: URL
    let audioStartTicks: UInt64          // mach_absolute_time() at audio start
    var firstFrameTicks: UInt64?         // from onFirstFrameHostTime (STOR-04); Phase 20 persists
    var failure: String?                 // set on start throw / stream death / stop failure
}
private var videoContext: VideoContext?
```
One optional field is easier to reason about than four parallel `var`s, and it nils out atomically on teardown.

### Error-surfacing machinery as it exists today

| Mechanism | Where | Semantics |
|-----------|-------|-----------|
| `AppState.lastRecordingError: String?` | `AppState.swift:60`; set at `:177` **only** from `.error` state; cleared at `:169` on entering `.recording`; also user-dismissible | Rendered by `MenuBarView.swift:26-31` as "⚠️ Last recording failed: …" **only in the `.idle` branch** |
| `NotificationManager.transcriptionError(title:error:)` | `NotificationManager.swift` (used at `RecordingCoordinator.swift:403`) | System banner — currently only fired from the fatal error path |
| `logger.error(...)` | throughout | os_log, info-level is memory-only (see 18-04 environment notes) |
| Coordinator → AppState callback precedent | `setOnStateChange` / `setOnPipelineStepChange` (`RecordingCoordinator.swift:55-61`), wired in `AppState.swift:153-188` | The exact shape to copy for a new `setOnVideoError` |

**Critical constraint:** a video failure must NOT drive the coordinator into `.error` (that would abort the meeting — the precise thing VID-04 forbids). Therefore the existing `lastRecordingError` write path (`.error` state → AppState) is unreachable for video failures. A new channel is required. See Open Question 1 for the two options.

---

## Architecture Patterns

### System Architecture Diagram

```
 USER / CALENDAR TRIGGER
   │  manual click (MenuBarView) ── AppState.startManualRecording ─┐
   │  calendar prompt (UNNotification "Record" action) ────────────┤
   └──────────────────────────────────────────────────────────────►│
                                                                   ▼
                                              RecordingCoordinator.handle(event)
                                                                   │
                                            RecordingState.reduce (pure, sync)
                                                                   │
                              ┌────────────────────────────────────┴──────────────────────────┐
                              ▼                                                               ▼
                   .startRecording(id, meeting)                                  .stopAndTranscribe(id)
                              │                                                (meetingEnded │ manualStop │ deviceDisconnected)
                              ▼                                                               │
                  executeStartRecording (actor)                                               ▼
                     │                                                        executeStopAndTranscribe (actor)
                     ├─ checkDiskSpace ──throw──► .recordingFailed ──►│          ├─ recorder.onSamples = nil
                     ├─ DB INSERT meeting ─fail─► .recordingFailed ──►│          ├─ recorder.stop()        [audio finalize]
                     ├─ recorder.start(wav) ─throw─► .recordingFailed►│          ├─ liveTranscriber.stop()
                     │        │ success                               │          ├─ ★ videoStop()          [idempotent]
                     │        ├─ audioStartTicks = mach_absolute_time()│          ├─ DB UPDATE end_time
                     │        ├─ liveTranscriber.start() + onSamples tee          └─ pipeline.enqueue ──► transcription
                     │        └─ ★ videoStart()                       │
                     │              ├─ set onFirstFrameHostTime ──────┼──► anchor pair (in-memory, logged) → Phase 20 DB
                     │              ├─ set onStreamStopped ───────────┼──► ★ mid-meeting death → surface + mark inactive
                     │              └─ ScreenRecorder.start(.display(nil), .balanced, <id>.mov)
                     │                     │ throws → ★ log + surface + CONTINUE (audio-only)
                     └─ NotificationManager.recordingStarted           ▼
                                                                executeNotifyError (actor)
                                                                   ├─ recorder.onSamples = nil
                                                                   ├─ liveTranscriber.stop()
                                                                   ├─ ★ videoStop()          [idempotent]
                                                                   ├─ DB UPDATE status=error
                                                                   └─ NotificationManager.transcriptionError

 APP QUIT: AppState.shutdown() ─Task─► coordinator.stop() ─► recorder.stop() + ★ videoStop()

 ★ = new in Phase 19.  Every ★ failure path is log + surface + continue; none feed .recordingFailed.
```

### Recommended file layout (all new files need `xcodegen generate`)

```
Sources/
├── Recording/
│   ├── ScreenRecorder.swift            # existing (Phase 18) — +ScreenRecording conformance
│   ├── ScreenRecording.swift           # NEW: protocol seam (+ extension ScreenRecorder: ScreenRecording {})
│   └── ScreenRecordingSettings.swift   # NEW: enum with static key + default (MeetingPromptSettings pattern)
├── Coordinator/
│   └── RecordingCoordinator.swift      # MODIFIED: dep, videoStart/videoStop, setOnVideoError, async stop()
├── Storage/
│   └── AudioFileManager.swift          # MODIFIED: +videoPath(for:)
└── App/
    └── AppState.swift                  # MODIFIED: construct when enabled, wire onVideoError
Tests/
├── Mocks/MockScreenRecorder.swift              # NEW
├── RecordingCoordinatorScreenCaptureTests.swift # NEW
└── ScreenRecordingSettingsTests.swift          # NEW (key/default pinning, videoPath)
```

### Pattern 1: Optional protocol dependency + engine conformance (the test seam)

```swift
// Source: verified compile-clean against Sources/Recording/ScreenRecorder.swift
//         with -swift-version 6 -strict-concurrency=complete (Xcode 26.2)

/// Test seam for the Phase 18 capture engine. Deliberately NOT Sendable — like
/// ScreenRecorder itself, a conformer is owned by exactly one isolation domain
/// (the RecordingCoordinator actor).
protocol ScreenRecording: AnyObject {
    var onFirstFrameHostTime: (@Sendable (UInt64) -> Void)? { get set }
    var onStreamStopped: (@Sendable (Error?) -> Void)? { get set }
    var isRecording: Bool { get }
    func start(target: ScreenRecorder.CaptureTarget,
               preset: ScreenRecorder.QualityPreset,
               outputURL: URL) async throws
    func stop() async
}

extension ScreenRecorder: ScreenRecording {}   // zero engine changes required
```

Coordinator init grows one optional parameter with a default, so **all existing call sites and tests keep compiling unchanged** (`RecordingCoordinatorTests.swift:28-35` constructs with only 4 args):

```swift
init(
    database: AppDatabase,
    recorder: AudioRecorder,
    pipeline: TranscriptionPipeline,
    detector: MeetingDetector,
    audioDeviceManager: AudioDeviceManager? = nil,
    liveTranscriber: LiveTranscriber? = nil,
    screenRecorder: ScreenRecording? = nil        // ← new, mirrors liveTranscriber
)
```

### Pattern 2: Start after audio, never before (VID-03) — and never blocking it

```swift
// inside executeStartRecording, immediately AFTER `try recorder.start(...)` succeeds
let audioStartTicks = mach_absolute_time()          // anchor half #1 (STOR-04, in-memory)
...
await startVideoIfEnabled(meetingId: meetingId, audioStartTicks: audioStartTicks)

private func startVideoIfEnabled(meetingId: String, audioStartTicks: UInt64) async {
    guard let screenRecorder else { return }
    let url = AudioFileManager.videoPath(for: meetingId)

    // Callbacks MUST be assigned BEFORE start() — WriterSink captures them by value
    // at construction time (ScreenRecorder.swift:145-152). Assigning after start is a
    // silent no-op.
    screenRecorder.onFirstFrameHostTime = { [weak self] ticks in
        Task { await self?.recordFirstFrameAnchor(ticks) }        // @Sendable, writerQueue
    }
    screenRecorder.onStreamStopped = { [weak self] error in
        Task { await self?.handleVideoStreamStopped(error) }      // @Sendable, SCK queue
    }

    do {
        try await screenRecorder.start(target: .display(nil), preset: .balanced, outputURL: url)
        videoContext = VideoContext(meetingId: meetingId, outputURL: url,
                                    audioStartTicks: audioStartTicks)
        logger.info("Screen capture started for \(meetingId) -> \(url.lastPathComponent)")
    } catch {
        // VID-04: log + surface + CONTINUE. Never `handle(.recordingFailed(...))`.
        logger.error("Screen capture failed to start for \(meetingId): \(error.localizedDescription)")
        surfaceVideoError("Screen recording unavailable — audio is still recording: \(error.localizedDescription)")
        videoContext = nil
    }
}
```

`.display(nil)` and `.balanced` are constructed at the call site → disconnected region → the non-Sendable `CaptureTarget` never poses an isolation problem (verified compile-clean).

### Pattern 3: Idempotent teardown on every path (VID-03 criterion 2, criterion 4)

```swift
/// Stop + finalize video. Safe to call unconditionally on every teardown path:
/// ScreenRecorder.stop() no-ops unless state == .recording (ScreenRecorder.swift:200-203)
/// and WriterSink.finalize is separately idempotent (18-02: "stop-after-error and
/// double-stop are safe no-ops").
private func stopVideo() async {
    guard let screenRecorder else { return }
    videoContext = nil
    await screenRecorder.stop()
}
```
Call it as the FIRST awaited teardown step in `executeStopAndTranscribe` and `executeNotifyError`, and in the shutdown `stop()`. Unconditional beats flag-gated: the flag can lie (see Pitfall 4) but the engine's guard cannot.

### Pattern 4: Settings enum (MeetingPromptSettings shape, verbatim precedent)

```swift
// Precedent: Sources/Calendar/GoogleCalendarService.swift:6-12
/// Shared persistence contract for the screen-recording feature gate, so the
/// Phase 21 Settings toggle (writer) and AppState (reader) can never drift.
enum ScreenRecordingSettings {
    /// UserDefaults key for whether meetings are also captured as video.
    static let enabledKey = "screenRecordingEnabled"
    /// VID-01: OFF by default — video is opt-in.
    static let defaultEnabled = false

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }
}
```
Use `object(forKey:) as? Bool ?? default` (not `bool(forKey:)`) so "never set" is distinguishable from "explicitly false" — this is exactly why `MeetingPromptSettings` reads via `object(forKey:)` (`GoogleCalendarService.swift:168`). Placement: `Sources/Recording/ScreenRecordingSettings.swift` (co-located with the engine it gates; the milestone ARCHITECTURE table also anticipates a Recording-scoped settings home).

### Pattern 5: AppState construction (mirrors LiveTranscriber, `AppState.swift:132-141`)

```swift
// 5b. Screen capture: optional, off by default. Constructed only when enabled so the
// coordinator's dependency is nil (and every video code path inert) when the feature is off.
var screenRecorder: ScreenRecording?
if ScreenRecordingSettings.isEnabled {
    screenRecorder = ScreenRecorder()
    logger.info("Screen recording enabled (permission status: \(String(describing: Permissions.screenRecording)))")
}
```
**Do not gate on `Permissions.screenRecording`.** It is an *inference* (`Permissions.swift:34-59` — reads foreign window names via `CGWindowListCopyWindowInfo`), so a false negative would silently disable video with no error. Constructing anyway means a denied TCC surfaces as a real `start()` throw → the VID-04 degrade path with a real, logged, surfaced message. Log the status for diagnostics.

### Anti-Patterns to Avoid
- **New reducer states/events for video** (`.recordingWithVideo`, `.videoFailed`) — milestone ARCHITECTURE Anti-Pattern 2; doubles the tested surface. `RecordingState.swift` should be untouched by this phase.
- **Routing video failure through `handle(.recordingFailed(...))`** — directly violates VID-04; it would kill the audio recording.
- **Gating `stopVideo()` on a coordinator-side "is video running" flag** — the flag is stale after `onStreamStopped` (Pitfall 4); the engine's own guard is authoritative.
- **Raising `minimumDiskSpaceBytes`** (`RecordingCoordinator.swift:175`) — explicitly Phase 20 per CONTEXT Deferred Ideas.
- **Adding video to `deleteAudio(meetingId:)`** (`AudioFileManager.swift:241-251`) — Phase 20 owns deletion; Phase 19 documents the transient orphan.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Stop idempotency / double-stop safety | Coordinator-side "did I already stop video" bookkeeping | `ScreenRecorder.stop()`'s state guard + `WriterSink`'s separate finalize guard | Already proven in 18-02 across stop-after-error and double-stop |
| File finalization on crash/quit | Manual flush/close logic, blocking quit on finalize | `movieFragmentInterval` + async `finishWriting` (already in the engine) | VID-07, hardware-verified in 18-04 (two kill-9 samples playable) |
| Host-tick → seconds conversion | Custom timebase math | `ScreenRecorder.hostTicksToSeconds(_:timebase:)` (`:316-318`) | Already unit-tested in `ScreenRecorderConfigTests` |
| Video path construction | Ad-hoc `URL` building in the coordinator | `AudioFileManager.videoPath(for:)` next to `wavPath`/`alacPath` | Single source of truth for the storage layout; Phase 20 deletion needs it |
| Mock synchronization | `nonisolated(unsafe)` counters or actor mocks | `final class … : @unchecked Sendable` + `NSLock` | Exact `MockStreamingEngine` precedent (`Tests/Mocks/MockStreamingEngine.swift:20-31`), which documents why test-executor serialization is NOT safe |
| Callback → actor hop | `MainActor.assumeIsolated` or locks in the callback | `Task { await self?.method(...) }` inside the `@Sendable` closure | Existing coordinator precedent (`:260-262`); compiles clean, inherits actor isolation |

**Key insight:** every hard part of screen capture was solved and hardware-verified in Phase 18. The only genuinely new engineering in Phase 19 is *ordering and failure containment* — which is why nearly all of this phase's risk lives in the pitfalls below, not in any algorithm.

---

## Common Pitfalls

### Pitfall 1 (BLOCKING): `ScreenRecorder` is single-use — meeting #2 silently records nothing
**What goes wrong:** With one injected instance, meeting #1 records video; every later meeting in that app session produces no video, no error, no user-visible signal.
**Why it happens (verified, not assumed):** `start()` guards `state == .idle` and *returns* (does not throw) otherwise (`ScreenRecorder.swift:80-83`). `stop()` sets `state = transition(state, .stopped)` → `.stopped` (`:204`). Executing the pure function proves `transition(.stopped, .started) == .stopped` and `transition(.failed, .started) == .failed` (§ Verification Evidence). So the guard can never be satisfied again.
**How to avoid — pick ONE:**
- **Option A — fresh engine per meeting (factory injection).** Coordinator dependency becomes `(@Sendable () -> ScreenRecording)?`; `executeStartRecording` calls it, keeps the instance in `videoContext`, drops it on teardown. Verified compile-clean. Zero changes to Phase 18's hardware-verified engine; callbacks are correct-by-construction per instance; the engine's defensive `deinit` finalize (`:222-227`) becomes a second safety net. Slight deviation from the literal "constructed in AppState.initialize()" wording — the *factory* is constructed there, gated identically.
- **Option B — make the engine restartable.** Add `case (.stopped, .started): return .recording` and `case (.failed, .started): return .recording` to `ScreenRecorder.transition` (`:344-351`) and relax `start()`'s guard to `state != .recording`. ~3 lines + pure-function tests, and it keeps the locked injection wording verbatim. Risk: modifies a hardware-verified file and makes one long-lived instance carry state across meetings (stale `sink`/`stream` are already nil'd in `stop()` at `:208-209`, so this is safe in practice).
**Recommendation:** Option B if the locked injection wording is treated strictly (smaller diff, keeps `liveTranscriber` symmetry); Option A if instance-per-meeting hygiene is preferred. **Either way the plan must include a test that starts, stops, and starts again, asserting video started twice.**
**Warning signs:** log line "ScreenRecorder.start called while state=stopped -- ignoring".

### Pitfall 2: Callbacks assigned after `start()` are silently ignored
**What goes wrong:** `onFirstFrameHostTime` never fires (no anchor) and `onStreamStopped` never fires (mid-meeting death goes undetected → silent failure).
**Why:** `WriterSink` is constructed with the *current values* of both closures at start time (`ScreenRecorder.swift:145-152`); later assignment to the `ScreenRecorder` properties does not reach the live sink.
**How to avoid:** Always assign both callbacks immediately before `await start(...)` (Pattern 2). With per-meeting instances (Pitfall 1 Option A) this is structural.
**Warning signs:** anchor log line never appears; a killed stream produces no error banner.

### Pitfall 3: Actor reentrancy — stop arriving while video start is still in flight
**What goes wrong:** `await screenRecorder.start(...)` suspends the coordinator actor for a measured **~200 ms+** (18-04: `start_to_anchor_ms=214.5`, dominated by `SCShareableContent` enumeration; a TCC prompt makes it much longer). During that suspension the actor can process `.manualStop` → `executeStopAndTranscribe` → `stopVideo()` runs while `videoContext` is still nil and the engine is still `.idle` → the stop no-ops, then the in-flight start completes and leaves a **running capture with no owner and no stop path** — a file left open at meeting end (violates success criterion 4).
**Why:** Swift actors are reentrant at every `await`; the existing code has no `await` between audio start and the end of `executeStartRecording`, so this hazard is new in Phase 19.
**How to avoid — two viable shapes:**
- **Shape 1 (join-on-teardown, recommended):** store the start as a task — `videoStartTask = Task { await self.startVideoInner(...) }` (unstructured Tasks created in actor context inherit that isolation; verified compile-clean) — and have `stopVideo()` do `await videoStartTask?.value` before `await screenRecorder.stop()`. Bonus: audio start latency and `NotificationManager.recordingStarted` are no longer delayed by SCK enumeration.
- **Shape 2 (inline await, simplest):** `await` the start inline and accept that the actor is busy ~200 ms; an early stop then serializes naturally *after* start completes. Simpler and race-free, but it delays every stop/`switchInputDevice` event by the start latency and makes a TCC-prompt stall block the actor.
**Warning signs:** a `.mov` still growing after the meeting ended; "ScreenRecorder started" logged after "Recording stopped".

### Pitfall 4: `isRecording` lies after a stream death
**What goes wrong:** Coordinator logic keyed on `screenRecorder.isRecording` believes video is alive after SCK killed the stream.
**Why:** `didStopWithError` transitions only the **sink's** state to `.failed` (`ScreenRecorder.swift:558-563`); the owner-domain `state` stays `.recording`, so `isRecording` (`:60`) still returns `true`.
**How to avoid:** Treat `onStreamStopped` as the authoritative death signal (clear `videoContext`, surface the error); call `stop()` unconditionally on teardown regardless of any flag (it is a safe no-op after a stream error).

### Pitfall 5: A slow/hung `stop()` delays transcription
**What goes wrong:** `stop()` awaits `SCStream.stopCapture()` (`:212-217`); if SCK is wedged, `executeStopAndTranscribe` stalls before `pipeline.enqueue` — the meeting appears stuck in "Processing…".
**How to avoid (optional, if the planner wants belt-and-braces):** a bounded race — `withTaskGroup` with one child calling `await rec.stop()` and one `Task.sleep(for: .seconds(5))`, taking `group.next()` then `cancelAll()` (verified compile-clean). The engine's finalize is already non-blocking, so a timed-out stop still leaves a playable fragmented file. Note this costs a test and some complexity; the alternative is to accept SCK's stop latency (normally milliseconds).
**Warning signs:** long gap between "Recording stopped for meeting X" and the pipeline's first step.

### Pitfall 6: App quit leaves video unfinalized
**What goes wrong:** `AppState.shutdown()` → `coordinator.stop()` (`:105-110`) stops only audio today. Quit during a recording leaves the video writer open.
**How to avoid:** add `await stopVideo()` there and make `stop()` async (sole caller is already inside a `Task`, `AppState.swift:368-371`). Be honest in the summary: `NSApp.terminate` does not await that Task, so finalize may not complete — the fragmented `.mov` remains playable up to the last ~10 s fragment (VID-07, verified in 18-04). Do NOT block quit on `finishWriting` (Pitfall 7 of the milestone research).

### Pitfall 7: Video failure surfaced as "Last recording failed"
**What goes wrong:** Reusing `lastRecordingError` renders "⚠️ Last recording failed: …" (`MenuBarView.swift:27`) for a meeting whose audio + transcript succeeded — user-facing misinformation, and it is auto-cleared on the next recording start (`AppState.swift:169`).
**How to avoid:** see Open Question 1 — a dedicated `lastVideoError` with honest copy ("Screen recording stopped — audio was saved").

### Pitfall 8: New files not added to the Xcode project
**What goes wrong:** `ScreenRecording.swift`, `ScreenRecordingSettings.swift`, and the new test files exist on disk but aren't compiled → confusing "cannot find type" errors.
**How to avoid:** `project.yml` uses directory-based `sources:` globs, so `xcodegen generate` (i.e. `make setup`, run automatically by `make build`/`make test`) picks them up. Run it after adding files, before assuming a red build is a code problem.

---

## Code Examples

### Verified: actor owning a non-Sendable engine, with @Sendable callbacks hopping back
```swift
// Source: compiled against the REAL Sources/Recording/ScreenRecorder.swift with
// `swiftc -swift-version 6 -strict-concurrency=complete` (Xcode 26.2 toolchain) — 0 errors.
actor Coord {
    private let screenRecorder: ScreenRecording?
    private var firstFrameTicks: UInt64?

    func startVideo(meetingId: String) async {
        guard let screenRecorder else { return }
        screenRecorder.onFirstFrameHostTime = { [weak self] ticks in
            Task { await self?.recordAnchor(ticks) }
        }
        screenRecorder.onStreamStopped = { [weak self] error in
            Task { await self?.handleStreamStopped(error) }
        }
        do {
            try await screenRecorder.start(target: .display(nil), preset: .balanced,
                                           outputURL: URL(fileURLWithPath: "/tmp/\(meetingId).mov"))
        } catch { /* log + surface + continue */ }
    }
    func stopVideo() async { await screenRecorder?.stop() }
    private func recordAnchor(_ ticks: UInt64) { firstFrameTicks = ticks }
    private func handleStreamStopped(_ error: Error?) { /* surface */ }
}
```

### Verified: mock shape for forced-failure tests (NSLock precedent)
```swift
// Source: compiled clean alongside the real engine; mirrors Tests/Mocks/MockStreamingEngine.swift:20-31
final class MockScreenRecorder: ScreenRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var _startCallCount = 0
    private var _stopCallCount = 0
    var startError: Error?                       // forced start failure (VID-04 case 1)
    var stopDelay: Duration?                     // forced slow stop      (VID-04 case 3)
    var onFirstFrameHostTime: (@Sendable (UInt64) -> Void)?
    var onStreamStopped: (@Sendable (Error?) -> Void)?
    var isRecording: Bool { lock.withLock { _startCallCount > _stopCallCount } }
    var startCallCount: Int { lock.withLock { _startCallCount } }
    var stopCallCount: Int { lock.withLock { _stopCallCount } }

    func start(target: ScreenRecorder.CaptureTarget,
               preset: ScreenRecorder.QualityPreset, outputURL: URL) async throws {
        lock.withLock { _startCallCount += 1 }
        if let startError { throw startError }
        onFirstFrameHostTime?(mach_absolute_time())      // deterministic anchor for tests
    }
    func stop() async {
        if let stopDelay { try? await Task.sleep(for: stopDelay) }
        lock.withLock { _stopCallCount += 1 }
    }
    /// Test hook: simulate SCK error -3821 / window-closed mid-meeting (VID-04 case 2).
    func simulateStreamDeath(_ error: Error) { onStreamStopped?(error) }
}
```

### Verified: anchor pair capture
```swift
// audio half — in executeStartRecording, right after `try recorder.start(...)` returns
let audioStartTicks = mach_absolute_time()

// video half — from onFirstFrameHostTime (fires once, on writerQueue)
private func recordFirstFrameAnchor(_ ticks: UInt64) {
    guard var ctx = videoContext else { return }
    ctx.firstFrameTicks = ticks
    videoContext = ctx
    var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
    let offset = ScreenRecorder.hostTicksToSeconds(ticks, timebase: tb)
               - ScreenRecorder.hostTicksToSeconds(ctx.audioStartTicks, timebase: tb)
    logger.info("Video anchor for \(ctx.meetingId): offset=\(offset, format: .fixed(precision: 3))s")
    // Phase 20 persists (audioStartTicks, firstFrameTicks) / the derived offset.
}
```

### Verified: `AudioFileManager.videoPath`
```swift
// Source: pattern copied verbatim from AudioFileManager.swift:29-36
/// Returns the video (.mov) file path for a given meeting ID.
static func videoPath(for meetingId: String) -> URL {
    audioDirectory.appendingPathComponent("\(meetingId).mov")
}
```

---

## Verification Evidence (this session)

| Claim | How verified | Result |
|-------|--------------|--------|
| Engine is single-use; restart is a silent no-op | Compiled + **executed** `ScreenRecorder.transition` from the real source | `stopped+started -> stopped`, `failed+started -> failed`, `idle+started -> recording` |
| Actor may own `ScreenRecording?` and `await start/stop` | `swiftc -swift-version 6 -strict-concurrency=complete -typecheck` on real `ScreenRecorder.swift` + modeled coordinator | 0 errors |
| Non-Sendable `CaptureTarget` crosses fine when built at the call site | same compile | 0 errors |
| `Task { await rec.stop() }` inside the actor | same compile | 0 errors |
| `withTaskGroup` stop-timeout race | same compile | 0 errors |
| `@Sendable () -> ScreenRecording` factory injection | same compile | 0 errors |
| `@unchecked Sendable` + NSLock mock conforms | same compile | 0 errors |
| Pre-existing engine warning (not introduced by Phase 19) | same compile | 1 warning: `capture of 'writer' with non-Sendable type 'AVAssetWriter'` at `ScreenRecorder.swift:581` — exists today, unrelated to this phase |
| Toolchain matches the project | `xcodebuild -version`; `project.yml` | Xcode 26.2 / Swift 6.2.3; `SWIFT_VERSION 6.0`, `SWIFT_STRICT_CONCURRENCY complete`, deployment target 14.2 |

---

## Runtime State Inventory

Phase 19 is an integration phase, not a rename — but it introduces runtime state that no grep of the repo will reveal.

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | **New:** `UserDefaults` key `screenRecordingEnabled` under `com.caddie.app`, default absent → OFF. No DB writes in this phase (`video_file` column is Phase 20) | Code only; no migration. Manual verification must set it: `defaults write com.caddie.app screenRecordingEnabled -bool true` (there is no toggle UI until Phase 21) |
| Live service config | None — no external services. SCK is in-process | None |
| OS-registered state | **TCC Screen Recording grant** for the built app. 18-04 notes: the Debug build had to be added via "+" in System Settings from DerivedData; grants survive rebuilds with the same signing identity; launching via `open` (LaunchServices) is required for TCC to attribute capture to Caddie | Manual verification prerequisite; also the mechanism for the VID-04 forced-failure manual check (revoke the grant → start throws) |
| Secrets/env vars | None | None |
| Build artifacts / files on disk | **New:** `~/Library/Application Support/Caddie/audio/<meetingId>.mov` files. `totalStorageUsed()` (`AudioFileManager.swift:254-274`) already sums the whole directory so video counts automatically; `findOrphanedWAVs()` (`:228-238`) filters `.wav` only, so it ignores video (correct); `deleteAudio(meetingId:)` (`:241-251`) does **not** remove `.mov` | Documented transient limitation until Phase 20; note it in the phase summary and README |
| Test side effects | Existing coordinator tests already write real WAVs to the real audio directory via a real `AudioRecorder` (see Validation Architecture). Video must NEVER use the real engine in tests — it would capture the developer's screen and require TCC | Enforced by the protocol seam + `nil` default |

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Xcode / xcodebuild | `make build`, `make test` | ✓ | 26.2 (17C52) | — |
| Swift toolchain | strict-concurrency build | ✓ | 6.2.3 (language mode 6.0) | — |
| XcodeGen | `make setup` for new files | ✓ (used by every make target) | per repo | — |
| ScreenCaptureKit / AVFoundation | engine | ✓ (system) | macOS 26 SDK, target 14.2 | — |
| Screen Recording TCC grant | manual/integration video checks only | ⚠️ per-machine, granted for the Debug build in 18-04 | — | Unit tests use the mock; no TCC needed |
| `Scripts/kill9-recovery-gate.sh` + `--validate-mov` harness | optional integration leg | ✓ (`Sources/Recording/ScreenRecorderHarness.swift:82-101`, DEBUG-only) | — | Manual QuickTime playback |
| Real display + audio input device | existing coordinator tests (audio) | ✓ on dev Mac | — | none (pre-existing baseline) |

**Missing dependencies with no fallback:** none.
**Missing with fallback:** TCC grant — only the manual leg needs it; all Phase 19 unit tests run mocked.

---

## Validation Architecture

*(`workflow.nyquist_validation: true` in `.planning/config.json`)*

### Test Framework
| Property | Value |
|----------|-------|
| Framework | XCTest via `xcodebuild` (XcodeGen-generated project) |
| Config file | `project.yml` (run `xcodegen generate` / `make setup` after adding files) |
| Quick run command | `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -destination 'platform=macOS' -only-testing:CaddieTests/RecordingCoordinatorScreenCaptureTests` |
| Full suite command | `make test` (require `** TEST SUCCEEDED **`) |
| Baseline | 304 tests green at end of Phase 18 (18-VERIFICATION.md:75) |
| Runtime | quick ~60–90 s (project build dominates) · full ~5–10 min |

### Honest note on the existing coordinator test rig
`RecordingCoordinatorTests.makeCoordinator()` (`Tests/RecordingCoordinatorTests.swift:28-35`) injects a **real `AudioRecorder`** — there is no AudioRecorder mock or protocol in the project. Tests like `testMeetingDetectedTransitionsToRecording` only pass because `AudioRecorder.start` genuinely succeeds on a dev Mac (it creates a real WAV in `~/Library/Application Support/Caddie/audio` and opens the default input). So: **coordinator tests today DO depend on audio hardware, and video tests will inherit that dependency.** Phase 19 does not fix that (out of scope), but it must not make it worse — hence a mock-only video seam. A consequence worth stating in the plan: "audio still recording" assertions can be made against the DB row / `isLiveTeeAttached` / coordinator state, not against real sample data.

### Phase Requirements → Test Map
| Req | Behavior (success criterion) | Test type | Automated command | File exists? |
|-----|------------------------------|-----------|-------------------|--------------|
| VID-03 | Manual start → video started exactly once with the meeting's `.mov` URL | unit | `-only-testing:CaddieTests/RecordingCoordinatorScreenCaptureTests/testManualStartStartsVideo` | ❌ Wave 0 |
| VID-03 | Calendar-prompted start (`.meetingDetected`) → video started (same side effect) | unit | `…/testMeetingDetectedStartsVideo` | ❌ Wave 0 |
| VID-03 | `.manualStop` → video stopped once, before pipeline enqueue | unit | `…/testManualStopStopsVideo` | ❌ Wave 0 |
| VID-03 | `.meetingEnded` → video stopped once | unit | `…/testMeetingEndedStopsVideo` | ❌ Wave 0 |
| VID-03 | `.deviceDisconnected` → video stopped once (same effect path) | unit | `…/testDeviceDisconnectStopsVideo` | ❌ Wave 0 |
| VID-03 | Second meeting in the same session also records video (Pitfall 1 regression) | unit | `…/testSecondMeetingStartsVideoAgain` | ❌ Wave 0 |
| VID-03 | `nil` screen recorder (feature off) → recording works unchanged | unit | `…/testRecordingWorksWithoutScreenRecorder` | ❌ Wave 0 |
| VID-03 | Settings key default is OFF; enabled reads the key | unit | `-only-testing:CaddieTests/ScreenRecordingSettingsTests` | ❌ Wave 0 |
| VID-04 | `start` throws → state stays `.recording`, meeting completes to `.transcribing` on stop, error surfaced via `onVideoError` | unit | `…/testVideoStartFailureDegradesToAudioOnly` | ❌ Wave 0 |
| VID-04 | `onStreamStopped` mid-meeting → error surfaced, state still `.recording`, later stop still finalizes and enqueues | unit | `…/testStreamDeathMidMeetingSurfacesAndKeepsAudio` | ❌ Wave 0 |
| VID-04 | Error teardown (`.recordingFailed` → `executeNotifyError`) also stops video | unit | `…/testErrorPathStopsVideo` | ❌ Wave 0 |
| VID-04 | Slow stop does not prevent the meeting from reaching `.transcribing` (only if the timeout of Pitfall 5 is implemented) | unit | `…/testSlowVideoStopDoesNotBlockPipeline` | ❌ Wave 0 |
| VID-03/04 | `videoPath(for:)` layout `<meetingId>.mov` in the audio dir | unit | `-only-testing:CaddieTests/ScreenRecordingSettingsTests/testVideoPath` | ❌ Wave 0 |
| STOR-04 (in-mem leg) | Anchor pair captured: audio ticks non-zero, first-frame ticks recorded from the callback | unit (DEBUG accessor) | `…/testAnchorPairCapturedInMemory` | ❌ Wave 0 |
| Criterion 4 | Real capture: a real meeting with video enabled yields a playable `.mov` of ≈ wall-clock duration and nothing left open | **manual gate** | see below | n/a |
| Criterion 3 | Real TCC-denied start degrades to audio-only end-to-end | **manual gate** | see below | n/a |

**Test-visibility helpers (mirror `isLiveTeeAttached`, `RecordingCoordinator.swift:114-121`):**
```swift
#if DEBUG
var isVideoActive: Bool { videoContext != nil }
var videoAnchorPair: (audio: UInt64, firstFrame: UInt64?)? {
    videoContext.map { ($0.audioStartTicks, $0.firstFrameTicks) }
}
#endif
```

### Manual / integration gate (honest scope)
Real SCStream capture cannot run in `make test` (TCC grant + a real display + it would record the developer's screen). Reuse the Phase 18 machinery:
1. `defaults write com.caddie.app screenRecordingEnabled -bool true` (no UI until Phase 21), relaunch via `open -n` (LaunchServices, per 18-04 environment notes).
2. Record a ~30 s manual meeting, stop normally. Assert: `<id>.mov` exists beside `<id>.m4a`; transcription completed; `Caddie.app/Contents/MacOS/Caddie --validate-mov <path>` prints `isPlayable=true` with duration ≈ elapsed (exit 0).
3. Repeat immediately for a SECOND meeting in the same app session → second `.mov` also playable (Pitfall 1 regression, the one bug a unit test can only approximate).
4. Revoke the Screen Recording grant → start a meeting → expect: audio records and transcribes normally, video error visible in the menu bar, error in `log stream`, no `.mov` (or a zero-length one) left open.
5. Quit the app mid-recording → resulting `.mov` still playable (VID-07 behavior; may lose ≤ ~10 s).

`Scripts/kill9-recovery-gate.sh` is NOT required again in Phase 19 (it gates the engine, already passed in 18-03/18-04); the `--validate-mov` mode of the same harness is the useful reusable piece.

### Sampling Rate
- **Per task commit:** the targeted `-only-testing` quick command for the touched class
- **Per wave merge:** `make test` (full suite; expect ≥ 304 + new tests, 0 failures)
- **Phase gate:** full suite green + the manual gate above before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] `Tests/Mocks/MockScreenRecorder.swift` — NSLock mock with `startError` / `stopDelay` / `simulateStreamDeath`
- [ ] `Tests/RecordingCoordinatorScreenCaptureTests.swift` — VID-03 + VID-04 coverage
- [ ] `Tests/ScreenRecordingSettingsTests.swift` — key/default pinning (raw literal, per the `GoogleCalendarServiceTests.swift:259` precedent of NOT referencing the constant) + `videoPath(for:)`
- [ ] `#if DEBUG` accessors on `RecordingCoordinator` for video state + anchor pair
- [ ] `xcodegen generate` after adding files
- *(No framework install needed — XCTest is already wired.)*

---

## Security Domain

`security_enforcement` is not set in `.planning/config.json` → treated as enabled. This phase is a local, offline macOS integration; most ASVS categories are structurally inapplicable.

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | No auth surface in this phase (Google OAuth is untouched) |
| V3 Session Management | no | — |
| V4 Access Control | yes (OS-level) | macOS TCC Screen Recording grant is the access control; the app must degrade gracefully when denied (VID-04) and never attempt to bypass or spoof the grant |
| V5 Input Validation | minimal | Only inputs are a `Bool` UserDefaults key and an internally generated `meetingId` (UUID prefix, `RecordingState.swift:169-171`) used in a file name — no user-supplied path components |
| V6 Cryptography | no | No new crypto; nothing leaves the device (no network calls added) |
| V12 File & Resources | yes | Video is written only under `~/Library/Application Support/Caddie/audio/` via `AudioFileManager` (sandbox/App-Support scoped); no temp-dir leakage; existing directory permissions apply |

| Threat pattern (this stack) | STRIDE | Mitigation |
|------|--------|------------|
| Screen capture is inherently privacy-sensitive: it can record other apps' content | Information disclosure | Off by default (`ScreenRecordingSettings.defaultEnabled = false`); Caddie's own windows already excluded (VID-05, verified in 18-04); nothing is uploaded — file stays local |
| A stale/orphaned `.mov` survives meeting deletion (Phase 19→20 window) | Information disclosure | Documented transient limitation; Phase 20 extends `deleteAudio` — must not be forgotten (tracked in the phase summary + README) |
| Silent capture without user awareness | Repudiation | Video only ever runs inside an explicit recording session the user started (state machine guarantees it); macOS also shows its own capture indicator |

---

## State of the Art

| Old approach | Current approach | When changed | Impact |
|--------------|------------------|--------------|--------|
| "Making ScreenRecorder an actor and fighting SCK's delegate queues" (milestone ARCHITECTURE gotcha) | Non-Sendable class + confined writerQueue + `@Sendable` callbacks | Phase 18-01/02 | Phase 19 just consumes it; no isolation redesign needed |
| Assumed Swift 6 friction: "budget a spike, main friction point" (ARCHITECTURE Pattern 2 trade-off) | **Empirically zero friction for the wiring** — every candidate shape compiles clean under the project's flags | This research (2026-07-31) | The planner should NOT budget a concurrency spike wave for Phase 19 |
| Roadmap phrasing "anchor accurate to ~100 ms" | Anchor is exact by construction; the ~200 ms figure is *setup latency* (start-call → first frame), not error | 18-04 | Phase 19 logs both ticks; no tolerance-tuning work |

**Deprecated/outdated for this phase:** the milestone ARCHITECTURE build-order note that puts the coordinator wiring *together with* storage (migration + disk guard) — the phase split moved storage to Phase 20; do not pull `video_file`, deletion, or the disk-guard raise into Phase 19.

---

## Assumptions Log

| # | Claim | Section | Risk if wrong |
|---|-------|---------|---------------|
| A1 | `AudioRecorder.start()` succeeding in the current test environment is why existing coordinator tests reach `.recording` (inferred from code flow, not from a test run in this session) | Validation Architecture | Low — affects only how the plan words its "audio still recording" assertions; if audio start actually fails in CI, those tests are already red today |
| A2 | `NSApp.terminate` does not await the `Task` spawned by `AppState.shutdown()` | Pitfall 6 | Low — the fragmented `.mov` is playable either way (VID-07 verified); only the honesty of the summary wording depends on it |
| A3 | SCK `stopCapture()` normally completes in milliseconds (basis for treating the stop-timeout as optional) | Pitfall 5 | Medium — if SCK stalls are common, a hung stop would visibly delay transcription; the timeout is cheap insurance |
| A4 | `defaults write com.caddie.app screenRecordingEnabled -bool true` maps to `UserDefaults.standard` for the built app (bundle id `com.caddie.app` per `project.yml`) | Runtime State Inventory, manual gate | Low — if wrong, the manual gate needs a temporary debug toggle instead |
| A5 | Adding an optional trailing init parameter keeps every existing coordinator construction site compiling (4 sites found: 2 test helpers ×2 files, 1 AppState) | Pattern 1 | Low — mechanically verifiable at build time |

---

## Open Questions (RESOLVED)

> Resolution record (2026-07-10, orchestrator + plan set `ca248f4`):
> - Q1 error surfacing → RESOLVED: dedicated `lastVideoError`/`onVideoError` channel + menu-bar row (19-02/19-04); `lastRecordingError` untouched.
> - Q2 single-use engine → RESOLVED: per-meeting factory injection (`ScreenRecorderFactory`), engine untouched (19-01/19-02/19-03).
> - Q3 start reentrancy → RESOLVED: task-join Shape 1 — `stopVideo()` awaits the in-flight `videoStartTask` (19-02/19-03).
> - Q4 stop timeout → RESOLVED: shipped — 5 s bounded race, surfaces video error, never blocks `pipeline.enqueue` (19-03-T2).

1. **How should a non-fatal video error be "surfaced" (VID-04)?** — *needs a decision before planning*
   - What we know: the only existing user-visible error surface is `AppState.lastRecordingError` → `MenuBarView` "⚠️ Last recording failed: …", written **only** from the `.error` state and shown **only** in the `.idle` branch (`AppState.swift:177`, `MenuBarView.swift:26-31`). Video failures must not enter `.error`.
   - Options:
     - **(A) Recommended — dedicated channel.** `RecordingCoordinator.setOnVideoError` (copy `setOnPipelineStepChange`, `:59-61`) → `AppState.lastVideoError: String?` → one line in `MenuBarView`'s `.idle` *and* `.recording` branches ("⚠️ Screen recording stopped — audio was saved") + a Dismiss. ~15 lines of UI. Honest copy; visible during the meeting, when it matters.
     - **(B) Minimal — reuse `lastRecordingError`.** Zero UI change, strictly "existing error-surfacing path" per CONTEXT — but renders "Last recording failed" for a meeting that succeeded (Pitfall 7) and is auto-cleared on the next start.
   - Tension: CONTEXT says "surfaced (existing error-surfacing path)" and scopes UI to Phase 21; (A) adds a small amount of UI. Recommendation: **(A)**, because (B) tells the user something false, which conflicts with the project's no-silent/no-misleading-failure core value. Whichever is chosen, also fire `NotificationManager` only if the user should be interrupted (recommend: no — log + banner is enough for a degraded-but-working recording), and update README per CLAUDE.md deliverables rule.

2. **Which fix for the single-use engine (Pitfall 1)?** Option A (factory / per-meeting instance) vs Option B (3-line restart transition in `ScreenRecorder`). Both verified compile-clean. Recommendation: **B** if the locked "constructed in AppState.initialize()" wording is binding; **A** if instance hygiene is preferred. Must be decided in planning, not during execution.

3. **Inline `await` vs task-join for video start (Pitfall 3)?** Recommendation: Shape 1 (store `videoStartTask`, join it in `stopVideo()`) — it removes both the ~200 ms actor stall on the start path and the stop-before-start-completes hole. Shape 2 is simpler and acceptable if the planner prefers fewer moving parts; it must then explicitly accept the start-latency stall.

4. **Ship the stop-timeout (Pitfall 5) now or defer?** Verified compile-clean, costs ~10 lines + 1 test. Slight preference: include it — a wedged SCK stop otherwise strands a meeting in "Processing…", which is a core-value failure mode.

5. **Anchor precision:** the audio half is `mach_absolute_time()` at start-call return, not the first sample's `AudioTimeStamp.mHostTime` (which IS available in the render callbacks — `MicrophoneCapture.swift:467`, `SystemAudioCapture.swift:919` — but is not plumbed out). CONTEXT locks the coordinator-level capture, so use it; note the residual device-start latency in the phase summary so Phase 20 can decide whether to plumb the exact value.

---

## Sources

### Primary (HIGH confidence)
- Codebase read, 2026-07-31: `Sources/Coordinator/RecordingCoordinator.swift`, `Sources/Coordinator/RecordingState.swift`, `Sources/Recording/ScreenRecorder.swift`, `Sources/Recording/ScreenRecorderHarness.swift`, `Sources/Recording/AudioRecorder.swift`, `Sources/App/AppState.swift`, `Sources/App/CaddieApp.swift`, `Sources/Storage/AudioFileManager.swift`, `Sources/Transcription/LiveTranscriber.swift`, `Sources/Calendar/GoogleCalendarService.swift`, `Sources/Utilities/Permissions.swift`, `Sources/Utilities/NotificationManager.swift`, `Sources/UI/MenuBar/MenuBarView.swift`, `Tests/RecordingCoordinatorTests.swift`, `Tests/RecordingCoordinatorLiveTranscriptionTests.swift`, `Tests/Mocks/MockStreamingEngine.swift`, `Tests/ProtocolDITests.swift`, `project.yml`, `Makefile`
- Compiler experiments this session (`swiftc -swift-version 6 -strict-concurrency=complete`, Xcode 26.2 / Swift 6.2.3) against the real `ScreenRecorder.swift` — see § Verification Evidence
- Phase 18 artifacts: `18-02-SUMMARY.md` (public API, stop/error semantics), `18-04-SUMMARY.md` (hardware results, 214.5 ms setup latency, TCC/`open` + `log stream` environment notes), `18-VERIFICATION.md` (304-test baseline), `18-VALIDATION.md` (validation doc format)
- Milestone research: `.planning/research/ARCHITECTURE.md` (integration points table, Patterns 1-5, Anti-Patterns 1-3), `.planning/research/PITFALLS.md` (Pitfalls 6, 7, 10; Integration Gotchas; "Looks Done But Isn't" checklist)
- `.planning/REQUIREMENTS.md` (VID-03, VID-04 text + phase mapping), `.planning/STATE.md` (decision log), `./CLAUDE.md`

### Secondary (MEDIUM confidence)
- `.planning/phases/19-recording-lifecycle-integration/19-CONTEXT.md` — user decisions (authoritative for scope, not for technical facts)

### Tertiary (LOW confidence)
- None. No WebSearch was used: every question in this phase is answerable from the codebase or the compiler, and both are more authoritative than any external source for this work.

## Project Constraints (from CLAUDE.md)

| Directive | How this phase complies |
|-----------|-------------------------|
| TDD: write tests first, no exceptions | Wave 0 gaps list the mock + test files; every VID-03/VID-04 row has a named test |
| Strict typing; no `any`/`unknown` without justification | Protocol existential is the only indirection; concrete types elsewhere |
| Handle errors explicitly — no silent catches | Every video `catch` logs **and** surfaces; Pitfall 1 exists precisely because the engine currently fails silently on restart |
| Small functions, one thing each | `startVideoIfEnabled` / `stopVideo` / `recordFirstFrameAnchor` / `handleVideoStreamStopped` as separate private methods |
| Check if something already exists before writing new logic | Reuses `hostTicksToSeconds`, `MeetingPromptSettings` pattern, `setOnStateChange` callback pattern, `MockStreamingEngine` NSLock pattern, `--validate-mov` harness |
| No dead code / no commented-out code | Anchor values are logged in Phase 19 (used, not dormant); Phase 20 consumes them |
| Update README.md when shipping features | Screen-recording behavior + the "enable via `defaults write` until Phase 21" note + the transient deletion limitation belong in the README in this phase's final task |
| Atomic commits, never commit to main, no Co-Authored-By | Standard GSD execution; current branch `feature/18-screen-capture-engine` — planner should confirm the Phase 19 branch |
| GSD workflow enforcement (no direct edits outside a GSD command) | This is research only; no source files were modified (compiler experiments ran in the scratchpad) |

---

## Metadata

**Confidence breakdown:**
- Integration surface (paths, line numbers, reducer behavior): **HIGH** — read directly from source; device-disconnect equivalence proven from `reduce`
- Swift 6 wiring shapes: **HIGH** — compiled against the real engine with the project's exact flags/toolchain, not reasoned about
- Single-use engine defect: **HIGH** — pure function executed, output captured
- Test seam design: **HIGH** — mock compiles; mirrors two existing project precedents
- Error-surfacing recommendation: **MEDIUM** — mechanism is certain; the UI-scope call needs a human decision (Open Question 1)
- Stop-timeout necessity: **MEDIUM** — based on SCK behavior assumptions (A3), not measured here
- Manual-gate procedure: **MEDIUM-HIGH** — reuses 18-04's documented, executed environment recipe

**Research date:** 2026-07-31
**Valid until:** ~2026-08-30 (stable — all inputs are in-repo; invalidated only by changes to `RecordingCoordinator`, `ScreenRecorder`, or the Xcode toolchain)
