# Phase 1: ML Pipeline Integration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integrate FluidAudio SDK to replace stub ASR and diarization engines, completing Caddie's core loop: detect → record → transcribe → view.

**Architecture:** FluidAudio SDK provides on-device ASR (Parakeet) and speaker diarization (Sortformer) via CoreML/ANE. Our existing `ASREngine` and `DiarizationEngine` stubs become thin wrappers. `TranscriptionPipeline` gets dependency injection and a mono mixdown step. `ModelManager` delegates to FluidAudio's built-in download system. `AppState.initialize()` becomes async to await model downloads.

**Tech Stack:** Swift 5.9+, SwiftUI, macOS 14.2+, FluidAudio 0.12.4+, CoreML, AudioToolbox (ExtAudioFile for mono mixdown)

**Spec:** `docs/superpowers/specs/2026-03-20-phase1-ml-pipeline-design.md`

---

## File Map

Every file that will be created or modified, and what changes:

```
project.yml                                    # Add FluidAudio SPM package + dependency
Sources/
├── Transcription/
│   ├── ASREngine.swift                        # Stub → FluidAudio Parakeet wrapper + token grouping
│   ├── DiarizationEngine.swift                # Stub → FluidAudio Sortformer wrapper + output mapping
│   └── TranscriptionPipeline.swift            # DI initializer, mono mixdown step, WAV cleanup
├── Models/
│   └── ModelManager.swift                     # Stub → FluidAudio download coordinator
├── App/
│   └── AppState.swift                         # Async initialize(), model download, engine injection
└── UI/
    └── Onboarding/
        └── OnboardingView.swift               # Add model download step after permissions
Tests/
├── ASREngineTests.swift                       # NEW: token-to-segment grouping tests
├── DiarizationEngineTests.swift               # NEW: output mapping tests
└── MonoMixdownTests.swift                     # NEW: stereo→mono conversion tests
```

---

## Task 1: Add FluidAudio SPM Dependency

**Files:**
- Modify: `project.yml`

**Context:** FluidAudio is a Swift Package at `https://github.com/FluidInference/FluidAudio.git`. We need to add it to the packages section and wire it as a dependency for both the Caddie target and CaddieTests target.

- [ ] **Step 1: Add FluidAudio package to project.yml**

In the `packages:` section, add after Sparkle:

```yaml
  FluidAudio:
    url: https://github.com/FluidInference/FluidAudio
    from: "0.12.4"
```

In the `Caddie` target's `dependencies:` list, add:

```yaml
      - package: FluidAudio
```

In the `CaddieTests` target's `dependencies:` list, add:

```yaml
      - package: FluidAudio
```

- [ ] **Step 2: Regenerate Xcode project**

```bash
cd /Users/yashdesai/Codebase/Fun/Caddie && xcodegen generate
```

Expected: `Generated project Caddie.xcodeproj`

- [ ] **Step 3: Resolve packages and verify build**

```bash
cd /Users/yashdesai/Codebase/Fun/Caddie && xcodebuild -project Caddie.xcodeproj -scheme Caddie -configuration Debug -resolvePackageDependencies 2>&1 | tail -5
```

Expected: Packages resolve successfully. FluidAudio and swift-transformers appear in resolved dependencies.

```bash
cd /Users/yashdesai/Codebase/Fun/Caddie && xcodebuild -project Caddie.xcodeproj -scheme Caddie -configuration Debug build 2>&1 | tail -3
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Run existing tests to verify nothing broke**

```bash
cd /Users/yashdesai/Codebase/Fun/Caddie && xcodebuild -project Caddie.xcodeproj -scheme CaddieTests -configuration Debug test 2>&1 | grep "Executed"
```

Expected: `Executed 7 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add project.yml
git commit -m "feat: add FluidAudio SPM dependency for on-device ML inference"
```

---

## Task 2: Mono Mixdown Utility

**Files:**
- Modify: `Sources/Storage/AudioFileManager.swift` (add `createMonoMixdown` method)
- Create: `Tests/MonoMixdownTests.swift`

**Context:** Both ASR and diarization expect 16kHz mono Float32 audio. Our recordings are stereo WAV (L=system audio, R=mic). We need a utility that averages both channels into a mono temp file. This goes in `AudioFileManager` since it's an audio file operation alongside `compressToALAC`.

- [ ] **Step 1: Write the failing test**

Create `Tests/MonoMixdownTests.swift`:

```swift
import XCTest
import AudioToolbox
@testable import Caddie

final class MonoMixdownTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testMonoMixdown_averagesChannels() throws {
        // Create a short stereo WAV: L=[1000, 3000], R=[2000, 4000]
        // Expected mono: [(1000+2000)/2, (3000+4000)/2] = [1500, 3500]
        let stereoURL = tempDir.appendingPathComponent("stereo.wav")
        try createStereoWAV(at: stereoURL, leftSamples: [1000, 3000], rightSamples: [2000, 4000])

        let monoURL = try AudioFileManager.createMonoMixdown(stereoURL: stereoURL)

        // Verify mono file exists
        XCTAssertTrue(FileManager.default.fileExists(atPath: monoURL.path))

        // Read back and verify samples
        let samples = try readMonoWAVSamples(from: monoURL)
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples[0], 1500)
        XCTAssertEqual(samples[1], 3500)

        // Clean up temp
        try? FileManager.default.removeItem(at: monoURL)
    }

    func testMonoMixdown_outputIsMono16kHz() throws {
        let stereoURL = tempDir.appendingPathComponent("stereo.wav")
        try createStereoWAV(at: stereoURL, leftSamples: [100, 200, 300], rightSamples: [100, 200, 300])

        let monoURL = try AudioFileManager.createMonoMixdown(stereoURL: stereoURL)

        // Read format and verify mono + 16kHz
        var inputFile: ExtAudioFileRef?
        let status = ExtAudioFileOpenURL(monoURL as CFURL, &inputFile)
        XCTAssertEqual(status, noErr)
        guard let file = inputFile else { XCTFail("Could not open mono file"); return }
        defer { ExtAudioFileDispose(file) }

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &format)

        XCTAssertEqual(format.mChannelsPerFrame, 1)
        XCTAssertEqual(format.mSampleRate, 16000.0)

        try? FileManager.default.removeItem(at: monoURL)
    }

    // MARK: - Helpers

    private func createStereoWAV(at url: URL, leftSamples: [Int16], rightSamples: [Int16]) throws {
        precondition(leftSamples.count == rightSamples.count)
        var format = AudioStreamBasicDescription(
            mSampleRate: 16000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,   // 2 channels * 2 bytes
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        var fileRef: ExtAudioFileRef?
        let status = ExtAudioFileCreateWithURL(
            url as CFURL, kAudioFileWAVEType, &format, nil,
            AudioFileFlags.eraseFile.rawValue, &fileRef
        )
        guard status == noErr, let file = fileRef else {
            throw NSError(domain: "test", code: Int(status))
        }
        defer { ExtAudioFileDispose(file) }

        // Interleave: [L0, R0, L1, R1, ...]
        var interleaved = [Int16]()
        for i in 0..<leftSamples.count {
            interleaved.append(leftSamples[i])
            interleaved.append(rightSamples[i])
        }

        try interleaved.withUnsafeBufferPointer { ptr in
            var bufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32(interleaved.count * 2),
                    mData: UnsafeMutableRawPointer(mutating: ptr.baseAddress!)
                )
            )
            let writeStatus = ExtAudioFileWrite(file, UInt32(leftSamples.count), &bufferList)
            guard writeStatus == noErr else {
                throw NSError(domain: "test", code: Int(writeStatus))
            }
        }
    }

    private func readMonoWAVSamples(from url: URL) throws -> [Int16] {
        var fileRef: ExtAudioFileRef?
        let status = ExtAudioFileOpenURL(url as CFURL, &fileRef)
        guard status == noErr, let file = fileRef else {
            throw NSError(domain: "test", code: Int(status))
        }
        defer { ExtAudioFileDispose(file) }

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &format)

        let bufferSize = 8192
        let buffer = UnsafeMutablePointer<Int16>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var samples = [Int16]()
        while true {
            var frameCount: UInt32 = UInt32(bufferSize)
            var bufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(bufferSize * 2),
                    mData: buffer
                )
            )
            ExtAudioFileRead(file, &frameCount, &bufferList)
            if frameCount == 0 { break }
            for i in 0..<Int(frameCount) {
                samples.append(buffer[i])
            }
        }
        return samples
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/yashdesai/Codebase/Fun/Caddie && xcodebuild -project Caddie.xcodeproj -scheme CaddieTests -configuration Debug test 2>&1 | grep -E "error:|FAIL|Executed"
```

Expected: Compilation error — `createMonoMixdown` does not exist on `AudioFileManager`.

- [ ] **Step 3: Implement `createMonoMixdown` in AudioFileManager**

Add to `Sources/Storage/AudioFileManager.swift`, after the `compressToALAC` method:

```swift
    /// Creates a mono mixdown from a stereo WAV file.
    /// Averages left and right channels: mono[i] = (left[i] + right[i]) / 2
    /// Returns the URL of the temp mono WAV file. Caller must delete it when done.
    static func createMonoMixdown(stereoURL: URL) throws -> URL {
        var inputFile: ExtAudioFileRef?
        var status = ExtAudioFileOpenURL(stereoURL as CFURL, &inputFile)
        guard status == noErr, let input = inputFile else {
            throw AudioError.failedToOpenInput(status)
        }
        defer { ExtAudioFileDispose(input) }

        // Read input format
        var inputFormat = AudioStreamBasicDescription()
        var propertySize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = ExtAudioFileGetProperty(input, kExtAudioFileProperty_FileDataFormat, &propertySize, &inputFormat)
        guard status == noErr else {
            throw AudioError.failedToReadFormat(status)
        }

        let sampleRate = inputFormat.mSampleRate
        let channelCount = inputFormat.mChannelsPerFrame
        guard channelCount == 2 else {
            // Already mono — just return a copy or the same URL
            return stereoURL
        }

        // Create output mono WAV
        let monoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("caddie_mono_\(UUID().uuidString).wav")

        var monoFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        var outputFile: ExtAudioFileRef?
        status = ExtAudioFileCreateWithURL(
            monoURL as CFURL, kAudioFileWAVEType, &monoFormat, nil,
            AudioFileFlags.eraseFile.rawValue, &outputFile
        )
        guard status == noErr, let output = outputFile else {
            throw AudioError.failedToCreateOutput(status)
        }
        defer { ExtAudioFileDispose(output) }

        // Read stereo in chunks, average to mono, write
        let chunkFrames: UInt32 = 4096
        let stereoBufferSize = Int(chunkFrames * 2) // 2 channels * Int16
        let stereoBuffer = UnsafeMutablePointer<Int16>.allocate(capacity: stereoBufferSize)
        defer { stereoBuffer.deallocate() }

        let monoBuffer = UnsafeMutablePointer<Int16>.allocate(capacity: Int(chunkFrames))
        defer { monoBuffer.deallocate() }

        while true {
            var frameCount = chunkFrames
            var readList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32(stereoBufferSize * MemoryLayout<Int16>.size),
                    mData: stereoBuffer
                )
            )

            status = ExtAudioFileRead(input, &frameCount, &readList)
            guard status == noErr else { throw AudioError.failedToRead(status) }
            if frameCount == 0 { break }

            // Average: mono[i] = (left[i] + right[i]) / 2
            for i in 0..<Int(frameCount) {
                let left = Int32(stereoBuffer[i * 2])
                let right = Int32(stereoBuffer[i * 2 + 1])
                monoBuffer[i] = Int16((left + right) / 2)
            }

            var writeList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(Int(frameCount) * MemoryLayout<Int16>.size),
                    mData: monoBuffer
                )
            )

            status = ExtAudioFileWrite(output, frameCount, &writeList)
            guard status == noErr else { throw AudioError.failedToWrite(status) }
        }

        return monoURL
    }
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /Users/yashdesai/Codebase/Fun/Caddie && xcodebuild -project Caddie.xcodeproj -scheme CaddieTests -configuration Debug test 2>&1 | grep "Executed"
```

Expected: `Executed 9 tests, with 0 failures` (7 existing + 2 new)

- [ ] **Step 5: Commit**

```bash
git add Sources/Storage/AudioFileManager.swift Tests/MonoMixdownTests.swift
git commit -m "feat: add stereo-to-mono mixdown for ML pipeline input"
```

---

## Task 3: ASREngine — Token Grouping Logic + Tests

**Files:**
- Modify: `Sources/Transcription/ASREngine.swift`
- Create: `Tests/ASREngineTests.swift`

**Context:** The ASREngine needs a `groupTokensIntoSegments` method that converts FluidAudio's per-token `TokenTiming` array into our `ASRSegment` array. We test this logic independently using mock data — no FluidAudio dependency needed for the grouping algorithm itself. The actual FluidAudio wiring comes in the next task.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ASREngineTests.swift`:

```swift
import XCTest
@testable import Caddie

final class ASREngineTests: XCTestCase {

    func testGroupTokens_splitOnSentenceEnd() {
        // Two sentences: "Hello world." and "How are you?"
        let tokens: [(word: String, start: Double, end: Double)] = [
            ("Hello", 0.0, 0.3),
            (" world.", 0.3, 0.8),
            (" How", 1.0, 1.2),
            (" are", 1.2, 1.4),
            (" you?", 1.4, 1.8)
        ]

        let segments = ASREngine.groupTokensIntoSegments(tokens: tokens)

        XCTAssertEqual(segments.count, 2)

        XCTAssertEqual(segments[0].text, "Hello world.")
        XCTAssertEqual(segments[0].start, 0.0)
        XCTAssertEqual(segments[0].end, 0.8)
        XCTAssertEqual(segments[0].words.count, 2)

        XCTAssertEqual(segments[1].text, "How are you?")
        XCTAssertEqual(segments[1].start, 1.0)
        XCTAssertEqual(segments[1].end, 1.8)
        XCTAssertEqual(segments[1].words.count, 3)
    }

    func testGroupTokens_splitOnSilenceGap() {
        // Two phrases separated by 1.5s silence (> 0.8s threshold)
        let tokens: [(word: String, start: Double, end: Double)] = [
            ("First", 0.0, 0.5),
            (" phrase", 0.5, 1.0),
            (" Second", 2.5, 3.0),   // 1.5s gap from previous
            (" phrase", 3.0, 3.5)
        ]

        let segments = ASREngine.groupTokensIntoSegments(tokens: tokens)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "First phrase")
        XCTAssertEqual(segments[1].text, "Second phrase")
    }

    func testGroupTokens_splitOnMaxDuration() {
        // 40 tokens spanning 35 seconds — should split at ~30s
        var tokens: [(word: String, start: Double, end: Double)] = []
        for i in 0..<40 {
            let start = Double(i) * 0.875
            let end = start + 0.5
            tokens.append(("word\(i)", start, end))
        }

        let segments = ASREngine.groupTokensIntoSegments(tokens: tokens)

        XCTAssertGreaterThan(segments.count, 1)
        // No segment should exceed 30 seconds
        for segment in segments {
            XCTAssertLessThanOrEqual(segment.end - segment.start, 31.0)
        }
    }

    func testGroupTokens_emptyInput() {
        let segments = ASREngine.groupTokensIntoSegments(tokens: [])
        XCTAssertTrue(segments.isEmpty)
    }

    func testGroupTokens_singleToken() {
        let tokens: [(word: String, start: Double, end: Double)] = [
            ("Hello", 0.0, 0.5)
        ]

        let segments = ASREngine.groupTokensIntoSegments(tokens: tokens)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "Hello")
        XCTAssertEqual(segments[0].words.count, 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/yashdesai/Codebase/Fun/Caddie && xcodebuild -project Caddie.xcodeproj -scheme CaddieTests -configuration Debug test 2>&1 | grep -E "error:|FAIL|Executed"
```

Expected: Compilation error — `groupTokensIntoSegments` does not exist on `ASREngine`.

- [ ] **Step 3: Implement token grouping in ASREngine**

Replace the entire contents of `Sources/Transcription/ASREngine.swift`:

```swift
import Foundation

/// Automatic Speech Recognition engine.
/// Wraps FluidAudio's Parakeet ASR with token-to-segment grouping.
final class ASREngine {

    enum ASRError: Error, LocalizedError {
        case notInitialized
        case modelNotLoaded
        case transcriptionFailed(String)

        var errorDescription: String? {
            switch self {
            case .notInitialized: return "ASR engine not initialized"
            case .modelNotLoaded: return "ASR model not loaded"
            case .transcriptionFailed(let msg): return "Transcription failed: \(msg)"
            }
        }
    }

    private var isReady = false

    // FluidAudio objects will be stored here after initialization (Task 5)
    // private var asrManager: AsrManager?

    /// Initialize with downloaded models. Called once at app startup.
    func initialize() async throws {
        // TODO: Task 5 — wire FluidAudio AsrManager here
        isReady = true
    }

    /// Transcribe audio at the given URL. Returns segments, language, and duration.
    func transcribe(audioURL: URL) async throws -> (segments: [ASRSegment], language: String, duration: Double) {
        guard isReady else { throw ASRError.notInitialized }

        // TODO: Task 5 — call asrManager.transcribe(audioURL) and map results
        throw ASRError.transcriptionFailed("FluidAudio integration pending — see Task 5")
    }

    // MARK: - Token Grouping (Pure Logic — Tested Independently)

    /// Groups per-token timings into sentence-level ASRSegments.
    ///
    /// Splits on:
    /// - Sentence-ending punctuation (. ? !)
    /// - Silence gap > 0.8 seconds between tokens
    /// - Segment duration exceeding 30 seconds
    static func groupTokensIntoSegments(
        tokens: [(word: String, start: Double, end: Double)]
    ) -> [ASRSegment] {
        guard !tokens.isEmpty else { return [] }

        let silenceThreshold = 0.8
        let maxSegmentDuration = 30.0

        var segments: [ASRSegment] = []
        var currentWords: [WordTimestamp] = []
        var segmentStart: Double = tokens[0].start

        for (index, token) in tokens.enumerated() {
            let trimmedWord = token.word.trimmingCharacters(in: .whitespaces)
            currentWords.append(WordTimestamp(word: trimmedWord, start: token.start, end: token.end))

            let isLastToken = index == tokens.count - 1
            let endsWithPunctuation = trimmedWord.last.map { ".?!".contains($0) } ?? false
            let segmentDuration = token.end - segmentStart

            // Check silence gap to next token
            var silenceGap = false
            if !isLastToken {
                let gap = tokens[index + 1].start - token.end
                silenceGap = gap > silenceThreshold
            }

            let shouldSplit = isLastToken
                || endsWithPunctuation
                || silenceGap
                || segmentDuration >= maxSegmentDuration

            if shouldSplit && !currentWords.isEmpty {
                let text = currentWords.map(\.word).joined(separator: " ")
                segments.append(ASRSegment(
                    start: segmentStart,
                    end: token.end,
                    text: text,
                    words: currentWords
                ))
                currentWords = []
                if !isLastToken {
                    segmentStart = tokens[index + 1].start
                }
            }
        }

        return segments
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /Users/yashdesai/Codebase/Fun/Caddie && xcodebuild -project Caddie.xcodeproj -scheme CaddieTests -configuration Debug test 2>&1 | grep "Executed"
```

Expected: `Executed 14 tests, with 0 failures` (9 previous + 5 new)

- [ ] **Step 5: Commit**

```bash
git add Sources/Transcription/ASREngine.swift Tests/ASREngineTests.swift
git commit -m "feat: ASREngine token-to-segment grouping algorithm with tests"
```

---

## Task 4: DiarizationEngine — Output Mapping + Tests

**Files:**
- Modify: `Sources/Transcription/DiarizationEngine.swift`
- Create: `Tests/DiarizationEngineTests.swift`

**Context:** The DiarizationEngine needs a `mapTimelineToSegments` method that converts FluidAudio's `DiarizerTimeline` output into our flat `[SpeakerSegment]` array with normalized labels (SPEAKER_00, SPEAKER_01). We test this with mock data — no FluidAudio dependency for the mapping logic.

- [ ] **Step 1: Write the failing tests**

Create `Tests/DiarizationEngineTests.swift`:

```swift
import XCTest
@testable import Caddie

final class DiarizationEngineTests: XCTestCase {

    func testMapSegments_normalizesLabels() {
        // Input: "Speaker 0", "Speaker 1" → "SPEAKER_00", "SPEAKER_01"
        let input: [(speakerIndex: Int, startTime: Float, endTime: Float)] = [
            (0, 0.0, 5.0),
            (1, 5.0, 10.0),
            (0, 10.0, 15.0)
        ]

        let result = DiarizationEngine.mapToSpeakerSegments(rawSegments: input)

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].speaker, "SPEAKER_00")
        XCTAssertEqual(result[1].speaker, "SPEAKER_01")
        XCTAssertEqual(result[2].speaker, "SPEAKER_00")
    }

    func testMapSegments_sortedByStartTime() {
        // Input out of order
        let input: [(speakerIndex: Int, startTime: Float, endTime: Float)] = [
            (1, 5.0, 10.0),
            (0, 0.0, 5.0),
            (0, 10.0, 15.0)
        ]

        let result = DiarizationEngine.mapToSpeakerSegments(rawSegments: input)

        XCTAssertEqual(result[0].start, 0.0)
        XCTAssertEqual(result[1].start, 5.0)
        XCTAssertEqual(result[2].start, 10.0)
    }

    func testMapSegments_emptyInput() {
        let result = DiarizationEngine.mapToSpeakerSegments(rawSegments: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testMapSegments_floatToDoubleConversion() {
        let input: [(speakerIndex: Int, startTime: Float, endTime: Float)] = [
            (0, 1.5, 3.75)
        ]

        let result = DiarizationEngine.mapToSpeakerSegments(rawSegments: input)

        XCTAssertEqual(result[0].start, 1.5, accuracy: 0.001)
        XCTAssertEqual(result[0].end, 3.75, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/yashdesai/Codebase/Fun/Caddie && xcodebuild -project Caddie.xcodeproj -scheme CaddieTests -configuration Debug test 2>&1 | grep -E "error:|FAIL|Executed"
```

Expected: Compilation error — `mapToSpeakerSegments` does not exist.

- [ ] **Step 3: Implement output mapping in DiarizationEngine**

Replace the entire contents of `Sources/Transcription/DiarizationEngine.swift`:

```swift
import Foundation

/// Speaker diarization engine.
/// Wraps FluidAudio's SortformerDiarizer with output mapping.
final class DiarizationEngine {

    enum DiarizationError: Error, LocalizedError {
        case notInitialized
        case modelNotLoaded
        case diarizationFailed(String)

        var errorDescription: String? {
            switch self {
            case .notInitialized: return "Diarization engine not initialized"
            case .modelNotLoaded: return "Diarization model not loaded"
            case .diarizationFailed(let msg): return "Diarization failed: \(msg)"
            }
        }
    }

    private var isReady = false

    // FluidAudio objects will be stored here after initialization (Task 5)
    // private var diarizer: SortformerDiarizer?

    /// Initialize with downloaded models. Called once at app startup.
    func initialize() async throws {
        // TODO: Task 5 — wire FluidAudio SortformerDiarizer here
        isReady = true
    }

    /// Run diarization on a mono audio file. Returns speaker segments sorted by start time.
    func diarize(audioURL: URL) async throws -> [SpeakerSegment] {
        guard isReady else { throw DiarizationError.notInitialized }

        // TODO: Task 5 — call diarizer.processComplete and map results
        throw DiarizationError.diarizationFailed("FluidAudio integration pending — see Task 5")
    }

    // MARK: - Output Mapping (Pure Logic — Tested Independently)

    /// Maps raw diarizer output to our SpeakerSegment type.
    /// Normalizes speaker labels: "Speaker 0" → "SPEAKER_00"
    /// Sorts by start time.
    static func mapToSpeakerSegments(
        rawSegments: [(speakerIndex: Int, startTime: Float, endTime: Float)]
    ) -> [SpeakerSegment] {
        rawSegments
            .map { seg in
                SpeakerSegment(
                    start: Double(seg.startTime),
                    end: Double(seg.endTime),
                    speaker: String(format: "SPEAKER_%02d", seg.speakerIndex)
                )
            }
            .sorted { $0.start < $1.start }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /Users/yashdesai/Codebase/Fun/Caddie && xcodebuild -project Caddie.xcodeproj -scheme CaddieTests -configuration Debug test 2>&1 | grep "Executed"
```

Expected: `Executed 18 tests, with 0 failures` (14 previous + 4 new)

- [ ] **Step 5: Commit**

```bash
git add Sources/Transcription/DiarizationEngine.swift Tests/DiarizationEngineTests.swift
git commit -m "feat: DiarizationEngine output mapping with speaker label normalization"
```

---

## Task 5: Wire FluidAudio SDK into ASREngine + DiarizationEngine

**Files:**
- Modify: `Sources/Transcription/ASREngine.swift` (wire FluidAudio calls)
- Modify: `Sources/Transcription/DiarizationEngine.swift` (wire FluidAudio calls)

**Context:** Now we connect the real FluidAudio SDK calls. The `initialize()` and `transcribe()`/`diarize()` methods get their real implementations. The grouping/mapping logic from Tasks 3-4 is already tested — here we just wire it to FluidAudio's output.

**Important:** This task requires `import FluidAudio`. If the FluidAudio API differs from what was documented in the spec (method names, parameter types), adapt accordingly — the spec is based on research, not guaranteed to be exact. The key contract is: call FluidAudio → get results → map to our types using the tested functions.

- [ ] **Step 1: Wire FluidAudio into ASREngine**

Update `Sources/Transcription/ASREngine.swift`. Add `import FluidAudio` at the top. Replace the commented-out placeholders:

```swift
import Foundation
import FluidAudio

final class ASREngine {

    enum ASRError: Error, LocalizedError {
        case notInitialized
        case modelNotLoaded
        case transcriptionFailed(String)

        var errorDescription: String? {
            switch self {
            case .notInitialized: return "ASR engine not initialized"
            case .modelNotLoaded: return "ASR model not loaded"
            case .transcriptionFailed(let msg): return "Transcription failed: \(msg)"
            }
        }
    }

    private var asrManager: AsrManager?
    private var isReady = false

    /// Initialize with downloaded ASR models. Called once at app startup.
    func initialize(models: AsrModels) async throws {
        let manager = AsrManager(config: .default)
        try await manager.initialize(models: models)
        self.asrManager = manager
        isReady = true
    }

    /// Transcribe audio at the given URL. Returns segments, language, and duration.
    func transcribe(audioURL: URL) async throws -> (segments: [ASRSegment], language: String, duration: Double) {
        guard isReady, let manager = asrManager else { throw ASRError.notInitialized }

        do {
            let result = try await manager.transcribe(audioURL)

            // Map TokenTiming to our tuple format for the grouping function
            let tokens: [(word: String, start: Double, end: Double)] = (result.tokenTimings ?? []).map { timing in
                (word: timing.token, start: timing.startTime, end: timing.endTime)
            }

            let segments = Self.groupTokensIntoSegments(tokens: tokens)

            // If no token timings, create a single segment from the full text
            let finalSegments: [ASRSegment]
            if segments.isEmpty && !result.text.isEmpty {
                finalSegments = [ASRSegment(
                    start: 0,
                    end: result.duration,
                    text: result.text
                )]
            } else {
                finalSegments = segments
            }

            return (
                segments: finalSegments,
                language: "en",  // FluidAudio ASRResult may expose language — adapt if available
                duration: result.duration
            )
        } catch let error as ASRError {
            throw error
        } catch {
            throw ASRError.transcriptionFailed(error.localizedDescription)
        }
    }

    // MARK: - Token Grouping (Pure Logic — Tested Independently)

    /// Groups per-token timings into sentence-level ASRSegments.
    static func groupTokensIntoSegments(
        tokens: [(word: String, start: Double, end: Double)]
    ) -> [ASRSegment] {
        guard !tokens.isEmpty else { return [] }

        let silenceThreshold = 0.8
        let maxSegmentDuration = 30.0

        var segments: [ASRSegment] = []
        var currentWords: [WordTimestamp] = []
        var segmentStart: Double = tokens[0].start

        for (index, token) in tokens.enumerated() {
            let trimmedWord = token.word.trimmingCharacters(in: .whitespaces)
            currentWords.append(WordTimestamp(word: trimmedWord, start: token.start, end: token.end))

            let isLastToken = index == tokens.count - 1
            let endsWithPunctuation = trimmedWord.last.map { ".?!".contains($0) } ?? false
            let segmentDuration = token.end - segmentStart

            var silenceGap = false
            if !isLastToken {
                let gap = tokens[index + 1].start - token.end
                silenceGap = gap > silenceThreshold
            }

            let shouldSplit = isLastToken
                || endsWithPunctuation
                || silenceGap
                || segmentDuration >= maxSegmentDuration

            if shouldSplit && !currentWords.isEmpty {
                let text = currentWords.map(\.word).joined(separator: " ")
                segments.append(ASRSegment(
                    start: segmentStart,
                    end: token.end,
                    text: text,
                    words: currentWords
                ))
                currentWords = []
                if !isLastToken {
                    segmentStart = tokens[index + 1].start
                }
            }
        }

        return segments
    }
}
```

- [ ] **Step 2: Wire FluidAudio into DiarizationEngine**

Update `Sources/Transcription/DiarizationEngine.swift`. Add `import FluidAudio`:

```swift
import Foundation
import FluidAudio

final class DiarizationEngine {

    enum DiarizationError: Error, LocalizedError {
        case notInitialized
        case modelNotLoaded
        case diarizationFailed(String)

        var errorDescription: String? {
            switch self {
            case .notInitialized: return "Diarization engine not initialized"
            case .modelNotLoaded: return "Diarization model not loaded"
            case .diarizationFailed(let msg): return "Diarization failed: \(msg)"
            }
        }
    }

    private var diarizer: SortformerDiarizer?
    private var isReady = false

    /// Initialize with a pre-created SortformerDiarizer. Called once at app startup.
    func initialize(diarizer: SortformerDiarizer) async throws {
        self.diarizer = diarizer
        isReady = true
    }

    /// Run diarization on a mono audio file. Returns speaker segments sorted by start time.
    func diarize(audioURL: URL) async throws -> [SpeakerSegment] {
        guard isReady, let diarizer = diarizer else { throw DiarizationError.notInitialized }

        do {
            let timeline = try diarizer.processComplete(
                audioFileURL: audioURL,
                keepingEnrolledSpeakers: nil,
                finalizeOnCompletion: true,
                progressCallback: nil
            )

            // Collect all finalized segments from all speakers
            var rawSegments: [(speakerIndex: Int, startTime: Float, endTime: Float)] = []
            for (index, speaker) in timeline.speakers {
                for segment in speaker.finalizedSegments {
                    rawSegments.append((
                        speakerIndex: index,
                        startTime: segment.startTime,
                        endTime: segment.endTime
                    ))
                }
            }

            let result = Self.mapToSpeakerSegments(rawSegments: rawSegments)

            // Reset diarizer state for next job
            diarizer.reset()

            return result
        } catch let error as DiarizationError {
            throw error
        } catch {
            throw DiarizationError.diarizationFailed(error.localizedDescription)
        }
    }

    // MARK: - Output Mapping (Pure Logic — Tested Independently)

    static func mapToSpeakerSegments(
        rawSegments: [(speakerIndex: Int, startTime: Float, endTime: Float)]
    ) -> [SpeakerSegment] {
        rawSegments
            .map { seg in
                SpeakerSegment(
                    start: Double(seg.startTime),
                    end: Double(seg.endTime),
                    speaker: String(format: "SPEAKER_%02d", seg.speakerIndex)
                )
            }
            .sorted { $0.start < $1.start }
    }
}
```

- [ ] **Step 3: Build to verify FluidAudio imports resolve**

```bash
cd /Users/yashdesai/Codebase/Fun/Caddie && xcodebuild -project Caddie.xcodeproj -scheme Caddie -configuration Debug build 2>&1 | tail -3
```

Expected: `BUILD SUCCEEDED`

If FluidAudio's API differs from the spec (different method names, parameter signatures), adapt the code to match the actual SDK API. The key contract: initialize with models → transcribe/diarize a file URL → map output to our types.

- [ ] **Step 4: Run all tests**

```bash
cd /Users/yashdesai/Codebase/Fun/Caddie && xcodebuild -project Caddie.xcodeproj -scheme CaddieTests -configuration Debug test 2>&1 | grep "Executed"
```

Expected: `Executed 18 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/Transcription/ASREngine.swift Sources/Transcription/DiarizationEngine.swift
git commit -m "feat: wire FluidAudio SDK into ASR and diarization engines"
```

---

## Task 6: ModelManager — FluidAudio Download Coordinator

**Files:**
- Modify: `Sources/Models/ModelManager.swift`

**Context:** Replace the stub ModelManager with a thin coordinator that calls FluidAudio's built-in download APIs and exposes progress to the UI. FluidAudio handles caching automatically. We delete the old `modelsDirectory`, `modelsReady` computed property, and `verifyModels()` method — they checked local directories that FluidAudio doesn't use.

- [ ] **Step 1: Replace ModelManager implementation**

Replace the entire contents of `Sources/Models/ModelManager.swift`:

```swift
import Foundation
import os
import Observation
import FluidAudio

@Observable
final class ModelManager {
    var isDownloading = false
    var downloadProgress: Double = 0
    var downloadError: String?
    var modelsReady = false

    private(set) var asrModels: AsrModels?
    private(set) var diarizer: SortformerDiarizer?

    private let logger = Logger(subsystem: "com.caddie.app", category: "ModelManager")

    /// Downloads and loads ASR + diarization models via FluidAudio.
    /// Models are cached by FluidAudio after first download.
    /// Safe to call multiple times — returns immediately if already downloaded.
    func downloadModelsIfNeeded() async {
        guard !modelsReady else {
            logger.info("Models already loaded")
            return
        }

        isDownloading = true
        downloadProgress = 0
        downloadError = nil

        do {
            // Step 1: Download ASR models (~60% of total)
            logger.info("Downloading ASR models...")
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            asrModels = models
            downloadProgress = 0.6
            logger.info("ASR models downloaded and loaded")

            // Step 2: Initialize Sortformer diarizer (~40% of total)
            logger.info("Initializing diarizer...")
            let sortformer = SortformerDiarizer(
                config: .default,
                timelineConfig: .sortformerDefault
            )
            // SortformerDiarizer downloads models during initialize if needed
            try await sortformer.initialize()
            diarizer = sortformer
            downloadProgress = 1.0
            logger.info("Diarizer initialized")

            modelsReady = true
        } catch {
            downloadError = error.localizedDescription
            logger.error("Model download failed: \(error.localizedDescription)")
        }

        isDownloading = false
    }
}
```

**Note on SortformerDiarizer initialization:** The spec says `initialize(mainModelPath:)` but FluidAudio may use a different method signature (e.g., `initialize()` with no args if models auto-download). Adapt to match the actual SDK API. Check FluidAudio docs or source if the call fails.

- [ ] **Step 2: Build to verify**

```bash
cd /Users/yashdesai/Codebase/Fun/Caddie && xcodebuild -project Caddie.xcodeproj -scheme Caddie -configuration Debug build 2>&1 | tail -3
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Run all tests**

```bash
cd /Users/yashdesai/Codebase/Fun/Caddie && xcodebuild -project Caddie.xcodeproj -scheme CaddieTests -configuration Debug test 2>&1 | grep "Executed"
```

Expected: `Executed 18 tests, with 0 failures`

- [ ] **Step 4: Commit**

```bash
git add Sources/Models/ModelManager.swift
git commit -m "feat: ModelManager delegates to FluidAudio for model download and caching"
```

---

## Task 7: TranscriptionPipeline — Dependency Injection + Mono Mixdown + WAV Cleanup

**Files:**
- Modify: `Sources/Transcription/TranscriptionPipeline.swift`

**Context:** Three changes: (1) Accept injected engines via initializer instead of creating them inline. (2) Add mono mixdown step before ASR/diarization. (3) Delete stereo WAV after status is set to `.done`. The pipeline's job queue and error handling stay the same.

- [ ] **Step 1: Update TranscriptionPipeline**

Replace the entire contents of `Sources/Transcription/TranscriptionPipeline.swift`:

```swift
import Foundation
import os

/// Queued actor that processes transcription jobs one at a time.
/// Pipeline: Mono Mixdown -> ASR -> Diarize -> Merge -> Write DB -> Compress -> Done -> Delete WAV
actor TranscriptionPipeline {

    private let logger = Logger(subsystem: "com.caddie.app", category: "TranscriptionPipeline")

    private let asrEngine: ASREngine
    private let diarizationEngine: DiarizationEngine

    private var queue: [(meetingId: String, database: AppDatabase?)] = []
    private var isProcessing = false

    init(asr: ASREngine, diarization: DiarizationEngine) {
        self.asrEngine = asr
        self.diarizationEngine = diarization
    }

    /// Enqueues a meeting for transcription processing.
    func enqueue(meetingId: String, database: AppDatabase? = nil) {
        queue.append((meetingId, database))
        logger.info("Enqueued meeting \(meetingId) for transcription (queue depth: \(self.queue.count))")

        if !isProcessing {
            Task { await processNext() }
        }
    }

    // MARK: - Private

    private func processNext() async {
        guard !isProcessing, !queue.isEmpty else { return }

        isProcessing = true
        let job = queue.removeFirst()
        let meetingId = job.meetingId
        let database = job.database

        logger.info("Starting transcription pipeline for meeting \(meetingId)")
        let startTime = CFAbsoluteTimeGetCurrent()

        // Update status to transcribing
        await updateMeetingStatus(meetingId: meetingId, status: .transcribing, database: database)

        do {
            let wavURL = AudioFileManager.wavPath(for: meetingId)

            // Step 1: Create mono mixdown
            logger.info("[\(meetingId)] Creating mono mixdown...")
            let monoURL = try AudioFileManager.createMonoMixdown(stereoURL: wavURL)
            logger.info("[\(meetingId)] Mono mixdown created")

            defer {
                // Clean up temp mono file after ASR + diarization
                try? FileManager.default.removeItem(at: monoURL)
            }

            // Step 2: ASR
            logger.info("[\(meetingId)] Running ASR...")
            let (asrSegments, language, duration) = try await asrEngine.transcribe(audioURL: monoURL)
            logger.info("[\(meetingId)] ASR complete: \(asrSegments.count) segments, language=\(language)")

            // Step 3: Diarization
            logger.info("[\(meetingId)] Running diarization...")
            let speakerSegments = try await diarizationEngine.diarize(audioURL: monoURL)
            logger.info("[\(meetingId)] Diarization complete: \(speakerSegments.count) speaker segments")

            // Step 4: Merge
            let merged = TranscriptMerger.merge(asr: asrSegments, speakers: speakerSegments)
            let fullText = TranscriptMerger.generateFullText(segments: merged)
            let uniqueSpeakers = Set(merged.map(\.speaker)).count

            let processingTime = CFAbsoluteTimeGetCurrent() - startTime
            let transcript = Transcript(
                language: language,
                duration: duration,
                numSegments: merged.count,
                numSpeakers: uniqueSpeakers,
                processingTimeSeconds: processingTime,
                fullText: fullText,
                segments: merged
            )

            logger.info("[\(meetingId)] Transcript merged: \(transcript.numSegments) segments, \(transcript.numSpeakers) speakers")

            // Step 5: Write transcript JSON to DB
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let transcriptJSON = try encoder.encode(transcript)
            let transcriptString = String(data: transcriptJSON, encoding: .utf8)

            if let db = database {
                try await db.dbWriter.write { dbConn in
                    try dbConn.execute(
                        sql: "UPDATE meetings SET transcript = ? WHERE meeting_id = ?",
                        arguments: [transcriptString, meetingId]
                    )
                }
            }

            // Step 6: Compress WAV to ALAC
            logger.info("[\(meetingId)] Compressing to ALAC...")
            let alacURL = AudioFileManager.alacPath(for: meetingId)
            try AudioFileManager.compressToALAC(wavURL: wavURL, outputURL: alacURL)
            logger.info("[\(meetingId)] ALAC compression complete")

            // Step 7: Update status to done
            await updateMeetingStatus(meetingId: meetingId, status: .done, database: database)

            // Step 8: Delete stereo WAV (AFTER status is .done so retry is still possible on failure)
            try? FileManager.default.removeItem(at: wavURL)
            logger.info("[\(meetingId)] Stereo WAV deleted")

            logger.info("[\(meetingId)] Pipeline complete in \(String(format: "%.1f", processingTime))s")

        } catch {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            logger.error("[\(meetingId)] Pipeline failed after \(String(format: "%.1f", elapsed))s: \(error.localizedDescription)")

            // Update status to error with message
            if let db = database {
                do {
                    try await db.dbWriter.write { dbConn in
                        try dbConn.execute(
                            sql: "UPDATE meetings SET status = ?, error = ? WHERE meeting_id = ?",
                            arguments: [MeetingStatus.error.rawValue, error.localizedDescription, meetingId]
                        )
                    }
                } catch {
                    logger.error("[\(meetingId)] Failed to write error status to DB: \(error.localizedDescription)")
                }
            }
        }

        isProcessing = false

        // Process next in queue
        if !queue.isEmpty {
            await processNext()
        }
    }

    private func updateMeetingStatus(meetingId: String, status: MeetingStatus, database: AppDatabase?) async {
        guard let db = database else { return }
        do {
            try await db.dbWriter.write { dbConn in
                try dbConn.execute(
                    sql: "UPDATE meetings SET status = ? WHERE meeting_id = ?",
                    arguments: [status.rawValue, meetingId]
                )
            }
        } catch {
            logger.error("[\(meetingId)] Failed to update status to \(status.rawValue): \(error.localizedDescription)")
        }
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
cd /Users/yashdesai/Codebase/Fun/Caddie && xcodebuild -project Caddie.xcodeproj -scheme Caddie -configuration Debug build 2>&1 | tail -5
```

Expected: Build will fail because `AppState.swift` still creates `TranscriptionPipeline()` with no args. That's fixed in Task 8. For now, verify the pipeline file itself compiles by checking for errors only in the pipeline file:

```bash
cd /Users/yashdesai/Codebase/Fun/Caddie && xcodebuild -project Caddie.xcodeproj -scheme Caddie -configuration Debug build 2>&1 | grep "TranscriptionPipeline.swift.*error"
```

Expected: No errors in TranscriptionPipeline.swift. Errors in AppState.swift are expected (fixed next task).

- [ ] **Step 3: Commit (will be buildable after Task 8)**

```bash
git add Sources/Transcription/TranscriptionPipeline.swift
git commit -m "feat: pipeline DI, mono mixdown step, WAV cleanup after transcription"
```

---

## Task 8: AppState — Async Initialization + Engine Wiring

**Files:**
- Modify: `Sources/App/AppState.swift`
- Modify: `Sources/UI/MainWindow/ContentView.swift` (update `.task` call)

**Context:** `AppState.initialize()` becomes `async`. It now: (1) creates ModelManager and downloads models, (2) initializes ASR + diarization engines with downloaded models, (3) creates pipeline with injected engines. The `pipeline` property changes from an inline constant to a late-initialized optional. ContentView's `.task` already runs in an async context, but the call needs `await`.

- [ ] **Step 1: Update AppState**

Replace the entire contents of `Sources/App/AppState.swift`:

```swift
import SwiftUI
import Observation
import os

enum AppStatus: String {
    case idle
    case recording
    case transcribing
}

@Observable
final class AppState {
    var status: AppStatus = .idle
    var currentMeetingTitle: String?
    var recordingStartTime: Date?
    var transcriptionProgress: Double = 0
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    var recordingDuration: TimeInterval {
        guard let start = recordingStartTime else { return 0 }
        return Date().timeIntervalSince(start)
    }

    // MARK: - Engines

    private(set) var database: AppDatabase?
    private(set) var modelManager = ModelManager()
    private let detector = MeetingDetector()
    private let recorder = AudioRecorder()
    private var pipeline: TranscriptionPipeline?
    private var currentMeetingId: String?

    private let logger = Logger(subsystem: "com.caddie.app", category: "AppState")

    var isInitialized = false
    var initError: String?

    // MARK: - Lifecycle

    func initialize() async {
        guard !isInitialized else { return }
        do {
            database = try AppDatabase()
            try AudioFileManager.ensureDirectoryExists()

            // 1. Download models (FluidAudio handles caching — instant if already downloaded)
            await modelManager.downloadModelsIfNeeded()

            if let downloadError = modelManager.downloadError {
                initError = "Model download failed: \(downloadError)"
                logger.error("Model download failed: \(downloadError)")
                return
            }

            // 2. Initialize ASR engine
            let asrEngine = ASREngine()
            if let asrModels = modelManager.asrModels {
                try await asrEngine.initialize(models: asrModels)
            }

            // 3. Initialize diarization engine
            let diarizationEngine = DiarizationEngine()
            if let diarizer = modelManager.diarizer {
                try await diarizationEngine.initialize(diarizer: diarizer)
            }

            // 4. Create pipeline with injected engines
            pipeline = TranscriptionPipeline(asr: asrEngine, diarization: diarizationEngine)

            // 5. Start detection
            detector.onMeetingStarted = { [weak self] meeting in
                self?.startRecording(meeting: meeting)
            }
            detector.onMeetingEnded = { [weak self] in
                self?.stopRecording()
            }
            detector.start()

            isInitialized = true
            logger.info("AppState initialized with ML pipeline")
        } catch {
            initError = error.localizedDescription
            logger.error("Failed to initialize: \(error.localizedDescription)")
        }
    }

    func retryTranscription(meetingId: String) {
        let wavURL = AudioFileManager.wavPath(for: meetingId)
        guard FileManager.default.fileExists(atPath: wavURL.path) else {
            if let db = database {
                do {
                    try db.dbWriter.write { dbConn in
                        try dbConn.execute(
                            sql: "UPDATE meetings SET status = ?, error = ? WHERE meeting_id = ?",
                            arguments: [MeetingStatus.error.rawValue, "Audio file not found", meetingId]
                        )
                    }
                } catch {
                    logger.error("Failed to update meeting error: \(error.localizedDescription)")
                }
            }
            return
        }
        if let db = database {
            do {
                try db.dbWriter.write { dbConn in
                    try dbConn.execute(
                        sql: "UPDATE meetings SET status = ?, error = NULL WHERE meeting_id = ?",
                        arguments: [MeetingStatus.transcribing.rawValue, meetingId]
                    )
                }
            } catch {
                logger.error("Failed to update meeting for retry: \(error.localizedDescription)")
            }
        }
        let db = database
        guard let pipeline = pipeline else {
            logger.error("Cannot retry transcription — pipeline not initialized")
            return
        }
        Task { await pipeline.enqueue(meetingId: meetingId, database: db) }
    }

    func shutdown() {
        detector.stop()
        if status == .recording {
            stopRecording()
        }
        logger.info("AppState shut down")
    }

    // MARK: - Recording Lifecycle

    private func startRecording(meeting: DetectedMeeting) {
        let meetingId = String(UUID().uuidString.prefix(12)).lowercased()
        currentMeetingId = meetingId
        currentMeetingTitle = meeting.title
        recordingStartTime = Date()
        status = .recording

        let now = ISO8601DateFormatter().string(from: Date())
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = dateFormatter.string(from: Date())

        var record = Meeting(
            meetingId: meetingId,
            title: meeting.title,
            app: meeting.app,
            date: today,
            startTime: now,
            status: .recording
        )
        record.audioFile = "\(meetingId).m4a"

        if let db = database {
            do {
                try db.dbWriter.write { dbConn in
                    try record.insert(dbConn)
                }
                logger.info("Created meeting record: \(meetingId)")
            } catch {
                logger.error("Failed to insert meeting record: \(error.localizedDescription)")
            }
        }

        let wavPath = AudioFileManager.wavPath(for: meetingId)
        do {
            try recorder.start(outputPath: wavPath, processID: meeting.processId)
            logger.info("Recording started for meeting \(meetingId)")
        } catch {
            logger.error("Failed to start recording: \(error.localizedDescription)")
        }
    }

    func stopRecording() {
        recorder.stop()
        guard let meetingId = currentMeetingId else { return }

        let duration = Int(Date().timeIntervalSince(recordingStartTime ?? Date()))
        let endTime = ISO8601DateFormatter().string(from: Date())

        if let db = database {
            do {
                try db.dbWriter.write { dbConn in
                    try dbConn.execute(
                        sql: """
                            UPDATE meetings
                            SET end_time = ?, duration_seconds = ?, status = ?
                            WHERE meeting_id = ?
                            """,
                        arguments: [endTime, duration, MeetingStatus.transcribing.rawValue, meetingId]
                    )
                }
            } catch {
                logger.error("Failed to update meeting status to transcribing: \(error.localizedDescription)")
            }
        }

        status = .transcribing
        logger.info("Recording stopped for meeting \(meetingId), enqueuing transcription")

        let db = database
        guard let pipeline = pipeline else {
            logger.error("Cannot enqueue transcription — pipeline not initialized")
            return
        }
        Task { await pipeline.enqueue(meetingId: meetingId, database: db) }

        recordingStartTime = nil
        currentMeetingId = nil
    }
}
```

- [ ] **Step 2: Update ContentView to use `await`**

In `Sources/UI/MainWindow/ContentView.swift`, make two changes:

**Change 1:** In the `.task` modifier (~line 25), add `await`:

```swift
        .task {
            await appState.initialize()
        }
```

**Change 2:** In the `initErrorView` method (~line 38), the retry button also calls `initialize()`. Wrap it in a Task since button actions are synchronous:

```swift
            Button("Retry") {
                appState.initError = nil
                Task { await appState.initialize() }
            }
```

- [ ] **Step 3: Build to verify**

```bash
cd /Users/yashdesai/Codebase/Fun/Caddie && xcodebuild -project Caddie.xcodeproj -scheme Caddie -configuration Debug build 2>&1 | tail -3
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Run all tests**

```bash
cd /Users/yashdesai/Codebase/Fun/Caddie && xcodebuild -project Caddie.xcodeproj -scheme CaddieTests -configuration Debug test 2>&1 | grep "Executed"
```

Expected: `Executed 18 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/App/AppState.swift Sources/UI/MainWindow/ContentView.swift
git commit -m "feat: async AppState initialization with model download and engine injection"
```

---

## Task 9: Onboarding — Model Download Step

**Files:**
- Modify: `Sources/UI/Onboarding/OnboardingView.swift`

**Context:** Add a model download step between permissions and "Get Started". Shows download progress with a progress bar. If download fails, shows error with retry. The download runs via `ModelManager` which is now on `AppState`.

- [ ] **Step 1: Update OnboardingView**

Replace the entire contents of `Sources/UI/Onboarding/OnboardingView.swift`:

```swift
import SwiftUI

struct OnboardingView: View {
    @Binding var isComplete: Bool
    @Environment(AppState.self) private var appState
    @State private var micStatus: PermissionStatus = Permissions.microphone
    @State private var screenStatus: PermissionStatus = Permissions.screenRecording
    @State private var accessibilityStatus: PermissionStatus = Permissions.accessibility
    @State private var isRequesting = false
    @State private var showModelDownload = false

    private var permissionsGranted: Bool {
        micStatus == .granted && accessibilityStatus == .granted
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "mic.badge.plus")
                .font(.system(size: 56, weight: .thin))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.orange)
                .padding(.bottom, 20)

            Text("Welcome to Caddie")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .padding(.bottom, 8)

            Text("Everything stays on your Mac.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 32)

            if showModelDownload {
                modelDownloadSection
            } else {
                permissionsSection
            }

            Spacer()
        }
        .padding(40)
        .frame(minWidth: 520, minHeight: 520)
        .onAppear { refreshStatuses() }
    }

    // MARK: - Permissions Section

    private var permissionsSection: some View {
        VStack(spacing: 0) {
            // Permission card
            VStack(spacing: 0) {
                permissionRow(title: "Microphone", description: "Record meeting audio", icon: "mic.fill", status: micStatus)
                Divider().padding(.leading, 44)
                permissionRow(title: "Accessibility", description: "Detect active meeting windows", icon: "hand.raised.fill", status: accessibilityStatus)
                Divider().padding(.leading, 44)
                permissionRow(title: "Screen Recording", description: "Capture system audio from meeting apps", icon: "rectangle.inset.filled.and.person.filled", status: screenStatus, isOptional: true)
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
            .frame(maxWidth: 400)
            .padding(.bottom, 24)

            if screenStatus != .granted {
                Text("Screen Recording is needed for system audio capture.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.bottom, 8)

                Button("Open System Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
                .font(.caption)
                .padding(.bottom, 16)
            }

            Button {
                if permissionsGranted {
                    showModelDownload = true
                    Task { await appState.modelManager.downloadModelsIfNeeded() }
                } else {
                    requestPermissions()
                }
            } label: {
                if isRequesting {
                    ProgressView().controlSize(.small)
                } else {
                    Text(permissionsGranted ? "Continue" : "Grant Permissions")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.large)
            .disabled(isRequesting)

            Button("Refresh") { refreshStatuses() }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
    }

    // MARK: - Model Download Section

    @ViewBuilder
    private var modelDownloadSection: some View {
        VStack(spacing: 16) {
            if let error = appState.modelManager.downloadError {
                // Error state
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundStyle(.red)

                Text("Download Failed")
                    .font(.headline)

                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 350)

                Button("Retry Download") {
                    Task { await appState.modelManager.downloadModelsIfNeeded() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.large)
            } else if appState.modelManager.modelsReady {
                // Done
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.green)

                Text("Models Ready")
                    .font(.headline)

                Button("Get Started") {
                    isComplete = true
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.large)
            } else {
                // Downloading
                Text("Downloading AI Models")
                    .font(.headline)

                Text("This is a one-time download (~1 GB).\nModels run entirely on your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                ProgressView(value: appState.modelManager.downloadProgress)
                    .frame(maxWidth: 300)
                    .padding(.vertical, 8)

                Text("\(Int(appState.modelManager.downloadProgress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: 400)
    }

    // MARK: - Helpers

    private func permissionRow(title: String, description: String, icon: String, status: PermissionStatus, isOptional: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(title).font(.body.bold())
                    if isOptional {
                        Text("(recommended)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            statusLabel(for: status)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func statusLabel(for status: PermissionStatus) -> some View {
        switch status {
        case .granted:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .denied:
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                Text("Denied")
            }
            .font(.caption)
            .foregroundStyle(.red)
        case .undetermined:
            Text("Not set")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func requestPermissions() {
        isRequesting = true
        Permissions.requestAccessibility()
        Task {
            _ = await Permissions.requestMicrophone()
            refreshStatuses()
            isRequesting = false
        }
    }

    private func refreshStatuses() {
        micStatus = Permissions.microphone
        screenStatus = Permissions.screenRecording
        accessibilityStatus = Permissions.accessibility
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
cd /Users/yashdesai/Codebase/Fun/Caddie && xcodebuild -project Caddie.xcodeproj -scheme Caddie -configuration Debug build 2>&1 | tail -3
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Run all tests**

```bash
cd /Users/yashdesai/Codebase/Fun/Caddie && xcodebuild -project Caddie.xcodeproj -scheme CaddieTests -configuration Debug test 2>&1 | grep "Executed"
```

Expected: `Executed 18 tests, with 0 failures`

- [ ] **Step 4: Commit**

```bash
git add Sources/UI/Onboarding/OnboardingView.swift
git commit -m "feat: onboarding model download step with progress and error handling"
```

---

## Task 10: Final Verification — Full Build + All Tests

**Files:** None (verification only)

**Context:** All code changes are done. Run a clean build and full test suite to verify everything works together.

- [ ] **Step 1: Regenerate Xcode project**

```bash
cd /Users/yashdesai/Codebase/Fun/Caddie && xcodegen generate
```

Expected: `Generated project Caddie.xcodeproj`

- [ ] **Step 2: Clean build**

```bash
cd /Users/yashdesai/Codebase/Fun/Caddie && xcodebuild -project Caddie.xcodeproj -scheme Caddie -configuration Debug clean build 2>&1 | tail -3
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Run all tests**

```bash
cd /Users/yashdesai/Codebase/Fun/Caddie && xcodebuild -project Caddie.xcodeproj -scheme CaddieTests -configuration Debug test 2>&1 | grep "Executed"
```

Expected: `Executed 18 tests, with 0 failures` (7 original + 2 mixdown + 5 ASR + 4 diarization)

- [ ] **Step 4: Verify git status is clean**

```bash
cd /Users/yashdesai/Codebase/Fun/Caddie && git status
```

Expected: All changes committed across Tasks 1-9.

- [ ] **Step 5: Review the change summary**

```bash
cd /Users/yashdesai/Codebase/Fun/Caddie && git log --oneline -10
```

Expected commits (newest first):
```
feat: onboarding model download step with progress and error handling
feat: async AppState initialization with model download and engine injection
feat: pipeline DI, mono mixdown step, WAV cleanup after transcription
feat: ModelManager delegates to FluidAudio for model download and caching
feat: wire FluidAudio SDK into ASR and diarization engines
feat: DiarizationEngine output mapping with speaker label normalization
feat: ASREngine token-to-segment grouping algorithm with tests
feat: add stereo-to-mono mixdown for ML pipeline input
feat: add FluidAudio SPM dependency for on-device ML inference
```
