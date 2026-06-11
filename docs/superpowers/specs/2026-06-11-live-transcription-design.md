# Live Transcription During Recording — Design

**Date:** 2026-06-11
**Status:** Approved
**Scope:** Stream live transcripts in the UI while a meeting is being recorded. No speaker segmentation in the live view. The final saved transcript is unchanged (full-accuracy pass + diarization after recording stops).

## Goals

- While a recording is active, the user sees text appear within a few seconds of speech.
- Live text is display-only: when recording stops, the existing TranscriptionPipeline produces the persisted transcript exactly as today; the live view hands off to the existing "Transcribing…" progress UI.
- Live transcription failures never affect recording. The WAV capture path is untouched on the real-time thread.

## Non-Goals

- Speaker labels in the live view (diarization stays post-recording only).
- Persisting live text to the database.
- A floating/always-on-top transcript window (decided: detail view only).
- Changing the final transcript quality or pipeline.

## Architecture

### Engine: FluidAudio StreamingAsrManager

FluidAudio (already a dependency, models already bundled) provides `StreamingAsrManager`:

- `start(models: AsrModels, source:)` — reuses the AsrModels already loaded by ModelManager; no additional model load or memory.
- `streamAudio(_ buffer: AVAudioPCMBuffer)` — accepts arbitrary-format buffers; converts/buffers internally.
- `transcriptionUpdates: AsyncStream<StreamingTranscriptionUpdate>` — emits updates with two tiers: **confirmed** text (stable) and **volatile** text (still revising), like Apple's Speech API.
- `cancel()` — tear down without a final flush (we don't need `finish()`; the real transcript comes from the batch pipeline).
- Config: use the low-latency `.streaming` preset (`StreamingAsrConfig.streaming`).

### Audio tee (AudioRecorder)

`AudioRecorder.flushRingBuffer()` already drains the SPSC ring buffer on the main thread every 100ms and writes to the WAV. It gains:

```swift
/// Called on the main thread with each drained batch of samples (16 kHz mono Int16),
/// after they are written to the WAV. nil when live transcription is inactive.
var onSamples: (([Int16]) -> Void)?
```

Invoked with the same samples written to disk. The real-time render callback is not touched. If `onSamples` is nil, behavior is identical to today.

### LiveTranscriber (new: Sources/Transcription/LiveTranscriber.swift)

Thin wrapper that isolates FluidAudio streaming from the rest of the app:

- `start(models: AsrModels) async` — creates StreamingAsrManager (`.streaming` config), starts it, spawns a consumer task over `transcriptionUpdates`.
- `feed(samples: [Int16])` — converts Int16 16 kHz mono → `AVAudioPCMBuffer` (Float32, 16 kHz, mono) and calls `streamAudio`.
- `onUpdate: @MainActor (String, String) -> Void` — (confirmed, volatile) pushed on every update.
- `stop() async` — cancels the manager and consumer task; idempotent.
- Error policy: any internal error logs via CaddieLogger.transcription and stops the transcriber. Errors never propagate to callers; recording continues.

A small protocol seam (`StreamingTranscriptionEngine` or equivalent) abstracts StreamingAsrManager so update plumbing is unit-testable without models.

### Wiring

- `AppState.initialize` constructs `LiveTranscriber` (only when `modelManager.asrModels` exists) and passes it to `RecordingCoordinator`.
- `RecordingCoordinator.executeStartRecording`: after `recorder.start(...)` succeeds, start the LiveTranscriber and set `recorder.onSamples = { transcriber.feed($0) }`. Failure to start live transcription is logged and ignored (recording proceeds without live text).
- `executeStopAndTranscribe` / device-disconnect / error paths: `recorder.onSamples = nil`, then `await transcriber.stop()` before enqueueing the batch pipeline (frees ANE contention before the full-accuracy pass).
- No RecordingState reducer changes: live transcription is a side effect of entering/leaving `.recording`, executed by the coordinator.

### UI

- `AppState` gains observable `liveConfirmedText: String` and `liveVolatileText: String`, set by LiveTranscriber's `onUpdate`, cleared when state returns to `.idle` and when a new recording starts.
- `MeetingDetailView`'s existing recording card (shown while the selected meeting is `.recording`) adds a live transcript area:
  - Scrolling text view; confirmed text in `.primary`, volatile tail appended in `.secondary`.
  - Auto-scrolls to bottom on update (pinned-to-bottom behavior).
  - Empty state ("Listening…") before the first confirmed text.
  - After Stop, the card is replaced by the existing transcribing-progress UI as today; live strings are cleared on `.idle`.

## Failure Handling

| Failure | Behavior |
|---|---|
| LiveTranscriber.start throws | Log; recording continues with no live text |
| Update stream errors mid-recording | Log; transcriber stops; last text remains until stop |
| ASR models absent | LiveTranscriber never constructed; recording unaffected |
| Recording stops/errors | onSamples detached first, transcriber cancelled, batch pipeline unchanged |

## Performance

- Streaming uses the same CoreML/ANE models already resident; incremental chunked inference (FluidAudio `.streaming` preset).
- Sample handoff is a main-thread array copy at 100ms cadence (~1600 samples/batch) — negligible.
- Live transcriber is stopped before the batch pipeline runs, so no ANE contention during the final pass.

## Testing (TDD)

- Int16 → AVAudioPCMBuffer conversion: sample count, format, value scaling.
- Update plumbing via protocol seam: confirmed/volatile strings reach onUpdate on MainActor.
- AudioRecorder tee: onSamples receives drained samples; nil callback = no-op (existing tests still pass).
- Coordinator lifecycle: transcriber started on record-start, stopped before pipeline enqueue (seam/spy).
- End-to-end live audio requires a microphone: manual verification.
