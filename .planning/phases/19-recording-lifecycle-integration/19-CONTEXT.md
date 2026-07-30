# Phase 19: Recording Lifecycle Integration - Context

**Gathered:** 2026-07-10
**Status:** Ready for planning
**Source:** Milestone scoping decisions + Phase 18 outcomes (18-01..18-04 SUMMARYs)

<domain>
## Phase Boundary

`ScreenRecorder` (built and hardware-verified in Phase 18) is injected into `RecordingCoordinator` so video starts and stops with every meeting recording — manual and calendar-prompted alike — and can NEVER take down the audio recording. NO DB schema (`video_file` column is Phase 20), NO Settings UI (Phase 21), NO playback. Phase 19 may define the persistence KEY that gates video (default off) so the wiring is shippable before the Phase 21 toggle exists.

</domain>

<decisions>
## Implementation Decisions

### Injection pattern (locked — mirrors LiveTranscriber)
- `ScreenRecorder` is an optional constructor dependency of `RecordingCoordinator`, exactly like `liveTranscriber: LiveTranscriber?`. Constructed in `AppState.initialize()` only when screen recording is enabled.
- Enablement gate: a shared settings enum (MeetingPromptSettings pattern — static key + default) with **default OFF**; Phase 21 builds the visible toggle over the same key. VID-01's "off by default" semantic starts here.

### Lifecycle (locked by roadmap success criteria)
- Video starts ONLY AFTER `recorder.start(...)` (audio) succeeds — audio is always the senior partner.
- Video stops/finalizes in BOTH stop paths: `executeStopAndTranscribe` (normal) and `executeNotifyError` (error teardown), plus the device-disconnect path if it tears down separately. No video file may be left open or corrupted when a meeting ends (Phase 18's finalize paths are proven — wiring must call them).
- Graceful degradation (VID-04, core-value safety net): ANY video failure — start throw, mid-recording `onStreamStopped`, stop failure — is logged with context and surfaced (existing error-surfacing path), and the audio recording continues/completes normally. Never abort or fail the meeting because of video.

### File placement (locked)
- Video writes to the canonical storage layout NOW: `<meetingId>.mov` beside the audio files (AudioFileManager conventions — add `videoPath(for:)`). Phase 20 adds the DB column, deletion, and disk guard. Transient limitation (acceptable, documented): between Phases 19 and 20, deleting a meeting won't remove its video file.

### Timing anchor plumbing (locked)
- Coordinator captures the audio-start host time and subscribes to `onFirstFrameHostTime`, holding both values with the in-flight recording (in-memory) and logging them. Persistence to the meetings row is Phase 20 (STOR-04 storage leg). Note from 18-04: first frame lands ~200 ms after the start call (setup latency) — alignment uses the anchor, which is exact.

### Phase 18 facts the plan must respect
- `ScreenRecorder` is a non-Sendable `final class` designed to be owned by one isolation domain (the coordinator actor) — same ownership model as `AudioRecorder`.
- `start(target:preset:outputURL:)` is async throws; `stop()` finalizes async without blocking; `onStreamStopped` fires on SCK-initiated stops (window closed, error -3821) leaving a playable partial.
- `CaptureTarget` is NOT Sendable (SCWindow) — mind actor boundaries when passing it.
- Phase 19 uses `.display(nil)` + `.balanced` as the interim target/preset (user-facing choice is Phase 21); read from the settings enum if trivially available.

### Conventions (project)
- TDD mandatory. Protocol seam + mock for the recorder in coordinator tests (project precedent: engine protocols enabling mock injection into TranscriptionPipeline; MockStreamingEngine with NSLock). Swift 6 strict concurrency. No silent failures. XcodeGen regen for new files. `make test` gates.

### Claude's Discretion
- Exact protocol shape for the test seam (e.g. `ScreenRecording` protocol with start/stop/callbacks) vs closure injection.
- Where the settings enum lives (Sources/Recording/ vs Sources/Storage/) and its exact key strings.
- Whether device-disconnect teardown needs distinct handling or flows through executeNotifyError already.
- How the anchor pair is held in-memory (struct on the coordinator vs fields).

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase 18 outputs (the engine being wired)
- `Sources/Recording/ScreenRecorder.swift` — public API, callbacks, ownership model
- `.planning/phases/18-screen-capture-engine/18-02-SUMMARY.md` — final signatures, stop/error semantics
- `.planning/phases/18-screen-capture-engine/18-04-SUMMARY.md` — hardware verification, setup-latency nuance, environment notes (TCC via `open`, log stream)

### Integration surface
- `Sources/Coordinator/RecordingCoordinator.swift` — executeStartRecording / executeStopAndTranscribe / executeNotifyError, LiveTranscriber lifecycle precedent
- `Sources/Coordinator/RecordingState.swift` — reducer; NO new states/side-effects expected (video piggybacks on existing ones)
- `Sources/App/AppState.swift` — initialize() step where deps are constructed
- `Sources/Storage/AudioFileManager.swift` — path conventions for `videoPath(for:)`
- `Sources/Calendar/GoogleCalendarService.swift:MeetingPromptSettings` — the settings-enum pattern to copy

### Milestone research
- `.planning/research/ARCHITECTURE.md` — integration points (file:symbol), anti-patterns
- `.planning/research/PITFALLS.md` — graceful-degradation and teardown pitfalls

</canonical_refs>

<specifics>
## Specific Ideas

- Roadmap success criteria: (1) video begins after audio starts and stops when meeting stops, both trigger paths; (2) both stop paths finalize cleanly; (3) forced video failure → logged/surfaced, audio completes (degrade to audio-only); (4) no video file left open/corrupted at meeting end.
- Forced-failure test idea: inject a mock recorder whose start throws / whose onStreamStopped fires mid-meeting; assert audio pipeline completes and error was surfaced.

</specifics>

<deferred>
## Deferred Ideas

- `video_file` column, deletion with meeting, disk-guard raise, anchor persistence → Phase 20
- Settings toggle UI, capture-target + preset pickers, permission request UX → Phase 21
- Playback/export → Phase 21

</deferred>

---

*Phase: 19-recording-lifecycle-integration*
*Context gathered: 2026-07-10 from milestone decisions + Phase 18 outcomes*
