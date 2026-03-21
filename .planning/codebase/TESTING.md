# Testing Patterns

**Analysis Date:** 2026-03-22

## Test Framework

**Runner:**
- XCTest (native Swift testing framework)
- Tests integrated into Xcode project as `CaddieTests` target
- Run via `xcodebuild test -scheme Caddie`

**Assertion Library:**
- XCTest assertions: `XCTAssertEqual()`, `XCTAssertNotNil()`, `XCTAssertTrue()`, etc.
- No external assertion library used

**Run Commands:**
```bash
# Run all tests (from Xcode or via xcodebuild)
xcodebuild test -scheme Caddie

# Run specific test class
xcodebuild test -scheme Caddie -testClassPattern FormattersTests

# Run with output (verbose)
xcodebuild test -scheme Caddie -verbose
```

## Test File Organization

**Location:**
- Separate directory: `/Tests/` at project root
- Mirror of production structure NOT enforced; tests grouped by functionality
- Test files co-located in single directory

**Naming:**
- Pattern: `*Tests.swift` (e.g., `FormattersTests.swift`, `ASREngineTests.swift`)
- Test classes named `final class [Name]Tests: XCTestCase`

**Structure:**
```
Tests/
├── TranscriptMergerTests.swift
├── MeetingModelTests.swift
├── ASREngineTests.swift
├── DiarizationEngineTests.swift
├── MonoMixdownTests.swift
├── FormattersTests.swift
├── MeetingDetectorTests.swift
├── MeetingPatternsTests.swift
├── ExportTests.swift
└── CaddieTests.swift
```

## Test Structure

**Suite Organization:**
```swift
final class FormattersTests: XCTestCase {
    // MARK: - duration(seconds:)

    func testDurationMinutesOnly() {
        XCTAssertEqual(Formatters.duration(seconds: 0), "0m")
        XCTAssertEqual(Formatters.duration(seconds: 60), "1m")
    }

    func testDurationHoursAndMinutes() {
        XCTAssertEqual(Formatters.duration(seconds: 3600), "1h")
    }

    // MARK: - time(from:)

    func testTimeFromISO8601() {
        let result = Formatters.time(from: "2026-03-19T14:45:00Z")
        XCTAssertNotNil(result)
    }
}
```

**Patterns:**
- **Setup:** `override func setUp()` for shared test initialization (e.g., creating temporary directories)
- **Teardown:** `override func tearDown()` for cleanup (e.g., deleting test files)
- **Shared state:** Test properties like `var db: AppDatabase!` for database tests
- **MARK sections:** Group tests by function under `// MARK: - FunctionName`

**Example from `MonoMixdownTests.swift`:**
```swift
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
        let stereoURL = tempDir.appendingPathComponent("stereo.wav")
        try createStereoWAV(at: stereoURL, leftSamples: [1000, 3000], rightSamples: [2000, 4000])

        let monoURL = try AudioFileManager.createMonoMixdown(stereoURL: stereoURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: monoURL.path))
        try? FileManager.default.removeItem(at: monoURL)
    }
}
```

## Mocking

**Framework:** No mocking library used; dependency injection and pure functions preferred

**Patterns:**
- **Pure function testing:** Logic functions (e.g., `ASREngine.groupTokensIntoSegments()`) tested directly with arrays of test data
- **Dependency injection:** Engines created with injected dependencies in tests
- **Test doubles:** In-memory database (`AppDatabase(inMemory: true)`) for persistence tests

**Example from `ASREngineTests.swift` (pure function):**
```swift
func testGroupTokens_splitOnSentenceEnd() {
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
}
```

**Example from `MeetingModelTests.swift` (in-memory database):**
```swift
final class MeetingModelTests: XCTestCase {
    var db: AppDatabase!

    override func setUpWithError() throws {
        db = try AppDatabase(inMemory: true)
    }

    func testCreateAndFetchMeeting() throws {
        var meeting = Meeting(
            title: "Standup",
            date: "2026-03-19",
            startTime: "2026-03-19T09:00:00Z"
        )

        try db.dbWriter.write { dbConn in
            try meeting.insert(dbConn)
        }

        XCTAssertNotNil(meeting.id)
    }
}
```

**What to Mock:**
- Avoid mocking; prefer pure functions and dependency injection
- Use test doubles (in-memory databases, fixture data)

**What NOT to Mock:**
- Production services (ASR, diarization) — use pure logic testing instead
- File system operations — use temporary directories in test

## Fixtures and Factories

**Test Data:**
- Inline test data defined in test function scope
- Tuples and arrays used directly (e.g., test token arrays, signal arrays)
- Immutable test Meeting objects created with default parameters

**Example from `MeetingDetectorTests.swift`:**
```swift
let signals = [
    DetectionSignal(
        source: .audioProcess,
        appName: "Zoom",
        processId: 1234,
        windowTitle: nil,
        calendarEvent: nil,
        isActive: true
    ),
    DetectionSignal(
        source: .micState,
        appName: nil,
        processId: nil,
        windowTitle: nil,
        calendarEvent: nil,
        isActive: true
    ),
]
let result = engine.evaluate(signals: signals)
```

**Location:**
- Test data defined within test functions (no separate fixture files)
- Helper methods for complex data creation (e.g., `createStereoWAV()` in `MonoMixdownTests.swift`)

## Coverage

**Requirements:** None explicitly enforced; quality driven by code review

**View Coverage:**
```bash
# Coverage reports generated by Xcode via Product > Scheme > Edit Scheme > Test > Options > Code Coverage
# Reports visible in Xcode's Coverage navigator
```

## Test Types

**Unit Tests:**
- **Scope:** Pure functions and isolated classes
- **Approach:** Verify logic correctness with various inputs (happy path, edge cases, empty input)
- **Examples:** `FormattersTests`, `ASREngineTests.testGroupTokens_*`, `DiarizationEngineTests.testMapSegments_*`

**Integration Tests:**
- **Scope:** Multi-component flows with database and file I/O
- **Approach:** Test data persistence, signal evaluation, meeting detection logic
- **Examples:** `MeetingModelTests` (database + Meeting model), `MeetingDetectorTests` (signal aggregation)

**E2E Tests:**
- **Framework:** Not used
- **Reasoning:** Interactive app; E2E testing would require UI automation

## Common Patterns

**Async Testing:**
```swift
// Not heavily used in current test suite; async patterns mostly in production code
// If needed, use async Task:
func testAsyncOperation() async throws {
    let result = try await someAsyncFunction()
    XCTAssertNotNil(result)
}
```

**Error Testing:**
```swift
// Test that throws is expected
func testCreateAndFetchMeeting() throws {
    var meeting = Meeting(...)
    try db.dbWriter.write { dbConn in
        try meeting.insert(dbConn)
    }
    // Assertion verifies success
    XCTAssertNotNil(meeting.id)
}

// Test that error is thrown
func testInvalidInput() throws {
    let invalidData = "not-a-date"
    let result = Formatters.dateLabel(from: invalidData)
    XCTAssertEqual(result, "not-a-date")  // Falls back to input
}
```

**Property-based assertions:**
```swift
// Verify ranges rather than exact values (e.g., timestamp duration)
func testDuration() {
    let start = Date()
    // ... operation ...
    let elapsed = Date().timeIntervalSince(start)
    XCTAssertLessThan(elapsed, 1.0)  // Should be quick
}
```

**Floating-point comparisons:**
```swift
// Use accuracy parameter for Double assertions
func testFloatToDoubleConversion() {
    let input: [(speakerIndex: Int, startTime: Float, endTime: Float)] = [
        (0, 1.5, 3.75)
    ]
    let result = DiarizationEngine.mapToSpeakerSegments(rawSegments: input)
    XCTAssertEqual(result[0].start, 1.5, accuracy: 0.001)
    XCTAssertEqual(result[0].end, 3.75, accuracy: 0.001)
}
```

## Test Coverage Areas

**Well-tested:**
- Pure utility functions: `Formatters` (6 functions, comprehensive test cases)
- Data models: `Meeting` CRUD, search, ordering, FTS5
- Transcription logic: `TranscriptMerger.merge()`, `TranscriptMerger.generateFullText()`
- Engine token/segment processing: `ASREngine.groupTokensIntoSegments()`, `DiarizationEngine.mapToSpeakerSegments()`
- Detection logic: `MeetingDetector.DecisionEngine.evaluate()`
- Audio processing: Mono mixdown channel averaging and format validation

**Not tested (by design):**
- UI components (SwiftUI views)
- External service integration (ASR model inference, diarization inference)
- File system I/O beyond format validation
- Real async/await flows in production (tested through state assertions)

---

*Testing analysis: 2026-03-22*
