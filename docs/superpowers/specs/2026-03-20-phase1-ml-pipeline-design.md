# Phase 1: ML Pipeline Integration — Design Specification

**Date:** 2026-03-20
**Status:** Approved
**Author:** Yash Desai + Claude
**Depends on:** Original Caddie design spec (`2026-03-19-caddie-design.md`)

---

## Overview

This spec covers integrating FluidAudio SDK into Caddie to replace the stub ASR and diarization engines with working on-device ML inference. After this work, Caddie will be able to record a meeting and produce a speaker-labeled transcript — the core product loop.

### What Changes

- `project.yml` — add FluidAudio SPM dependency
- `Sources/Transcription/ASREngine.swift` — stub → FluidAudio Parakeet wrapper
- `Sources/Transcription/DiarizationEngine.swift` — stub → FluidAudio Sortformer wrapper
- `Sources/Transcription/TranscriptionPipeline.swift` — change initializer to accept injected engines, add mono mixdown step before ASR/diarization, delete WAV after ALAC compression
- `Sources/Models/ModelManager.swift` — stub → FluidAudio's built-in download system, remove unused `modelsDirectory`/`verifyModels()`
- `Sources/App/AppState.swift` — restructure `initialize()` to create ModelManager first, download models, then inject engines into pipeline; change `pipeline` from inline constant to late-initialized property
- `Sources/UI/Onboarding/OnboardingView.swift` — add model download step with progress bar between permissions and "Get Started"

### What Does NOT Change

- Detection system (all 4 monitors + decision engine)
- Recording system (CoreAudio Tap + AVAudioEngine → stereo WAV)
- Storage layer (GRDB, Meeting model, AudioFileManager, ALAC compression)
- TranscriptMerger (temporal overlap algorithm — already implemented and tested)
- All other UI (menu bar, main window, settings, shared components)

---

## FluidAudio SDK

### What It Is

FluidAudio is a Swift SDK for on-device audio AI on Apple platforms. It runs inference on the Apple Neural Engine (ANE) for minimal CPU/power usage. MIT/Apache 2.0 licensed, 1.7k stars on GitHub, actively maintained (v0.12.4 as of March 2026).

- **GitHub:** `https://github.com/FluidInference/FluidAudio`
- **HuggingFace org:** `https://huggingface.co/FluidInference`
- **Sample app:** `https://github.com/FluidInference/swift-scribe`
- **Swift Package Index:** `https://swiftpackageindex.com/FluidInference/FluidAudio`

### Platform Requirements

- macOS 14+ / iOS 17+
- Swift Tools 6.0, C++17
- Depends on `swift-transformers` (HuggingFace tokenizers) v1.2.0+

### SPM Integration

```swift
// In project.yml packages section:
FluidAudio:
  url: https://github.com/FluidInference/FluidAudio.git
  from: "0.12.4"
```

---

## ASR Integration

### FluidAudio ASR API

FluidAudio wraps NVIDIA's Parakeet TDT 0.6B v3 model, converted to CoreML and optimized for Apple Neural Engine.

**Model:** `FluidInference/parakeet-tdt-0.6b-v3-coreml` on HuggingFace
**Languages:** 25 European languages with automatic detection
**Performance:** ~110-190x real-time on M4 Pro (1 hour audio in ~19-30 seconds)
**Input:** 16kHz mono Float32 PCM (files accepted via URL — SDK handles format conversion)

#### Initialization

```swift
import FluidAudio

// Download models (cached after first download)
let models = try await AsrModels.downloadAndLoad(version: .v3)

// Create manager and initialize
let asrManager = AsrManager(config: .default)
try await asrManager.initialize(models: models)
```

#### Transcription

```swift
// From file URL — simplest path
let result = try await asrManager.transcribe(URL(fileURLWithPath: "meeting.wav"))

// Also supports raw [Float] samples or AVAudioPCMBuffer
```

For audio >30 seconds, the SDK automatically uses chunked streaming mode with constant ~1.2MB memory. Progress is reported for audio >15 seconds.

#### Output: ASRResult

```swift
public struct ASRResult {
    public let text: String                    // full transcribed text
    public let confidence: Float               // 0.1–1.0 average token probability
    public let duration: TimeInterval          // audio duration in seconds
    public let processingTime: TimeInterval    // wall-clock inference time
    public let tokenTimings: [TokenTiming]?    // per-token timestamps

    public var rtfx: Double { ... }            // real-time factor (speed multiplier)
}

public struct TokenTiming {
    public let token: String          // word or subword
    public let tokenId: Int
    public let startTime: TimeInterval  // seconds
    public let endTime: TimeInterval    // seconds
    public let confidence: Float
}
```

### Caddie ASREngine Design

Replace the stub with a wrapper that:

1. Initializes `AsrManager` with downloaded models
2. Accepts a mono WAV URL
3. Calls `asrManager.transcribe(url)`
4. Groups `TokenTiming` array into `ASRSegment` chunks (our existing type)
5. Returns `(segments: [ASRSegment], language: String, duration: Double)`

#### Token-to-Segment Grouping

FluidAudio returns per-token timings. Our `TranscriptMerger` expects sentence-level `ASRSegment` objects. The grouping algorithm:

1. Iterate through `tokenTimings`
2. Accumulate tokens into a current segment
3. Split into a new segment when:
   - A sentence-ending punctuation is encountered (`.` `?` `!`)
   - A silence gap > 0.8 seconds exists between consecutive tokens
   - The current segment exceeds 30 seconds duration
4. Each segment gets: `start` (first token's startTime), `end` (last token's endTime), `text` (joined tokens), `words` (mapped from TokenTiming to WordTimestamp)

```swift
struct ASRSegment {
    let start: Double       // seconds
    let end: Double         // seconds
    let text: String        // segment text
    let words: [WordTimestamp]
}

struct WordTimestamp {
    let word: String
    let start: Double
    let end: Double
}
```

#### Error Handling

- Model not loaded → `ASRError.modelNotLoaded`
- Transcription failure → `ASRError.transcriptionFailed(message)`
- Empty audio file → return empty segments array (not an error)

---

## Diarization Integration

### FluidAudio Diarizer API

FluidAudio provides two diarizer backends. We use **SortformerDiarizer** (NVIDIA Sortformer).

> **Naming note:** The original Caddie design spec (2026-03-19) references "pyannote v4" for diarization. In FluidAudio's API, the Sortformer model is the recommended diarizer — it is a different architecture than pyannote but serves the same purpose. FluidAudio also has pyannote-derived models but Sortformer is newer and faster. The original spec's intent (speaker diarization on CoreML/ANE) is fulfilled by Sortformer.

- **Max speakers:** 4
- **Mode:** Batch (offline) — no streaming needed for v1
- **Model:** Downloaded and cached by FluidAudio automatically

#### Initialization

```swift
import FluidAudio

let diarizer = SortformerDiarizer(
    config: .default,
    timelineConfig: .sortformerDefault  // 4 speakers, 80ms frames
)
// Models downloaded automatically on first use
try await diarizer.initialize(mainModelPath: modelURL)
```

#### Batch Processing

```swift
let timeline = try diarizer.processComplete(
    audioFileURL: URL(fileURLWithPath: "meeting_mono.wav"),
    keepingEnrolledSpeakers: nil,
    finalizeOnCompletion: true,
    progressCallback: { processed, total, chunks in
        // Report progress to UI
    }
)
```

#### Output: DiarizerTimeline

```swift
public final class DiarizerTimeline {
    public var speakers: [Int: DiarizerSpeaker]   // index → speaker
    public var finalizedDuration: Float
}

public final class DiarizerSpeaker: Identifiable {
    public let id: UUID
    public var name: String?
    public var index: Int
    public var finalizedSegments: [DiarizerSegment]
    public var speechDuration: Float
}

public struct DiarizerSegment: Sendable, Identifiable {
    public var speakerIndex: Int
    public var startTime: Float      // seconds
    public var endTime: Float        // seconds
    public var duration: Float
    public var isFinalized: Bool
    public var speakerLabel: String  // "Speaker 0", "Speaker 1", etc.
}
```

### Caddie DiarizationEngine Design

Replace the stub with a wrapper that:

1. Initializes `SortformerDiarizer` with downloaded models
2. Accepts a mono WAV URL
3. Calls `diarizer.processComplete(audioFileURL:)`
4. Maps `DiarizerTimeline` → `[SpeakerSegment]` (our existing type)
5. Calls `diarizer.reset()` after each job to free memory

#### Output Mapping

```swift
// FluidAudio output:
timeline.speakers[0].finalizedSegments → [DiarizerSegment(startTime, endTime, speakerLabel)]

// Mapped to our type:
struct SpeakerSegment {
    let start: Double       // from DiarizerSegment.startTime
    let end: Double         // from DiarizerSegment.endTime
    let speaker: String     // from DiarizerSegment.speakerLabel ("Speaker 0" → "SPEAKER_00")
}
```

All finalized segments from all speakers are collected into a flat `[SpeakerSegment]` array, sorted by start time. Speaker labels are normalized to `SPEAKER_00`, `SPEAKER_01`, etc. for consistency with our UI's `SpeakerBadge` color hashing.

#### Error Handling

- Model not loaded → `DiarizationError.modelNotLoaded`
- Diarization failure → `DiarizationError.diarizationFailed(message)`
- No speakers detected → return empty array (not an error — merger defaults to "Speaker")

---

## Mono Mixdown

### Why

Our recording is stereo 16kHz WAV:
- **Left channel (0):** System audio (remote participants)
- **Right channel (1):** Microphone (your voice)

Both ASR and diarization expect **mono** input. We need to mix down before feeding to FluidAudio.

### Implementation

Add a `createMonoMixdown(stereoURL:) -> URL` method to `TranscriptionPipeline` or `AudioFileManager`:

1. Open the stereo WAV with `ExtAudioFile`
2. Read interleaved samples: `[L0, R0, L1, R1, ...]`
3. Average each pair: `mono[i] = (left[i] + right[i]) / 2.0`
4. Write mono samples to a temp WAV file at the same sample rate (16kHz)
5. Return the temp file URL

The temp mono file is deleted after both ASR and diarization complete.

**Why average instead of using one channel?** Averaging captures both sides of the conversation. ASR needs to hear everyone. Using only the mic channel would miss remote participants; using only system audio would miss the user.

### Alternative Considered

Pass stereo directly and let FluidAudio handle it — but the SDK expects mono, and mixing ourselves gives us control over the blend. Simple average is correct for our use case since both channels are at the same sample rate and bit depth.

---

## Model Management

### Current State

`ModelManager.swift` is a stub with placeholder download logic. It checks for `~/Library/Application Support/Caddie/models/parakeet/` and `diarization/` directories.

### New Design

FluidAudio manages its own model downloads and caching internally:

- ASR models: `AsrModels.downloadAndLoad(version: .v3)` — downloads to FluidAudio's internal cache
- Diarizer models: Downloaded during `SortformerDiarizer.initialize()`

Our `ModelManager` becomes a **thin coordinator** that:

1. Calls FluidAudio's download APIs
2. Pipes download progress to the UI via `@Observable` properties
3. Tracks whether models are ready (have been downloaded and loaded at least once)
4. Provides a retry mechanism if download fails

```swift
@Observable
final class ModelManager {
    var isDownloading = false
    var downloadProgress: Double = 0    // 0.0–1.0
    var downloadError: String?
    var modelsReady: Bool = false

    private var asrModels: AsrModels?
    private var diarizer: SortformerDiarizer?

    func downloadModelsIfNeeded() async {
        // 1. Download ASR models via FluidAudio
        // 2. Download diarizer models via FluidAudio
        // 3. Track progress from FluidAudio's progress callbacks
        // 4. Set modelsReady = true when both complete
    }

    func getASRModels() -> AsrModels? { asrModels }
    func getDiarizer() -> SortformerDiarizer? { diarizer }
}
```

### Model Sizes (Approximate)

- **Parakeet ASR (v3):** ~600 MB–1.2 GB (depending on quantization)
- **Sortformer diarization:** ~129 MB
- **Total first-launch download:** ~800 MB–1.4 GB

### Cache Location

FluidAudio caches models in its own directory (typically `~/Library/Application Support/FluidAudio/Models/`). We do NOT duplicate models into our Caddie models directory — we let FluidAudio manage its own cache.

The existing `ModelManager.modelsDirectory` static property, `modelsReady` computed property (which checks local directories), and `verifyModels()` method are all replaced. Delete them — FluidAudio manages its own cache. The `modelsReady` boolean becomes a simple stored property set to `true` after successful download.

### Cache Clearing

FluidAudio provides:
```swift
DownloadUtils.clearAllModelCaches()
DownloadUtils.clearModelCache(forRepo: repo, directory: dir)
```

Wire the "Clean Up" button in Settings to optionally clear model caches as well (with a warning about re-download time).

---

## Pipeline Changes

### Current Code (What Needs Restructuring)

Currently, `TranscriptionPipeline` creates its own engines inline:

```swift
// TranscriptionPipeline.swift (current — lines 10-11)
private let asrEngine = ASREngine()
private let diarizationEngine = DiarizationEngine()
```

And `AppState` creates the pipeline with no arguments:

```swift
// AppState.swift (current — line 32)
private let pipeline = TranscriptionPipeline()
```

This must change because FluidAudio engines require downloaded models at initialization time. Engines cannot be constructed until models are available.

### Current Pipeline Flow

```
1. ASR (stub — throws notImplemented)
2. Diarization (stub — throws notImplemented)
3. Merge (implemented — TranscriptMerger)
4. Write transcript to database
5. Compress WAV → ALAC
6. Update meeting status to .done
   (Note: WAV is NOT deleted after compression — this is new in the new flow)
```

### New Flow

```
1. Create mono mixdown from stereo WAV → temp file
2. ASR: asrManager.transcribe(monoURL) → group into ASRSegments
3. Diarization: diarizer.processComplete(monoURL) → map to SpeakerSegments
4. Delete temp mono file
5. Merge: TranscriptMerger.merge(asrSegments, speakerSegments) → Transcript
6. Write transcript JSON to database
7. Compress stereo WAV → ALAC (keep the original stereo for playback)
8. Update meeting status to .done
9. Delete stereo WAV (NEW — current code does not do this; done AFTER status
   is set to .done so that retry is still possible if the status update fails)
```

### Structural Changes to TranscriptionPipeline

Change the initializer to accept injected engines:

```swift
// TranscriptionPipeline.swift (new)
actor TranscriptionPipeline {
    private let asrEngine: ASREngine
    private let diarizationEngine: DiarizationEngine

    init(asr: ASREngine, diarization: DiarizationEngine) {
        self.asrEngine = asr
        self.diarizationEngine = diarization
    }
    // ... rest unchanged
}
```

### Structural Changes to AppState

Change `pipeline` from an inline constant to a late-initialized property. The initialization order becomes:

```swift
// AppState.swift (new initialization order)
func initialize() async {
    guard !isInitialized else { return }
    do {
        database = try AppDatabase()
        try AudioFileManager.ensureDirectoryExists()

        // 1. Download models (FluidAudio handles caching)
        let modelManager = ModelManager()
        await modelManager.downloadModelsIfNeeded()

        // 2. Initialize engines with downloaded models
        let asrEngine = ASREngine()
        try await asrEngine.initialize(models: modelManager.getASRModels())

        let diarizationEngine = DiarizationEngine()
        try await diarizationEngine.initialize(diarizer: modelManager.getDiarizer())

        // 3. Create pipeline with injected engines
        pipeline = TranscriptionPipeline(asr: asrEngine, diarization: diarizationEngine)

        // 4. Start detection
        detector.onMeetingStarted = { ... }
        detector.onMeetingEnded = { ... }
        detector.start()

        isInitialized = true
    } catch {
        initError = error.localizedDescription
    }
}
```

**Note:** `initialize()` changes from synchronous to `async` because model download is async. The `.task` modifier in ContentView already calls it in an async context, so this is compatible.

### Engine Lifecycle

ASR and diarization engines are **initialized once** at app startup (in `AppState.initialize()`) and reused across meetings. They are NOT created per-transcription — model loading is expensive.

### Concurrency

The `TranscriptionPipeline` is already an actor that processes one job at a time. FluidAudio's inference is also sequential (one CoreML inference at a time on ANE). No changes needed to concurrency model.

### Error Recovery

Same as existing design:
- Pipeline catches errors, logs with elapsed time
- Sets meeting status to `.error` with error message
- User can retry via "Retry Transcription" button in MeetingDetailView
- Retry re-enqueues the meeting (the stereo WAV still exists if status is `.error` because WAV deletion only happens after status is set to `.done`)

---

## Onboarding Changes

### Current Onboarding Flow

1. Permission requests (Microphone, Accessibility, Screen Recording)
2. "Get Started" button → marks onboarding complete

### New Flow

1. Permission requests (unchanged)
2. **Model download step** (new):
   - Header: "Downloading AI Models"
   - Subtitle: "This is a one-time download (~1 GB). Models run entirely on your Mac."
   - Progress bar showing `ModelManager.downloadProgress`
   - Download size estimate
   - Error state with retry button if download fails
   - "Continue" button enabled when `modelsReady == true`
3. "Get Started" button → marks onboarding complete

### Skip/Background Option

If the user dismisses onboarding before models finish downloading, the download continues in the background. The app functions normally (detection + recording work) — transcription just queues until models are ready. When models finish downloading, queued meetings are processed automatically.

---

## Testing Strategy

### Unit Tests

- **ASREngine token grouping:** Test the token-to-segment grouping algorithm with mock `TokenTiming` arrays. Verify sentence splitting, silence gap detection, max duration splitting.
- **DiarizationEngine output mapping:** Test mapping from `DiarizerTimeline` → `[SpeakerSegment]`. Verify speaker label normalization, time accuracy, sorting.
- **Mono mixdown:** Test that stereo → mono conversion produces correct sample count and values.

### Integration Test (Manual)

- Record a real meeting (or simulate with a test audio file)
- Verify end-to-end: detection → recording → mixdown → ASR → diarization → merge → transcript in UI
- Check transcript quality, speaker labels, timestamps

### Existing Tests

All 7 existing test files should continue to pass unchanged:
- `MeetingDetectorTests.swift` — detection logic (not touched)
- `MeetingPatternsTests.swift` — pattern matching (not touched)
- `MeetingModelTests.swift` — GRDB record types (not touched)
- `TranscriptMergerTests.swift` — merge algorithm (not touched)
- `FormattersTests.swift` — formatters (not touched)
- `ExportTests.swift` — export formats (not touched)
- `CaddieTests.swift` — basic tests (not touched)

---

## Dependencies After This Work

| Dependency | Version | Purpose | License |
|------------|---------|---------|---------|
| **FluidAudio** | 0.12.4+ | ASR (Parakeet) + Diarization (Sortformer) on CoreML/ANE | MIT / Apache 2.0 |
| **swift-transformers** | 1.2.0+ | HuggingFace tokenizers (transitive via FluidAudio) | Apache 2.0 |
| **GRDB** | 7.0.0+ | SQLite database | MIT |
| **SimplyCoreAudio** | 4.0.0+ | CoreAudio mic state monitoring | MIT |
| **AXSwift** | 0.3.2+ | Accessibility API for window titles | MIT |
| **Sparkle** | 2.6.0+ | Auto-updates | MIT |

### Model Licenses

- **Parakeet TDT 0.6B v3:** CC-BY-4.0 (original NVIDIA model)
- **Sortformer diarization:** Apache 2.0 (SDK) + CC-BY-4.0 (pyannote parent model)

---

## Fallback Strategy

If FluidAudio becomes unavailable:

- **ASR fallback:** WhisperKit by Argmax (MIT, SPM, proven CoreML Whisper implementation). Would require changing the ASREngine wrapper but not the pipeline or merger.
- **Diarization fallback:** Use the pre-exported CoreML models from `FluidInference/speaker-diarization-coreml` on HuggingFace directly, or speech-swift (Apache 2.0). Would require a custom CoreML pipeline in DiarizationEngine.

The thin wrapper architecture means swapping backends only requires changing 2 files (ASREngine + DiarizationEngine). The pipeline, merger, storage, and UI are all backend-agnostic.

---

## Summary

This is a focused integration: 5 files modified, 1 new dependency. The existing architecture was designed for this — we're filling in stubs, not restructuring anything. After this work, Caddie's core loop is complete: detect → record → transcribe → view.
