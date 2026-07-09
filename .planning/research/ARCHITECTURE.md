# Architecture Research

**Domain:** Integrating ScreenCaptureKit video capture into Caddie's existing Swift 6 recording pipeline
**Researched:** 2026-07-09 (22-agent workflow sweep + full codebase read)
**Confidence:** HIGH (integration points verified against current source)

## Existing Recording Architecture (as-read, 2026-07-09)

Recording is audio-only today; ScreenCaptureKit/SCStream/AVAssetWriter appear nowhere in the codebase. Flow: `AppState` (@MainActor @Observable, Sources/App/AppState.swift) builds a `RecordingCoordinator` during `initialize()` with non-optional deps (AppDatabase, AudioRecorder, TranscriptionPipeline, MeetingDetector) plus **optional** AudioDeviceManager and LiveTranscriber. `RecordingCoordinator` (Sources/Coordinator/RecordingCoordinator.swift) is a Swift **actor** owning the lifecycle via a pure reducer — `RecordingState.reduce(state:event:)` (Sources/Coordinator/RecordingState.swift) returns `(newState, RecordingSideEffect?)` synchronously; the coordinator executes side effects asynchronously (`.startRecording`, `.stopAndTranscribe`, `.retryTranscription`, `.notifyComplete`, `.notifyError`).

`executeStartRecording` checks 500 MB free disk (`checkDiskSpace`), inserts a Meeting row (status=.recording), then calls `AudioRecorder.start(outputPath:deviceUID:)` and optionally attaches the live-transcription sample tee. `AudioRecorder` (Sources/Recording/AudioRecorder.swift) is a **final class, not an actor** — confined to the coordinator's isolation domain. Real-time audio flows MicrophoneCapture → lock-free `SPSCRingBuffer` → 100 ms main-queue drain → ExtAudioFileWrite. `SystemAudioCapture` (Sources/Recording/SystemAudioCapture.swift) captures system audio via **CoreAudio process taps** (`CATapDescription`/`AudioHardwareCreateProcessTap`, the 14.2+ API that set the deployment floor) — **not** ScreenCaptureKit. Stop path: `executeStopAndTranscribe` detaches callbacks, `recorder.stop()`, sets end_time, enqueues into the `TranscriptionPipeline` actor (mixdown → ASR → diarization → merge → transcript JSON → ALAC compress → delete WAV).

**Key consequence:** there is no existing SCStream to attach video to. Video is a **new, independent, video-only SCStream** (`capturesAudio = false`). Do not consolidate system audio into the SCStream — that would rewrite working code for no gain.

## System Overview (v3.0 additions marked ★)

```
AppState (@MainActor, @Observable)
 │  initialize(): builds deps; ★ constructs ScreenRecorder when
 │  Settings toggle on + Permissions.screenRecording == .granted
 ▼
RecordingCoordinator (actor) ── RecordingState.reduce (pure; unchanged ★)
 │
 ├─ executeStartRecording
 │    ├─ checkDiskSpace (★ raised threshold when video enabled)
 │    ├─ insert Meeting row
 │    ├─ AudioRecorder.start(...)              [unchanged, source of truth]
 │    └─ ★ ScreenRecorder.start(target:url:)   [after audio succeeds;
 │         failure → log + continue audio-only, LiveTranscriber pattern]
 │
 ├─ executeStopAndTranscribe / executeNotifyError
 │    ├─ recorder.stop()
 │    ├─ ★ screenRecorder.stop()  → finishWriting (async, non-blocking)
 │    └─ pipeline.enqueue(...)     [video NOT in the ML pipeline]
 │
 ├─ AudioRecorder ──► <meetingId>.wav → (pipeline) → .m4a
 └─ ★ ScreenRecorder (final class, Sources/Recording/)
        SCShareableContent → SCContentFilter (display | window)
        → SCStream (video-only, 10–15fps) ─ delegate queue (background)
        → AVAssetWriter (.mov, HEVC 2–3 Mbps, movieFragmentInterval 10s)
        → <meetingId>.mov + first-frame host-clock anchor
                │
Storage: AppDatabase / Migrations (★ v_add_video_file: nullable video_file
         + host-clock anchor column, NOT in FTS5) / Meeting (★ videoFile)
         AudioFileManager (★ videoPath(for:), delete + storage accounting)
                │
UI: MeetingDetailView (★ AVKit player next to AudioPlayerView),
    SettingsView (★ Record-screen toggle + target picker)
```

## Integration Points (verbatim from codebase read)

| Location | Change |
|----------|--------|
| `Sources/Coordinator/RecordingCoordinator.swift:RecordingCoordinator.init` | Inject an optional screen recorder dependency exactly like `liveTranscriber: LiveTranscriber?` (constructed in AppState.initialize() only when the feature toggle is on) |
| `Sources/Coordinator/RecordingCoordinator.swift:executeStartRecording` | Start video after `recorder.start(...)` succeeds; follow the graceful-degradation pattern (log + continue audio-only on video failure, like LiveTranscriber start failures) |
| `Sources/Coordinator/RecordingCoordinator.swift:executeStopAndTranscribe` | Stop/finalize video alongside `recorder.stop()` before `pipeline.enqueue`; **also stop video in `executeNotifyError`** (the error path already tears down the live tee there) |
| `Sources/Coordinator/RecordingCoordinator.swift:checkDiskSpace` | Raise `minimumDiskSpaceBytes` (500 MB) when video is enabled (2.5 Mbps ≈ 1.1 GB/hr; SCK itself gets flaky under ~12 GB free) |
| `Sources/Coordinator/RecordingState.swift:RecordingState.reduce` | **No new states needed** — video piggybacks on `.startRecording`/`.stopAndTranscribe` side effects and the `.deviceDisconnected`/`.recordingFailed` teardown events |
| `Sources/Recording/` — new `ScreenRecorder` | Sibling of AudioRecorder/SystemAudioCapture (naming convention: `final class` in Sources/Recording/), SCStream + AVAssetWriter writing compressed video directly — no WAV→ALAC-style post-pass needed; AVAssetWriter encodes HEVC in-flight |
| `Sources/Storage/AudioFileManager.swift:videoPath(for:)` | Add next to `wavPath(for:)`/`alacPath(for:)` (layout: `~/Library/Application Support/Caddie/audio/<meetingId>.<ext>`); extend `deleteAudio(meetingId:)` to remove the video file (called from Sources/UI/MainWindow/MeetingDetailView.swift:299); `totalStorageUsed()` already sums the whole directory |
| `Sources/Storage/Migrations.swift:Migrations.run` | New `migrator.registerMigration("v2_add_video_file")` adding a nullable `video_file` TEXT column to `meetings` (v1_create_meetings shows the pattern); **video_file must NOT be added to the FTS5 table/triggers**. Add the host-clock anchor column (video↔audio start offset) in the same migration |
| `Sources/Storage/Meeting.swift:Meeting` | Add `var videoFile: String?` + CodingKeys case `videoFile = "video_file"` (snake_case mapping convention) |
| `Sources/UI/Settings/SettingsView.swift:generalSection` (or a new Recording section) | 'Record screen' Toggle + capture-target choice persisted via the MeetingPromptSettings pattern: a shared enum with static `key` + `default` (see Sources/Calendar/GoogleCalendarService.swift:MeetingPromptSettings), read in `.onAppear`, written in `.onChange`; `AudioDeviceManager.selectedDeviceUID` (Sources/Recording/AudioDeviceManager.swift:79-100) shows the alternative didSet-persistence pattern |
| `Sources/Utilities/Permissions.swift:Permissions.screenRecording` | Status check already exists (CGWindowListCopyWindowInfo inference), surfaced in SettingsView.permissionsSection and OnboardingView; video reuses the same TCC grant, but there is **no request method yet** — add `CGRequestScreenCaptureAccess()` |
| `Sources/App/AppState.swift:initialize` step 5 | Construct the ScreenRecorder (gated on settings toggle + `Permissions.screenRecording == .granted`) and pass into RecordingCoordinator; surface failures via `lastRecordingError` (no-silent-failure rule) |

## Architectural Patterns

### Pattern 1: Optional dependency with graceful degradation (reuse of LiveTranscriber shape)

**What:** `ScreenRecorder?` injected into the coordinator; nil when the toggle is off or permission missing. Start failure logs and continues audio-only; video is strictly additive.
**Why:** Directly satisfies the core value — video failure must never abort or degrade the WAV/ASR pipeline. The pattern, injection site, and error surface (`lastRecordingError`) already exist.
**Trade-off:** Two capture lifecycles to keep in sync at stop/error; mitigated by routing all teardown through the existing reducer side effects (no new states).

### Pattern 2: Non-Sendable final class confined to the coordinator actor, with an internal writer queue

**What:** `ScreenRecorder` mirrors `AudioRecorder` — a `final class` owned by the RecordingCoordinator actor. Under `SWIFT_STRICT_CONCURRENCY: complete`, SCStream delegate callbacks (`SCStreamOutput.stream(_:didOutputSampleBuffer:of:)`, `SCStreamDelegate.stream(_:didStopWithError:)`) arrive on **background queues the framework owns** — they cannot be actor-isolated. The delegate handler appends to AVAssetWriterInput on a dedicated serial queue (AVAssetWriter handles its own backpressure via `isReadyForMoreMediaData`); cross-actor notifications (e.g. stream died) go through `@Sendable` callbacks, matching the `onSamples` tee convention.
**Why:** Keeps the SCK/writer hot path off the actor executor and completely separate from the audio ring buffer (real-time discipline: no locks/allocations added to audio threads — SCStream and the audio path never touch).
**Trade-off:** A small `@unchecked Sendable` boundary or a dedicated delegate object is likely needed for the queue-confined writer state; document the confinement invariant. Budget a spike here — this is the main Swift 6 friction point.

### Pattern 3: Crash-safe in-flight encoding (contrast with the audio compress-after pattern)

**What:** AVAssetWriter encodes HEVC in-flight to the final `.mov` with `movieFragmentInterval` ≈ 10 s. Unlike audio (WAV → pipeline → ALAC → delete WAV), video needs **no post-pass and no delete-after-compress dance** — but the file must survive on pipeline failure for retry/playback regardless of transcription status.
**Why:** A crash loses at most the last fragment; crashed files remain playable. `finishWriting` runs a defragment pass that grows with duration — run it async, never block app quit on it.

### Pattern 4: Host-clock timestamp anchoring for transcript alignment

**What:** SCStream sample buffers carry PTS on `CMClockGetHostTimeClock()` (mach host time) — the same clock CoreAudio reports in `AudioTimeStamp.mHostTime`. Record (a) host time of the first video frame actually written and (b) host time of the first WAV sample; persist `videoStartOffsetSeconds` (converted via `mach_timebase_info`) in the meetings row.
**Why:** Transcript timeline is WAV-relative; the stored delta maps any segment time onto the video with ppm-level drift over an hour. No library exposes this — a genuine advantage of the native implementation. Capture the anchors in phase 1 even though the seek UI ships later; they can't be reconstructed after the fact.

### Pattern 5: Programmatic capture-target selection

**What:** Settings stores display-vs-window preference; at start, `SCShareableContent.excludingDesktopWindows` resolves the target — `SCContentFilter(display:excludingApplications:[caddieApp]exceptingWindows:[])` for display (exclude Caddie's own windows), or `SCContentFilter(desktopIndependentWindow:)` for the meeting window.
**Why:** No picker friction at recording start; Caddie already holds the TCC grant. SCContentSharingPicker remains a possible later "choose precisely" affordance, not the default.

## Anti-Patterns

### Anti-Pattern 1: Consolidating audio into the video SCStream
**What people do:** "We already have SCK for video, move system audio there for a shared clock."
**Why it's wrong:** System audio uses CoreAudio process taps (SystemAudioCapture.swift:273-292) — proven, hardened code with device-alive listeners and retained RenderContexts. Both clocks are already mach host time; nothing is gained.
**Do this instead:** Independent video-only SCStream, `capturesAudio = false`.

### Anti-Pattern 2: New reducer states for video
**What people do:** Add `.recordingWithVideo`, `.videoFailed` states to RecordingState.
**Why it's wrong:** Video is subordinate to the audio lifecycle; forking the state machine doubles the tested surface and invites divergence.
**Do this instead:** Video piggybacks on existing side effects; its own health is internal to ScreenRecorder + logged/surfaced via lastRecordingError.

### Anti-Pattern 3: Adding video_file to FTS5
**What people do:** Extend the FTS5 table/triggers when adding the column.
**Why it's wrong:** The meetings FTS5 shadow table is synced by triggers on (title, transcript, app); touching them for a filename breaks the migration invariants for zero search value.
**Do this instead:** Plain nullable TEXT column only.

## Suggested Build Order

1. **ScreenRecorder core (capture engine):** SCStream → AVAssetWriter with retiming, static-frame handling, fragmented `.mov`, explicit bitrate, host-clock anchor capture, `didStopWithError` handling. Testable standalone (record N seconds of a display, assert file duration/playability). Includes the Swift 6 delegate-isolation spike.
2. **Storage + coordinator integration:** migration (`video_file` + anchor columns), `Meeting.videoFile`, `videoPath(for:)` + deletion/storage accounting, coordinator injection + start/stop/error wiring, disk-guard raise, `CGRequestScreenCaptureAccess()`.
3. **Settings + UI:** Record-screen toggle + target choice (MeetingPromptSettings pattern), AppState gating, AVKit playback in MeetingDetailView, transcript-time seek using the stored anchor.

Rationale: the capture engine has all the sharp edges (PITFALLS.md) and zero dependencies on schema/UI — de-risk it first. Storage before UI because playback queries the schema. Alignment anchors are captured in step 1 but consumed in step 3.

## Sources

- Caddie codebase read (2026-07-09): Sources/Coordinator/, Sources/Recording/, Sources/Storage/, Sources/Utilities/Permissions.swift, Sources/UI/Settings/SettingsView.swift, project.yml (SWIFT_STRICT_CONCURRENCY: complete)
- nonstrict-hq/ScreenCaptureKit-Recording-example (MIT) — SCStream → AVAssetWriter blueprint; Azayaka ClassicProcessing.swift (read-only) — dual-path structure
- Apple docs: SCStreamOutput/SCStreamDelegate threading, AVAssetWriter movieFragmentInterval, CMClockGetHostTimeClock

---
*Architecture research for: Caddie v3.0 Screen Recording*
*Researched: 2026-07-09 via 22-agent workflow sweep + repo verification*
