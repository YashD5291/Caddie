# Caddie Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Caddie — a native macOS menu bar app that auto-detects meetings, records audio, transcribes with speaker diarization on Apple Neural Engine, and stores everything locally.

**Architecture:** Single-process SwiftUI app with MenuBarExtra + WindowGroup. Detection via multi-signal CoreAudio/Accessibility/EventKit. Recording via CoreAudio Taps + AVAudioEngine. Transcription via FluidAudio (Parakeet + pyannote on CoreML/ANE). Storage in SQLite (GRDB) + ALAC audio files.

**Tech Stack:** Swift 5.9+, SwiftUI, macOS 14.2+, CoreAudio, AVFoundation, ScreenCaptureKit, EventKit, FluidAudio, SimplyCoreAudio, AXSwift, GRDB.swift, Sparkle

**Spec:** `docs/superpowers/specs/2026-03-19-caddie-design.md`

---

## File Map

Every file that will be created, and what it does:

```
Caddie/                              # Xcode project root
├── project.yml                      # xcodegen project spec (generates .xcodeproj)
├── Package.resolved                 # SPM lockfile (auto-generated)
├── Podfile                          # CocoaPods for FluidAudio (if no SPM)
├── Sources/
│   ├── App/
│   │   ├── CaddieApp.swift          # @main entry, MenuBarExtra + WindowGroup
│   │   └── AppState.swift           # @Observable: app-wide state machine
│   ├── Detection/
│   │   ├── MeetingDetector.swift     # Orchestrates signals, decision logic, grace period
│   │   ├── AudioProcessMonitor.swift # kAudioHardwarePropertyProcessObjectList enumeration
│   │   ├── MicStateMonitor.swift     # SimplyCoreAudio isRunningSomewhere listener
│   │   ├── WindowTitleMonitor.swift  # AXSwift AXObserver per meeting app
│   │   ├── CalendarMonitor.swift     # EventKit current event query
│   │   └── MeetingPatterns.swift     # Known apps, bundle IDs, process names, title regexes
│   ├── Recording/
│   │   ├── AudioRecorder.swift       # Orchestrates SystemAudioCapture + MicrophoneCapture
│   │   ├── SystemAudioCapture.swift  # CATapDescription → aggregate device → PCM callback
│   │   └── MicrophoneCapture.swift   # AVAudioEngine installTap → PCM buffers
│   ├── Transcription/
│   │   ├── TranscriptionPipeline.swift # Queued pipeline: ASR → diarize → merge → compress
│   │   ├── ASREngine.swift           # FluidAudio Parakeet wrapper
│   │   ├── DiarizationEngine.swift   # FluidAudio pyannote wrapper
│   │   └── TranscriptMerger.swift    # Temporal overlap alignment algorithm
│   ├── Storage/
│   │   ├── Database.swift            # GRDB DatabasePool setup, WAL, FTS5
│   │   ├── Migrations.swift          # Schema v1 creation + future migration slots
│   │   ├── Meeting.swift             # Meeting record: Codable, FetchableRecord, PersistableRecord
│   │   └── AudioFileManager.swift    # WAV write, ALAC compress, file delete, orphan scan
│   ├── UI/
│   │   ├── MenuBar/
│   │   │   ├── MenuBarView.swift     # MenuBarExtra content: status, recent meetings, actions
│   │   │   └── RecordingIndicator.swift # Pulsing red dot animation
│   │   ├── MainWindow/
│   │   │   ├── ContentView.swift     # NavigationSplitView: sidebar + detail
│   │   │   ├── MeetingListView.swift # Sidebar: search field + date-grouped meeting list
│   │   │   ├── MeetingDetailView.swift # Detail: header + player + transcript + actions
│   │   │   ├── TranscriptView.swift  # Scrollable speaker-labeled segments with timestamps
│   │   │   ├── AudioPlayerView.swift # AVAudioPlayer controls: play/pause, scrub, speed
│   │   │   └── ExportSheet.swift     # TXT/SRT format export sheet
│   │   ├── Settings/
│   │   │   └── SettingsView.swift    # Settings window: auto-launch, mic, storage, calendar
│   │   ├── Onboarding/
│   │   │   └── OnboardingView.swift  # First-launch permission + model download wizard
│   │   └── Shared/
│   │       ├── SpeakerBadge.swift    # Color-coded speaker label capsule
│   │       └── StatusDot.swift       # Green/orange/red status circle
│   ├── Models/
│   │   └── ModelManager.swift        # HuggingFace model download, cache, integrity check
│   └── Utilities/
│       ├── Formatters.swift          # Duration, date, SRT timestamp formatters
│       ├── Permissions.swift         # TCC permission check + request helpers
│       └── Logger.swift              # OSLog wrapper with file output + rotation
├── Tests/
│   ├── MeetingPatternsTests.swift    # Pattern matching for all known meeting apps
│   ├── MeetingDetectorTests.swift    # Decision logic with mocked signals
│   ├── TranscriptMergerTests.swift   # Temporal overlap alignment algorithm
│   ├── MeetingModelTests.swift       # GRDB record encoding/decoding + FTS5 queries
│   ├── FormattersTests.swift         # Duration, SRT timestamp formatting
│   ├── AudioFileManagerTests.swift   # ALAC compression verification
│   └── ExportTests.swift             # TXT/SRT export format correctness
├── Resources/
│   ├── Assets.xcassets/              # App icon, menu bar icons (idle/recording/transcribing)
│   ├── Info.plist                    # Privacy descriptions, deployment target, LSUIElement
│   └── Caddie.entitlements           # com.apple.security.device.audio-input, etc.
└── .gitignore
```

---

## Task 1: Xcode Project + Dependencies + App Shell

**Files:**
- Create: `Caddie/project.yml` (xcodegen spec)
- Create: `Caddie/Sources/App/CaddieApp.swift`
- Create: `Caddie/Sources/App/AppState.swift`
- Create: `Caddie/Resources/Info.plist`
- Create: `Caddie/Resources/Caddie.entitlements`
- Create: `Caddie/.gitignore`

**Context:** We're creating a brand new macOS SwiftUI app from scratch. The existing Oracle codebase (Python) will be removed. We use `xcodegen` to generate the `.xcodeproj` from a YAML spec so the project config is version-controlled.

- [ ] **Step 1: Install xcodegen**

```bash
brew install xcodegen
```

- [ ] **Step 2: Remove old Oracle code**

```bash
cd /Users/yashdesai/Codebase/Fun/Oracle
rm -rf mac-agent/ server/ swift-helper/ docker-compose.yml Dockerfile Dockerfile.cpu com.meetingrecorder.agent.plist setup.sh .env.example README.md
```

Keep `docs/` (our spec and plan) and `.git/`.

- [ ] **Step 3: Create project directory structure**

```bash
mkdir -p Caddie/Sources/{App,Detection,Recording,Transcription,Storage,UI/{MenuBar,MainWindow,Settings,Onboarding,Shared},Models,Utilities}
mkdir -p Caddie/Tests
mkdir -p Caddie/Resources/Assets.xcassets
```

- [ ] **Step 4: Write project.yml**

Create `Caddie/project.yml`:

```yaml
name: Caddie
options:
  bundleIdPrefix: com.caddie
  deploymentTarget:
    macOS: "14.2"
  xcodeVersion: "15.0"
  createIntermediateGroups: true

settings:
  base:
    SWIFT_VERSION: "5.9"
    MACOSX_DEPLOYMENT_TARGET: "14.2"
    CODE_SIGN_IDENTITY: "-"
    PRODUCT_BUNDLE_IDENTIFIER: com.caddie.app
    MARKETING_VERSION: "1.0.0"
    CURRENT_PROJECT_VERSION: "1"
    INFOPLIST_FILE: Resources/Info.plist
    CODE_SIGN_ENTITLEMENTS: Resources/Caddie.entitlements
    LD_RUNPATH_SEARCH_PATHS: "$(inherited) @executable_path/../Frameworks"

packages:
  GRDB:
    url: https://github.com/groue/GRDB.swift
    from: "7.0.0"
  SimplyCoreAudio:
    url: https://github.com/rnine/SimplyCoreAudio
    from: "4.0.0"
  AXSwift:
    url: https://github.com/tmandry/AXSwift
    from: "0.3.2"
  Sparkle:
    url: https://github.com/sparkle-project/Sparkle
    from: "2.6.0"

targets:
  Caddie:
    type: application
    platform: macOS
    sources:
      - Sources
    resources:
      - Resources
    dependencies:
      - package: GRDB
      - package: SimplyCoreAudio
      - package: AXSwift
      - package: Sparkle
    settings:
      base:
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        LSUIElement: true  # Menu bar app, no dock icon

  CaddieTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - Tests
    dependencies:
      - target: Caddie
```

- [ ] **Step 5: Write Info.plist**

Create `Caddie/Resources/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Caddie</string>
    <key>CFBundleDisplayName</key>
    <string>Caddie</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleVersion</key>
    <string>$(CURRENT_PROJECT_VERSION)</string>
    <key>CFBundleShortVersionString</key>
    <string>$(MARKETING_VERSION)</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>LSMinimumSystemVersion</key>
    <string>$(MACOSX_DEPLOYMENT_TARGET)</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Caddie records your voice during meetings for transcription.</string>
    <key>NSCalendarsUsageDescription</key>
    <string>Caddie reads your calendar to detect meeting titles and improve detection accuracy.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Caddie reads browser tab titles to detect web-based meetings like Google Meet.</string>
</dict>
</plist>
```

- [ ] **Step 6: Write entitlements**

Create `Caddie/Resources/Caddie.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.personal-information.calendars</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 7: Write AppState.swift**

Create `Caddie/Sources/App/AppState.swift`:

```swift
import SwiftUI
import Observation

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
}
```

- [ ] **Step 8: Write CaddieApp.swift**

Create `Caddie/Sources/App/CaddieApp.swift`:

```swift
import SwiftUI

@main
struct CaddieApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            Text("Caddie — v1.0.0")
                .font(.headline)
            Divider()
            switch appState.status {
            case .idle:
                Text("No active meeting")
                    .foregroundStyle(.secondary)
            case .recording:
                Label(appState.currentMeetingTitle ?? "Recording...", systemImage: "record.circle")
                    .foregroundStyle(.red)
            case .transcribing:
                Label("Transcribing...", systemImage: "waveform")
                    .foregroundStyle(.orange)
            }
            Divider()
            Button("Open Caddie") {
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Quit") {
                NSApp.terminate(nil)
            }
        } label: {
            Image(systemName: appState.status == .recording ? "record.circle.fill" : "mic.badge.plus")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(appState.status == .recording ? .red : .primary)
        }

        WindowGroup {
            ContentView()
                .environment(appState)
        }

        Settings {
            Text("Settings placeholder")
                .frame(width: 400, height: 300)
        }
    }
}
```

- [ ] **Step 9: Write minimal ContentView**

Create `Caddie/Sources/UI/MainWindow/ContentView.swift`:

```swift
import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationSplitView {
            Text("Meetings")
                .navigationTitle("Caddie")
        } detail: {
            Text("Select a meeting")
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 700, minHeight: 500)
    }
}
```

- [ ] **Step 10: Write .gitignore**

Create `Caddie/.gitignore`:

```
# Xcode
*.xcodeproj/
xcuserdata/
DerivedData/
build/
*.xcworkspace/

# CocoaPods
Pods/

# SPM
.build/
Package.resolved

# macOS
.DS_Store
```

- [ ] **Step 11: Generate Xcode project and verify build**

```bash
cd Caddie
xcodegen generate
xcodebuild -project Caddie.xcodeproj -scheme Caddie -configuration Debug build | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 12: Commit**

```bash
git add Caddie/ docs/
git commit -m "feat: scaffold Caddie macOS app with dependencies and app shell"
```

---

## Task 2: Storage Layer — Database + Meeting Model

**Files:**
- Create: `Caddie/Sources/Storage/Meeting.swift`
- Create: `Caddie/Sources/Storage/Database.swift`
- Create: `Caddie/Sources/Storage/Migrations.swift`
- Create: `Caddie/Sources/Storage/AudioFileManager.swift`
- Create: `Caddie/Sources/Utilities/Formatters.swift`
- Test: `Caddie/Tests/MeetingModelTests.swift`
- Test: `Caddie/Tests/FormattersTests.swift`

**Context:** The storage layer is the foundation everything else builds on. It must work correctly before we add detection, recording, or transcription. Uses GRDB.swift for SQLite with WAL mode and FTS5 full-text search.

- [ ] **Step 1: Write Meeting model tests**

Create `Caddie/Tests/MeetingModelTests.swift`:

```swift
import XCTest
import GRDB
@testable import Caddie

final class MeetingModelTests: XCTestCase {
    var dbPool: DatabasePool!

    override func setUp() async throws {
        dbPool = try DatabasePool(path: ":memory:")
        try AppDatabase.migrate(dbPool)
    }

    func testCreateAndFetchMeeting() throws {
        var meeting = Meeting(
            meetingId: "test-123",
            title: "Q3 Budget Review",
            app: "Zoom",
            date: "2026-03-19",
            startTime: "2026-03-19T14:00:00",
            endTime: "2026-03-19T14:45:00",
            durationSeconds: 2700,
            status: .recording
        )

        try dbPool.write { db in
            try meeting.insert(db)
        }

        let fetched = try dbPool.read { db in
            try Meeting.filter(Column("meeting_id") == "test-123").fetchOne(db)
        }

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.title, "Q3 Budget Review")
        XCTAssertEqual(fetched?.app, "Zoom")
        XCTAssertEqual(fetched?.status, .recording)
    }

    func testFTS5Search() throws {
        var meeting = Meeting(
            meetingId: "fts-test",
            title: "Budget Discussion",
            app: "Teams",
            date: "2026-03-19",
            startTime: "2026-03-19T10:00:00",
            endTime: "2026-03-19T10:30:00",
            durationSeconds: 1800,
            status: .done,
            transcript: "{\"full_text\": \"Let's talk about the Q3 revenue numbers\"}"
        )

        try dbPool.write { db in
            try meeting.insert(db)
        }

        let results = try dbPool.read { db in
            try Meeting.search("revenue").fetchAll(db)
        }

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.meetingId, "fts-test")
    }

    func testListMeetingsOrderedByDate() throws {
        try dbPool.write { db in
            var m1 = Meeting(meetingId: "a", title: "Old", app: "Zoom", date: "2026-03-17", startTime: "", endTime: "", durationSeconds: 0, status: .done)
            var m2 = Meeting(meetingId: "b", title: "New", app: "Zoom", date: "2026-03-19", startTime: "", endTime: "", durationSeconds: 0, status: .done)
            try m1.insert(db)
            try m2.insert(db)
        }

        let meetings = try dbPool.read { db in
            try Meeting.order(Column("created_at").desc).fetchAll(db)
        }

        XCTAssertEqual(meetings.count, 2)
        XCTAssertEqual(meetings.first?.meetingId, "b")
    }

    func testUpdateStatus() throws {
        var meeting = Meeting(meetingId: "status-test", title: "Test", app: "Zoom", date: "2026-03-19", startTime: "", endTime: "", durationSeconds: 0, status: .recording)

        try dbPool.write { db in
            try meeting.insert(db)
            try db.execute(sql: "UPDATE meetings SET status = ? WHERE meeting_id = ?", arguments: [MeetingStatus.transcribing.rawValue, "status-test"])
        }

        let fetched = try dbPool.read { db in
            try Meeting.filter(Column("meeting_id") == "status-test").fetchOne(db)
        }

        XCTAssertEqual(fetched?.status, .transcribing)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd Caddie
xcodebuild test -project Caddie.xcodeproj -scheme CaddieTests -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: Compilation errors — `Meeting`, `AppDatabase`, `MeetingStatus` not defined.

- [ ] **Step 3: Write Meeting.swift**

Create `Caddie/Sources/Storage/Meeting.swift`:

```swift
import Foundation
import GRDB

enum MeetingStatus: String, Codable, DatabaseValueConvertible {
    case recording
    case transcribing
    case done
    case error
}

struct Meeting: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var meetingId: String
    var title: String
    var app: String
    var date: String
    var startTime: String
    var endTime: String
    var durationSeconds: Int
    var audioFile: String?
    var status: MeetingStatus
    var transcript: String?
    var error: String?
    var createdAt: Date?

    static let databaseTableName = "meetings"

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id, meetingId = "meeting_id", title, app, date
        case startTime = "start_time", endTime = "end_time"
        case durationSeconds = "duration_seconds", audioFile = "audio_file"
        case status, transcript, error, createdAt = "created_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// FTS5 search on title + transcript
    static func search(_ query: String) -> QueryInterfaceRequest<Meeting> {
        let pattern = FTS5Pattern(matchingAllTokensIn: query)
        return Meeting
            .joining(required: Meeting.hasOne(
                Meeting.self,
                using: ForeignKey([Column("rowid")], to: [Column("id")])
            ).aliased(TableAlias(name: "meetings_fts")))
            .filter(sql: "meetings_fts MATCH ?", arguments: [pattern?.rawPattern ?? query])
    }
}
```

Note: The FTS5 search approach above is simplified. The actual implementation may need adjustment based on GRDB's FTS5 API — see GRDB docs at `https://swiftpackageindex.com/groue/GRDB.swift/documentation/grdb/fts5`.

- [ ] **Step 4: Write Database.swift**

Create `Caddie/Sources/Storage/Database.swift`:

```swift
import Foundation
import GRDB

struct AppDatabase {
    let dbPool: DatabasePool

    init() throws {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let caddieDir = appSupport.appendingPathComponent("Caddie", isDirectory: true)
        try FileManager.default.createDirectory(at: caddieDir, withIntermediateDirectories: true)

        let dbPath = caddieDir.appendingPathComponent("caddie.db").path
        dbPool = try DatabasePool(path: dbPath)

        try Self.migrate(dbPool)
    }

    /// For testing with in-memory database
    init(dbPool: DatabasePool) throws {
        self.dbPool = dbPool
        try Self.migrate(dbPool)
    }

    static func migrate(_ db: DatabasePool) throws {
        try Migrations.run(db)
    }
}
```

- [ ] **Step 5: Write Migrations.swift**

Create `Caddie/Sources/Storage/Migrations.swift`:

```swift
import GRDB

enum Migrations {
    static func run(_ dbPool: DatabasePool) throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_create_meetings") { db in
            try db.create(table: "meetings") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meeting_id", .text).notNull().unique()
                t.column("title", .text).notNull()
                t.column("app", .text).notNull().defaults(to: "Unknown")
                t.column("date", .text).notNull()
                t.column("start_time", .text).notNull()
                t.column("end_time", .text).notNull()
                t.column("duration_seconds", .integer).defaults(to: 0)
                t.column("audio_file", .text)
                t.column("status", .text).notNull().defaults(to: "recording")
                t.column("transcript", .text)
                t.column("error", .text)
                t.column("created_at", .datetime).defaults(sql: "CURRENT_TIMESTAMP")
            }

            try db.create(index: "idx_meetings_date", on: "meetings", columns: ["date"])
            try db.create(index: "idx_meetings_status", on: "meetings", columns: ["status"])

            try db.execute(sql: """
                CREATE VIRTUAL TABLE meetings_fts USING fts5(
                    title, transcript,
                    content=meetings, content_rowid=id,
                    tokenize='porter unicode61'
                )
            """)

            // FTS5 sync triggers
            try db.execute(sql: """
                CREATE TRIGGER meetings_ai AFTER INSERT ON meetings BEGIN
                    INSERT INTO meetings_fts(rowid, title, transcript)
                    VALUES (new.id, new.title, new.transcript);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER meetings_ad AFTER DELETE ON meetings BEGIN
                    INSERT INTO meetings_fts(meetings_fts, rowid, title, transcript)
                    VALUES ('delete', old.id, old.title, old.transcript);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER meetings_au AFTER UPDATE ON meetings BEGIN
                    INSERT INTO meetings_fts(meetings_fts, rowid, title, transcript)
                    VALUES ('delete', old.id, old.title, old.transcript);
                    INSERT INTO meetings_fts(rowid, title, transcript)
                    VALUES (new.id, new.title, new.transcript);
                END
            """)
        }

        try migrator.migrate(dbPool)
    }
}
```

- [ ] **Step 6: Write AudioFileManager.swift**

Create `Caddie/Sources/Storage/AudioFileManager.swift`:

```swift
import Foundation
import AudioToolbox
import os

struct AudioFileManager {
    private static let logger = Logger(subsystem: "com.caddie.app", category: "AudioFileManager")

    static var audioDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Caddie/audio", isDirectory: true)
    }

    static func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
    }

    static func wavPath(for meetingId: String) -> URL {
        audioDirectory.appendingPathComponent("\(meetingId).wav")
    }

    static func alacPath(for meetingId: String) -> URL {
        audioDirectory.appendingPathComponent("\(meetingId).m4a")
    }

    /// Compress WAV to ALAC using AudioToolbox
    static func compressToALAC(wavURL: URL, outputURL: URL) throws {
        var inputFile: ExtAudioFileRef?
        var status = ExtAudioFileOpenURL(wavURL as CFURL, &inputFile)
        guard status == noErr, let input = inputFile else {
            throw AudioFileError.cannotOpenInput(status)
        }
        defer { ExtAudioFileDispose(input) }

        // Read input format
        var inputFormat = AudioStreamBasicDescription()
        var propSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = ExtAudioFileGetProperty(input, kExtAudioFileProperty_FileDataFormat, &propSize, &inputFormat)
        guard status == noErr else { throw AudioFileError.cannotReadFormat(status) }

        // Set up ALAC output format
        var outputFormat = AudioStreamBasicDescription(
            mSampleRate: inputFormat.mSampleRate,
            mFormatID: kAudioFormatAppleLossless,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 4096,
            mBytesPerFrame: 0,
            mChannelsPerFrame: inputFormat.mChannelsPerFrame,
            mBitsPerChannel: 0,
            mReserved: 0
        )

        var outputFile: ExtAudioFileRef?
        status = ExtAudioFileCreateWithURL(
            outputURL as CFURL,
            kAudioFileM4AType,
            &outputFormat,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &outputFile
        )
        guard status == noErr, let output = outputFile else {
            throw AudioFileError.cannotCreateOutput(status)
        }
        defer { ExtAudioFileDispose(output) }

        // Set client format (what we read as)
        var clientFormat = inputFormat
        ExtAudioFileSetProperty(output, kExtAudioFileProperty_ClientDataFormat,
                                UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFormat)

        // Copy audio data
        let bufferSize: UInt32 = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(bufferSize) * Int(inputFormat.mBytesPerFrame))
        defer { buffer.deallocate() }

        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: inputFormat.mChannelsPerFrame,
                mDataByteSize: bufferSize * inputFormat.mBytesPerFrame,
                mData: buffer
            )
        )

        while true {
            var frameCount = bufferSize
            bufferList.mBuffers.mDataByteSize = bufferSize * inputFormat.mBytesPerFrame
            status = ExtAudioFileRead(input, &frameCount, &bufferList)
            guard status == noErr else { throw AudioFileError.readFailed(status) }
            if frameCount == 0 { break }
            status = ExtAudioFileWrite(output, frameCount, &bufferList)
            guard status == noErr else { throw AudioFileError.writeFailed(status) }
        }

        logger.info("Compressed \(wavURL.lastPathComponent) → \(outputURL.lastPathComponent)")
    }

    /// Scan for orphaned WAV files (from crashed recordings)
    static func findOrphanedWAVs() -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: audioDirectory, includingPropertiesForKeys: nil) else { return [] }
        return contents.filter { $0.pathExtension == "wav" }
    }

    /// Delete audio file for a meeting
    static func deleteAudio(meetingId: String) throws {
        let alac = alacPath(for: meetingId)
        let wav = wavPath(for: meetingId)
        if FileManager.default.fileExists(atPath: alac.path) {
            try FileManager.default.removeItem(at: alac)
        }
        if FileManager.default.fileExists(atPath: wav.path) {
            try FileManager.default.removeItem(at: wav)
        }
    }

    /// Total size of all audio files
    static func totalStorageUsed() -> Int64 {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: audioDirectory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return contents.compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.reduce(0) { $0 + Int64($1) }
    }

    enum AudioFileError: Error {
        case cannotOpenInput(OSStatus)
        case cannotCreateOutput(OSStatus)
        case cannotReadFormat(OSStatus)
        case readFailed(OSStatus)
        case writeFailed(OSStatus)
    }
}
```

- [ ] **Step 7: Write Formatters.swift**

Create `Caddie/Sources/Utilities/Formatters.swift`:

```swift
import Foundation

enum Formatters {
    /// "45m" or "1h 30m"
    static func duration(seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    /// "2:45 PM"
    static func time(from isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: isoString) ?? ISO8601DateFormatter().date(from: isoString) else { return "" }
        let display = DateFormatter()
        display.timeStyle = .short
        return display.string(from: date)
    }

    /// "Today", "Yesterday", "Mon, Mar 17"
    static func dateLabel(from dateString: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dateString) else { return dateString }

        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }

        let display = DateFormatter()
        display.dateFormat = "EEE, MMM d"
        return display.string(from: date)
    }

    /// "2:45" (minutes:seconds)
    static func timestamp(seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return "\(m):\(String(format: "%02d", s))"
    }

    /// SRT format: "00:02:45,000"
    static func srtTimestamp(seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        let ms = Int((seconds.truncatingRemainder(dividingBy: 1)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
}
```

- [ ] **Step 8: Write Formatters tests**

Create `Caddie/Tests/FormattersTests.swift`:

```swift
import XCTest
@testable import Caddie

final class FormattersTests: XCTestCase {
    func testDurationShort() {
        XCTAssertEqual(Formatters.duration(seconds: 2700), "45m")
    }

    func testDurationLong() {
        XCTAssertEqual(Formatters.duration(seconds: 5400), "1h 30m")
    }

    func testDurationZero() {
        XCTAssertEqual(Formatters.duration(seconds: 0), "0m")
    }

    func testTimestamp() {
        XCTAssertEqual(Formatters.timestamp(seconds: 65.0), "1:05")
        XCTAssertEqual(Formatters.timestamp(seconds: 0.0), "0:00")
        XCTAssertEqual(Formatters.timestamp(seconds: 3661.0), "61:01")
    }

    func testSrtTimestamp() {
        XCTAssertEqual(Formatters.srtTimestamp(seconds: 165.5), "00:02:45,500")
        XCTAssertEqual(Formatters.srtTimestamp(seconds: 0.0), "00:00:00,000")
    }

    func testDateLabelToday() {
        let today = DateFormatter()
        today.dateFormat = "yyyy-MM-dd"
        let todayStr = today.string(from: Date())
        XCTAssertEqual(Formatters.dateLabel(from: todayStr), "Today")
    }
}
```

- [ ] **Step 9: Run all tests**

```bash
cd Caddie
xcodebuild test -project Caddie.xcodeproj -scheme CaddieTests -destination 'platform=macOS' 2>&1 | grep -E '(Test Case|Tests|PASS|FAIL|error:)'
```

Expected: All tests pass.

- [ ] **Step 10: Commit**

```bash
git add Caddie/
git commit -m "feat: add storage layer with GRDB, Meeting model, FTS5, ALAC compression, formatters"
```

---

## Task 3: Meeting Patterns + Detection Signal Types

**Files:**
- Create: `Caddie/Sources/Detection/MeetingPatterns.swift`
- Test: `Caddie/Tests/MeetingPatternsTests.swift`

**Context:** Define the known meeting apps, their process names, bundle IDs, and window title patterns. This is pure data + pattern matching logic — no system interaction. All detection signals will reference these patterns.

- [ ] **Step 1: Write pattern matching tests**

Create `Caddie/Tests/MeetingPatternsTests.swift`:

```swift
import XCTest
@testable import Caddie

final class MeetingPatternsTests: XCTestCase {
    func testZoomProcessDetection() {
        XCTAssertEqual(MeetingPatterns.appForProcess("zoom.us"), "Zoom")
        XCTAssertNil(MeetingPatterns.appForProcess("com.apple.finder"))
    }

    func testTeamsProcessDetection() {
        XCTAssertEqual(MeetingPatterns.appForProcess("Microsoft Teams"), "Microsoft Teams")
        XCTAssertEqual(MeetingPatterns.appForProcess("Teams"), "Microsoft Teams")
    }

    func testGoogleMeetWindowTitle() {
        XCTAssertTrue(MeetingPatterns.isMeetingTitle("Meet - Budget Review", forApp: "Google Meet"))
        XCTAssertFalse(MeetingPatterns.isMeetingTitle("Gmail - Inbox", forApp: "Google Meet"))
    }

    func testZoomWindowTitle() {
        XCTAssertTrue(MeetingPatterns.isMeetingTitle("Zoom Meeting", forApp: "Zoom"))
        XCTAssertTrue(MeetingPatterns.isMeetingTitle("Zoom Meeting-ID: 123-456-789", forApp: "Zoom"))
        XCTAssertFalse(MeetingPatterns.isMeetingTitle("Zoom Workplace", forApp: "Zoom"))
    }

    func testBrowserIsMeetingApp() {
        XCTAssertTrue(MeetingPatterns.isBrowser("Google Chrome"))
        XCTAssertTrue(MeetingPatterns.isBrowser("Safari"))
        XCTAssertTrue(MeetingPatterns.isBrowser("Arc"))
        XCTAssertFalse(MeetingPatterns.isBrowser("Finder"))
    }

    func testCleanMeetingTitle() {
        XCTAssertEqual(
            MeetingPatterns.cleanTitle("Budget Review - Zoom Meeting", app: "Zoom"),
            "Budget Review"
        )
        XCTAssertEqual(
            MeetingPatterns.cleanTitle("Sprint Planning | Microsoft Teams", app: "Microsoft Teams"),
            "Sprint Planning"
        )
        XCTAssertEqual(
            MeetingPatterns.cleanTitle("Meet - Q3 Sync", app: "Google Meet"),
            "Q3 Sync"
        )
    }

    func testAllKnownAppsHaveProcessNames() {
        for app in MeetingPatterns.knownApps {
            XCTAssertFalse(app.processNames.isEmpty, "\(app.name) has no process names")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: `MeetingPatterns` not defined.

- [ ] **Step 3: Write MeetingPatterns.swift**

Create `Caddie/Sources/Detection/MeetingPatterns.swift`:

```swift
import Foundation

struct MeetingApp {
    let name: String
    let processNames: [String]
    let bundleIds: [String]
    let titlePatterns: [NSRegularExpression]
    let isBrowserBased: Bool

    init(name: String, processNames: [String], bundleIds: [String] = [],
         titlePatterns: [String] = [], isBrowserBased: Bool = false) {
        self.name = name
        self.processNames = processNames
        self.bundleIds = bundleIds
        self.titlePatterns = titlePatterns.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
        self.isBrowserBased = isBrowserBased
    }
}

enum MeetingPatterns {
    static let knownApps: [MeetingApp] = [
        MeetingApp(
            name: "Zoom",
            processNames: ["zoom.us", "zoom"],
            bundleIds: ["us.zoom.xos"],
            titlePatterns: ["^Zoom Meeting", "^Zoom Webinar"]
        ),
        MeetingApp(
            name: "Microsoft Teams",
            processNames: ["Microsoft Teams", "Teams"],
            bundleIds: ["com.microsoft.teams2", "com.microsoft.teams"],
            titlePatterns: [] // Teams shows meeting name directly — any non-idle title matches
        ),
        MeetingApp(
            name: "Google Meet",
            processNames: [], // Browser-based only
            bundleIds: [],
            titlePatterns: ["^Meet\\s*[-–—]\\s*"],
            isBrowserBased: true
        ),
        MeetingApp(
            name: "Slack",
            processNames: ["Slack"],
            bundleIds: ["com.tinyspeck.slackmacgap"],
            titlePatterns: ["huddle", "call with"]
        ),
        MeetingApp(
            name: "Discord",
            processNames: ["Discord"],
            bundleIds: ["com.hnc.Discord"],
            titlePatterns: [] // Voice channel name in title
        ),
        MeetingApp(
            name: "Webex",
            processNames: ["Webex", "CiscoWebex", "WebexMTA"],
            bundleIds: ["com.cisco.webexmeetingsapp"],
            titlePatterns: ["meeting", "webex"]
        ),
        MeetingApp(
            name: "FaceTime",
            processNames: ["FaceTime"],
            bundleIds: ["com.apple.FaceTime"],
            titlePatterns: [] // Shows contact name
        ),
        MeetingApp(
            name: "Skype",
            processNames: ["Skype"],
            bundleIds: ["com.skype.skype"],
            titlePatterns: ["call"]
        ),
    ]

    static let browsers = ["Google Chrome", "Safari", "Arc", "Firefox", "Brave Browser", "Microsoft Edge"]

    /// Find which known meeting app matches a process name
    static func appForProcess(_ processName: String) -> String? {
        let lower = processName.lowercased()
        for app in knownApps {
            for pName in app.processNames {
                if lower.contains(pName.lowercased()) {
                    return app.name
                }
            }
        }
        return nil
    }

    /// Check if a process name is a browser
    static func isBrowser(_ processName: String) -> Bool {
        browsers.contains(processName)
    }

    /// Check if a window title matches meeting patterns for a given app
    static func isMeetingTitle(_ title: String, forApp appName: String) -> Bool {
        guard let app = knownApps.first(where: { $0.name == appName }) else { return false }
        if app.titlePatterns.isEmpty { return true } // No patterns = any title matches
        let range = NSRange(title.startIndex..., in: title)
        return app.titlePatterns.contains { $0.firstMatch(in: title, range: range) != nil }
    }

    /// Clean a window title by removing app-specific chrome
    static func cleanTitle(_ rawTitle: String, app: String) -> String {
        var title = rawTitle.trimmingCharacters(in: .whitespaces)

        // Zoom: "Budget Review - Zoom Meeting"
        title = title.replacingOccurrences(of: "\\s*[-–—]\\s*Zoom\\s*(Meeting|Webinar)?\\s*$",
                                           with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: "^Zoom\\s*(Meeting|Webinar)?\\s*[-–—]\\s*",
                                           with: "", options: .regularExpression)

        // Teams: "Sprint Planning | Microsoft Teams"
        title = title.replacingOccurrences(of: "\\s*\\|\\s*Microsoft Teams.*$",
                                           with: "", options: .regularExpression)

        // Google Meet: "Meet - Q3 Sync"
        title = title.replacingOccurrences(of: "^Meet\\s*[-–—]\\s*",
                                           with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: "\\s*[-–—]\\s*Google Meet\\s*$",
                                           with: "", options: .regularExpression)

        // Slack: "... - Slack"
        title = title.replacingOccurrences(of: "\\s*[-–—]\\s*Slack\\s*$",
                                           with: "", options: .regularExpression)

        // Browser notification count: "(3) Meeting Title"
        title = title.replacingOccurrences(of: "^\\(\\d+\\)\\s*", with: "", options: .regularExpression)

        return title.trimmingCharacters(in: .whitespaces)
    }
}
```

- [ ] **Step 4: Run tests**

```bash
cd Caddie
xcodebuild test -project Caddie.xcodeproj -scheme CaddieTests -destination 'platform=macOS' 2>&1 | grep -E '(Test Case|PASS|FAIL)'
```

Expected: All MeetingPatternsTests pass.

- [ ] **Step 5: Commit**

```bash
git add Caddie/
git commit -m "feat: add meeting app patterns with process names and title matching"
```

---

## Task 4: Detection Signals — All 4 Monitors

**Files:**
- Create: `Caddie/Sources/Detection/AudioProcessMonitor.swift`
- Create: `Caddie/Sources/Detection/MicStateMonitor.swift`
- Create: `Caddie/Sources/Detection/WindowTitleMonitor.swift`
- Create: `Caddie/Sources/Detection/CalendarMonitor.swift`

**Context:** Each monitor is an independent signal source. They all publish their state via a common protocol so the orchestrator (Task 5) can combine them. These interact with system hardware, so they can't be unit-tested directly — we'll use protocol abstractions.

- [ ] **Step 1: Define the signal protocol**

Add to `Caddie/Sources/Detection/MeetingPatterns.swift` (or a new file if preferred):

```swift
/// A signal emitted by a detection monitor
struct DetectionSignal {
    let source: SignalSource
    let appName: String?       // Which meeting app, if identifiable
    let processId: pid_t?      // PID of the meeting app
    let windowTitle: String?   // Window/tab title, if available
    let calendarEvent: String? // Calendar event title, if available
    let isActive: Bool         // true = signal present, false = signal lost

    enum SignalSource: String {
        case audioProcess     // kAudioProcessPropertyPID
        case micState         // kAudioDevicePropertyDeviceIsRunningSomewhere
        case windowTitle      // AXObserver title change
        case calendar         // EventKit current event
    }
}

protocol DetectionMonitor {
    var onSignal: ((DetectionSignal) -> Void)? { get set }
    func start()
    func stop()
}
```

- [ ] **Step 2: Write AudioProcessMonitor.swift**

Create `Caddie/Sources/Detection/AudioProcessMonitor.swift`:

```swift
import Foundation
import CoreAudio
import os

/// Enumerates which processes are actively using audio (macOS 14+).
/// Fires a signal when a known meeting app is found using audio.
final class AudioProcessMonitor: DetectionMonitor {
    var onSignal: ((DetectionSignal) -> Void)?

    private let logger = Logger(subsystem: "com.caddie.app", category: "AudioProcessMonitor")
    private var timer: Timer?
    private var lastKnownPIDs: Set<pid_t> = []

    func start() {
        // Poll every 3 seconds — kAudioHardwarePropertyProcessObjectList
        // does not support property listeners for changes
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.checkAudioProcesses()
        }
        timer?.tolerance = 1.0
        checkAudioProcesses() // Initial check
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func checkAudioProcesses() {
        let pids = readAudioProcessPIDs()
        var currentMeetingPIDs: Set<pid_t> = []

        for pid in pids {
            guard let processName = processName(for: pid) else { continue }
            if let appName = MeetingPatterns.appForProcess(processName) {
                currentMeetingPIDs.insert(pid)
                if !lastKnownPIDs.contains(pid) {
                    logger.info("Meeting app using audio: \(appName) (PID \(pid))")
                    onSignal?(DetectionSignal(
                        source: .audioProcess,
                        appName: appName,
                        processId: pid,
                        windowTitle: nil,
                        calendarEvent: nil,
                        isActive: true
                    ))
                }
            }
        }

        // Check for apps that stopped using audio
        for pid in lastKnownPIDs.subtracting(currentMeetingPIDs) {
            onSignal?(DetectionSignal(
                source: .audioProcess,
                appName: nil,
                processId: pid,
                windowTitle: nil,
                calendarEvent: nil,
                isActive: false
            ))
        }

        lastKnownPIDs = currentMeetingPIDs
    }

    /// Read all process PIDs currently registered with the audio HAL
    private func readAudioProcessPIDs() -> [pid_t] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize
        )
        guard status == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var objectIDs = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize, &objectIDs
        )
        guard status == noErr else { return [] }

        // Get PID for each audio process object
        return objectIDs.compactMap { objectID in
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            let result = AudioObjectGetPropertyData(objectID, &pidAddress, 0, nil, &pidSize, &pid)
            return result == noErr ? pid : nil
        }
    }

    /// Get process name from PID
    private func processName(for pid: pid_t) -> String? {
        let app = NSRunningApplication(processIdentifier: pid)
        return app?.localizedName ?? app?.bundleIdentifier
    }
}
```

- [ ] **Step 3: Write MicStateMonitor.swift**

Create `Caddie/Sources/Detection/MicStateMonitor.swift`:

```swift
import Foundation
import SimplyCoreAudio
import os

/// Monitors microphone active/inactive state via CoreAudio property listener.
/// Fires instantly when any app starts/stops using the mic (event-driven, no polling).
final class MicStateMonitor: DetectionMonitor {
    var onSignal: ((DetectionSignal) -> Void)?

    private let logger = Logger(subsystem: "com.caddie.app", category: "MicStateMonitor")
    private let coreAudio = SimplyCoreAudio()
    private var observer: NSObjectProtocol?
    private var lastState: Bool = false

    func start() {
        // Check initial state
        lastState = isDefaultInputRunning()
        logger.info("Mic state monitor started. Mic active: \(self.lastState)")

        // Subscribe to device changes
        observer = NotificationCenter.default.addObserver(
            forName: .deviceIsRunningSomewhereDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleStateChange()
        }
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
    }

    private func handleStateChange() {
        let isActive = isDefaultInputRunning()
        guard isActive != lastState else { return }
        lastState = isActive

        logger.info("Mic state changed: \(isActive ? "active" : "inactive")")

        onSignal?(DetectionSignal(
            source: .micState,
            appName: nil,
            processId: nil,
            windowTitle: nil,
            calendarEvent: nil,
            isActive: isActive
        ))
    }

    private func isDefaultInputRunning() -> Bool {
        guard let defaultInput = coreAudio.defaultInputDevice else { return false }
        return defaultInput.isRunningSomewhere
    }
}
```

- [ ] **Step 4: Write WindowTitleMonitor.swift**

Create `Caddie/Sources/Detection/WindowTitleMonitor.swift`:

```swift
import Foundation
import AppKit
import os

/// Monitors window titles of known meeting apps.
/// Uses CGWindowListCopyWindowInfo for enumeration (requires Screen Recording).
/// AXSwift event-driven observation can be layered on top in a future iteration
/// for zero-polling title change detection.
/// Polls every 3 seconds (same cadence as AudioProcessMonitor).
final class WindowTitleMonitor: DetectionMonitor {
    var onSignal: ((DetectionSignal) -> Void)?

    private let logger = Logger(subsystem: "com.caddie.app", category: "WindowTitleMonitor")
    private var timer: Timer?
    private var lastMatchedTitles: [String: String] = [:] // appName -> title

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.checkWindowTitles()
        }
        timer?.tolerance = 1.0
        checkWindowTitles()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func checkWindowTitles() {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }

        var currentMatches: [String: String] = [:]

        for window in windowList {
            guard let ownerName = window[kCGWindowOwnerName as String] as? String,
                  let title = window[kCGWindowName as String] as? String,
                  !title.isEmpty else { continue }

            // Check native meeting apps
            if let appName = MeetingPatterns.appForProcess(ownerName) {
                if MeetingPatterns.isMeetingTitle(title, forApp: appName) {
                    currentMatches[appName] = title
                }
            }

            // Check browser-based meetings (Google Meet, etc.)
            if MeetingPatterns.isBrowser(ownerName) {
                for app in MeetingPatterns.knownApps where app.isBrowserBased {
                    if MeetingPatterns.isMeetingTitle(title, forApp: app.name) {
                        currentMatches[app.name] = title
                    }
                }
            }
        }

        // Emit signals for new matches
        for (appName, title) in currentMatches {
            if lastMatchedTitles[appName] != title {
                let cleaned = MeetingPatterns.cleanTitle(title, app: appName)
                logger.info("Meeting window detected: \(appName) — \"\(cleaned)\"")
                onSignal?(DetectionSignal(
                    source: .windowTitle,
                    appName: appName,
                    processId: nil,
                    windowTitle: cleaned,
                    calendarEvent: nil,
                    isActive: true
                ))
            }
        }

        // Emit signals for lost matches
        for appName in lastMatchedTitles.keys where currentMatches[appName] == nil {
            onSignal?(DetectionSignal(
                source: .windowTitle,
                appName: appName,
                processId: nil,
                windowTitle: nil,
                calendarEvent: nil,
                isActive: false
            ))
        }

        lastMatchedTitles = currentMatches
    }
}
```

- [ ] **Step 5: Write CalendarMonitor.swift**

Create `Caddie/Sources/Detection/CalendarMonitor.swift`:

```swift
import Foundation
import EventKit
import os

/// Checks EventKit for calendar events happening right now.
/// Provides meeting titles (especially useful when Zoom doesn't show them).
final class CalendarMonitor: DetectionMonitor {
    var onSignal: ((DetectionSignal) -> Void)?

    private let logger = Logger(subsystem: "com.caddie.app", category: "CalendarMonitor")
    private let eventStore = EKEventStore()
    private var timer: Timer?
    private var lastEventTitle: String?
    private var isAuthorized = false

    func start() {
        requestAccess { [weak self] granted in
            guard granted else {
                self?.logger.warning("Calendar access denied")
                return
            }
            self?.isAuthorized = true
            self?.timer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
                self?.checkCurrentEvents()
            }
            self?.timer?.tolerance = 5.0
            self?.checkCurrentEvents()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func requestAccess(completion: @escaping (Bool) -> Void) {
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToEvents { granted, error in
                DispatchQueue.main.async { completion(granted) }
            }
        } else {
            eventStore.requestAccess(to: .event) { granted, error in
                DispatchQueue.main.async { completion(granted) }
            }
        }
    }

    private func checkCurrentEvents() {
        guard isAuthorized else { return }

        let now = Date()
        let predicate = eventStore.predicateForEvents(
            withStart: now.addingTimeInterval(-60), // 1 min buffer
            end: now.addingTimeInterval(60),
            calendars: nil
        )

        let events = eventStore.events(matching: predicate)
            .filter { !$0.isAllDay } // Skip all-day events
            .filter { ($0.attendees?.count ?? 0) >= 2 } // Meetings have 2+ attendees

        let currentEvent = events.first

        if let title = currentEvent?.title, title != lastEventTitle {
            logger.info("Calendar event active: \"\(title)\"")
            onSignal?(DetectionSignal(
                source: .calendar,
                appName: nil,
                processId: nil,
                windowTitle: nil,
                calendarEvent: title,
                isActive: true
            ))
        } else if currentEvent == nil && lastEventTitle != nil {
            onSignal?(DetectionSignal(
                source: .calendar,
                appName: nil,
                processId: nil,
                windowTitle: nil,
                calendarEvent: nil,
                isActive: false
            ))
        }

        lastEventTitle = currentEvent?.title
    }
}
```

- [ ] **Step 6: Build to verify compilation**

```bash
cd Caddie
xcodegen generate
xcodebuild -project Caddie.xcodeproj -scheme Caddie build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Commit**

```bash
git add Caddie/
git commit -m "feat: add 4 detection monitors — audio process, mic state, window title, calendar"
```

---

## Task 5: Meeting Detector Orchestrator

**Files:**
- Create: `Caddie/Sources/Detection/MeetingDetector.swift`
- Test: `Caddie/Tests/MeetingDetectorTests.swift`

**Context:** The orchestrator combines signals from all 4 monitors and applies the decision logic: 2+ signals = meeting confirmed. It manages the grace period for meeting end detection and determines the meeting title.

- [ ] **Step 1: Write orchestrator tests with mock signals**

Create `Caddie/Tests/MeetingDetectorTests.swift`:

```swift
import XCTest
@testable import Caddie

final class MeetingDetectorTests: XCTestCase {

    func testNoSignals_noMeeting() {
        let detector = MeetingDetector.DecisionEngine()
        let result = detector.evaluate(signals: [])
        XCTAssertNil(result)
    }

    func testSingleSignal_noMeeting() {
        let detector = MeetingDetector.DecisionEngine()
        let result = detector.evaluate(signals: [
            DetectionSignal(source: .micState, appName: nil, processId: nil, windowTitle: nil, calendarEvent: nil, isActive: true)
        ])
        XCTAssertNil(result, "Single signal should not confirm a meeting")
    }

    func testAudioProcess_plus_mic_confirmsMeeting() {
        let detector = MeetingDetector.DecisionEngine()
        let result = detector.evaluate(signals: [
            DetectionSignal(source: .audioProcess, appName: "Zoom", processId: 123, windowTitle: nil, calendarEvent: nil, isActive: true),
            DetectionSignal(source: .micState, appName: nil, processId: nil, windowTitle: nil, calendarEvent: nil, isActive: true),
        ])
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.app, "Zoom")
    }

    func testWindowTitle_plus_calendar_confirmsMeeting() {
        let detector = MeetingDetector.DecisionEngine()
        let result = detector.evaluate(signals: [
            DetectionSignal(source: .windowTitle, appName: "Google Meet", processId: nil, windowTitle: "Budget Review", calendarEvent: nil, isActive: true),
            DetectionSignal(source: .calendar, appName: nil, processId: nil, windowTitle: nil, calendarEvent: "Q3 Budget Review", isActive: true),
        ])
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.app, "Google Meet")
        // Calendar title should take priority
        XCTAssertEqual(result?.title, "Q3 Budget Review")
    }

    func testTitlePriority_calendarOverWindow() {
        let detector = MeetingDetector.DecisionEngine()
        let result = detector.evaluate(signals: [
            DetectionSignal(source: .audioProcess, appName: "Zoom", processId: 123, windowTitle: nil, calendarEvent: nil, isActive: true),
            DetectionSignal(source: .micState, appName: nil, processId: nil, windowTitle: nil, calendarEvent: nil, isActive: true),
            DetectionSignal(source: .windowTitle, appName: "Zoom", processId: nil, windowTitle: "Zoom Meeting", calendarEvent: nil, isActive: true),
            DetectionSignal(source: .calendar, appName: nil, processId: nil, windowTitle: nil, calendarEvent: "Weekly Standup", isActive: true),
        ])
        XCTAssertEqual(result?.title, "Weekly Standup")
    }

    func testTitleFallback_appNameWhenNoOtherTitle() {
        let detector = MeetingDetector.DecisionEngine()
        let result = detector.evaluate(signals: [
            DetectionSignal(source: .audioProcess, appName: "Zoom", processId: 123, windowTitle: nil, calendarEvent: nil, isActive: true),
            DetectionSignal(source: .micState, appName: nil, processId: nil, windowTitle: nil, calendarEvent: nil, isActive: true),
        ])
        XCTAssertEqual(result?.title, "Zoom Meeting")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: `MeetingDetector` and `DecisionEngine` not defined.

- [ ] **Step 3: Write MeetingDetector.swift**

Create `Caddie/Sources/Detection/MeetingDetector.swift`:

```swift
import Foundation
import os

/// Detected meeting info
struct DetectedMeeting {
    let app: String
    let title: String
    let processId: pid_t?
}

/// Orchestrates all detection monitors, applies decision logic, manages grace period.
@Observable
final class MeetingDetector {
    private let logger = Logger(subsystem: "com.caddie.app", category: "MeetingDetector")

    private var audioProcessMonitor = AudioProcessMonitor()
    private var micStateMonitor = MicStateMonitor()
    private var windowTitleMonitor = WindowTitleMonitor()
    private var calendarMonitor = CalendarMonitor()

    private var activeSignals: [DetectionSignal] = []
    private var graceTimer: Timer?
    private var graceTicks: Int = 0

    var onMeetingStarted: ((DetectedMeeting) -> Void)?
    var onMeetingEnded: (() -> Void)?

    var isDetectingMeeting: Bool = false
    var currentMeeting: DetectedMeeting?

    /// Grace period in seconds before declaring meeting over (default 15s)
    var graceSeconds: TimeInterval = 15.0

    func start() {
        let handler: (DetectionSignal) -> Void = { [weak self] signal in
            self?.handleSignal(signal)
        }

        audioProcessMonitor.onSignal = handler
        micStateMonitor.onSignal = handler
        windowTitleMonitor.onSignal = handler
        calendarMonitor.onSignal = handler

        audioProcessMonitor.start()
        micStateMonitor.start()
        windowTitleMonitor.start()
        calendarMonitor.start()

        logger.info("Meeting detector started")
    }

    func stop() {
        audioProcessMonitor.stop()
        micStateMonitor.stop()
        windowTitleMonitor.stop()
        calendarMonitor.stop()
        graceTimer?.invalidate()
        logger.info("Meeting detector stopped")
    }

    private func handleSignal(_ signal: DetectionSignal) {
        // Update active signals
        activeSignals.removeAll { $0.source == signal.source && $0.appName == signal.appName }
        if signal.isActive {
            activeSignals.append(signal)
        }

        // Run decision logic
        let engine = DecisionEngine()
        let detected = engine.evaluate(signals: activeSignals)

        if let meeting = detected, !isDetectingMeeting {
            // Meeting just started
            isDetectingMeeting = true
            currentMeeting = meeting
            graceTimer?.invalidate()
            graceTicks = 0
            logger.info("Meeting started: \(meeting.app) — \"\(meeting.title)\"")
            onMeetingStarted?(meeting)
        } else if let meeting = detected, isDetectingMeeting {
            // Meeting still active — update title if better one found
            if meeting.title != currentMeeting?.title && meeting.title != "\(meeting.app) Meeting" {
                currentMeeting = meeting
            }
            graceTimer?.invalidate()
            graceTicks = 0
        } else if detected == nil && isDetectingMeeting {
            // No meeting signals — start grace period
            startGracePeriod()
        }
    }

    private func startGracePeriod() {
        guard graceTimer == nil || !graceTimer!.isValid else { return }
        graceTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.graceTicks += 1
            let elapsed = Double(self.graceTicks) * 3.0
            if elapsed >= self.graceSeconds {
                self.graceTimer?.invalidate()
                self.graceTicks = 0
                self.isDetectingMeeting = false
                self.currentMeeting = nil
                self.activeSignals.removeAll()
                self.logger.info("Meeting ended (grace period expired)")
                self.onMeetingEnded?()
            }
        }
    }

    // MARK: - Decision Engine (pure logic, testable)

    struct DecisionEngine {
        func evaluate(signals: [DetectionSignal]) -> DetectedMeeting? {
            let active = signals.filter(\.isActive)
            guard active.count >= 2 else { return nil }

            let hasAudioProcess = active.contains { $0.source == .audioProcess }
            let hasMic = active.contains { $0.source == .micState }
            let hasWindowTitle = active.contains { $0.source == .windowTitle }
            let hasCalendar = active.contains { $0.source == .calendar }

            let confirmed = (hasAudioProcess && hasMic)
                         || (hasAudioProcess && hasWindowTitle)
                         || (hasMic && hasCalendar)
                         || (hasWindowTitle && hasCalendar)

            guard confirmed else { return nil }

            // Determine app name
            let appName = active.compactMap(\.appName).first ?? "Unknown"

            // Determine title (priority: calendar > window > fallback)
            let calendarTitle = active.compactMap(\.calendarEvent).first
            let windowTitle = active.compactMap(\.windowTitle).first
            let title = calendarTitle ?? windowTitle ?? "\(appName) Meeting"

            // Determine PID
            let pid = active.compactMap(\.processId).first

            return DetectedMeeting(app: appName, title: title, processId: pid)
        }
    }
}
```

- [ ] **Step 4: Run tests**

```bash
cd Caddie
xcodegen generate
xcodebuild test -project Caddie.xcodeproj -scheme CaddieTests -destination 'platform=macOS' 2>&1 | grep -E '(Test Case|PASS|FAIL)'
```

Expected: All MeetingDetectorTests pass.

- [ ] **Step 5: Commit**

```bash
git add Caddie/
git commit -m "feat: add meeting detector orchestrator with decision logic and grace period"
```

---

## Task 6: Audio Capture — CoreAudio Taps + AVAudioEngine

**Files:**
- Create: `Caddie/Sources/Recording/SystemAudioCapture.swift`
- Create: `Caddie/Sources/Recording/MicrophoneCapture.swift`
- Create: `Caddie/Sources/Recording/AudioRecorder.swift`

**Context:** This is the hardest system integration — CoreAudio Taps (macOS 14.2+) for system audio and AVAudioEngine for microphone. The two streams are written as separate channels in a stereo WAV file. Reference: AudioCap by insidegui, AudioTee by makeusabrew.

- [ ] **Step 1: Write SystemAudioCapture.swift**

Create `Caddie/Sources/Recording/SystemAudioCapture.swift`. This uses the CoreAudio Tap API to capture a specific process's audio output. Reference: `github.com/insidegui/AudioCap/blob/main/AudioCap/ProcessTap/CoreAudioUtils.swift`

```swift
import Foundation
import CoreAudio
import AudioToolbox
import os

/// Captures system audio from a specific process using CoreAudio Taps (macOS 14.2+).
/// Outputs raw PCM buffers via a callback.
final class SystemAudioCapture {
    typealias BufferCallback = (UnsafeBufferPointer<Int16>, Int) -> Void

    private let logger = Logger(subsystem: "com.caddie.app", category: "SystemAudioCapture")
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var audioUnit: AudioComponentInstance?
    private var callback: BufferCallback?
    private let sampleRate: Float64 = 16000
    private var isRunning = false

    func start(processID: pid_t?, onBuffer: @escaping BufferCallback) throws {
        self.callback = onBuffer

        // 1. Create process tap
        try createProcessTap(processID: processID)

        // 2. Create aggregate device with the tap
        try createAggregateDevice()

        // 3. Set up AudioUnit to read from aggregate device
        try setupAudioUnit()

        // 4. Start
        let status = AudioOutputUnitStart(audioUnit!)
        guard status == noErr else {
            throw CaptureError.startFailed(status)
        }
        isRunning = true
        logger.info("System audio capture started (PID: \(processID ?? -1))")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        if let unit = audioUnit {
            AudioOutputUnitStop(unit)
            AudioComponentInstanceDispose(unit)
            audioUnit = nil
        }

        // Cleanup aggregate device
        if aggregateDeviceID != kAudioObjectUnknown {
            // The device is cleaned up when the process exits
            aggregateDeviceID = kAudioObjectUnknown
        }

        logger.info("System audio capture stopped")
    }

    // MARK: - Private

    private func createProcessTap(processID: pid_t?) throws {
        // CATapDescription is the entry point for the macOS 14.2+ tap API
        // This requires Screen Recording permission
        var description = CATapDescription()

        if let pid = processID {
            description = CATapDescription(processes: [pid])
        }
        description.isMutedWhenTapped = false

        var newTapID: AudioObjectID = kAudioObjectUnknown
        let status = CATapCreate(kAudioObjectSystemObject, description, &newTapID)
        guard status == noErr else {
            throw CaptureError.tapCreateFailed(status)
        }
        self.tapID = newTapID
    }

    private func createAggregateDevice() throws {
        // Get default output device UID
        var defaultDeviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &defaultDeviceID)

        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        AudioObjectGetPropertyData(defaultDeviceID, &address, 0, nil, &size, &uid)

        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "CaddieTap",
            kAudioAggregateDeviceUIDKey as String: "com.caddie.tap.\(ProcessInfo.processInfo.processIdentifier)",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [[kAudioSubTapUIDKey as String: "\(tapID)"]],
            kAudioAggregateDeviceMainSubDeviceKey as String: uid,
            kAudioAggregateDeviceSubDeviceListKey as String: [[kAudioSubDeviceUIDKey as String: uid]],
            kAudioAggregateDeviceTapAutoStartKey as String: true,
        ]

        var aggDeviceID: AudioDeviceID = kAudioObjectUnknown
        let status = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggDeviceID)
        guard status == noErr else {
            throw CaptureError.aggregateDeviceFailed(status)
        }
        self.aggregateDeviceID = aggDeviceID

        // Brief delay to let the aggregate device stabilize (known CoreAudio quirk)
        CFRunLoopRunInMode(.defaultMode, 0.1, false)
    }

    private func setupAudioUnit() throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw CaptureError.noHALOutput
        }

        var unit: AudioComponentInstance?
        AudioComponentInstanceNew(component, &unit)
        guard let audioUnit = unit else { throw CaptureError.noHALOutput }

        // Enable input, disable output
        var enable: UInt32 = 1
        AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, UInt32(MemoryLayout<UInt32>.size))
        var disable: UInt32 = 0
        AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable, UInt32(MemoryLayout<UInt32>.size))

        // Set aggregate device as input
        var deviceID = aggregateDeviceID
        AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))

        // Set output format: 16kHz mono 16-bit
        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0
        )
        AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

        // Set render callback
        var callbackStruct = AURenderCallbackStruct(
            inputProc: { (inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData) -> OSStatus in
                let capture = Unmanaged<SystemAudioCapture>.fromOpaque(inRefCon).takeUnretainedValue()
                let bufferSize = inNumberFrames * 2 // 16-bit = 2 bytes per frame
                let buffer = UnsafeMutablePointer<Int16>.allocate(capacity: Int(inNumberFrames))
                defer { buffer.deallocate() }

                var bufferList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: bufferSize, mData: buffer)
                )

                guard let unit = capture.audioUnit else { return noErr }
                let status = AudioUnitRender(unit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, &bufferList)
                if status == noErr {
                    let ptr = UnsafeBufferPointer(start: buffer, count: Int(inNumberFrames))
                    capture.callback?(ptr, Int(inNumberFrames))
                }
                return noErr
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        AudioUnitInitialize(audioUnit)
        self.audioUnit = audioUnit
    }

    enum CaptureError: Error {
        case tapCreateFailed(OSStatus)
        case aggregateDeviceFailed(OSStatus)
        case noHALOutput
        case startFailed(OSStatus)
    }
}
```

- [ ] **Step 2: Write MicrophoneCapture.swift**

Create `Caddie/Sources/Recording/MicrophoneCapture.swift`:

```swift
import Foundation
import AVFoundation
import os

/// Captures microphone audio via AVAudioEngine.
/// Outputs 16kHz mono 16-bit PCM buffers via callback.
final class MicrophoneCapture {
    typealias BufferCallback = (UnsafeBufferPointer<Int16>, Int) -> Void

    private let logger = Logger(subsystem: "com.caddie.app", category: "MicrophoneCapture")
    private let engine = AVAudioEngine()
    private var callback: BufferCallback?

    func start(onBuffer: @escaping BufferCallback) throws {
        self.callback = onBuffer

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Target format: 16kHz mono 16-bit signed integer
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else {
            throw MicError.invalidFormat
        }

        // Install converter if sample rates differ
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw MicError.converterFailed
        }

        let bufferSize: AVAudioFrameCount = 4096

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, time in
            guard let self else { return }

            let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * 16000.0 / buffer.format.sampleRate)
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }

            var error: NSError?
            converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if let int16Data = outputBuffer.int16ChannelData {
                let ptr = UnsafeBufferPointer(start: int16Data[0], count: Int(outputBuffer.frameLength))
                self.callback?(ptr, Int(outputBuffer.frameLength))
            }
        }

        try engine.start()
        logger.info("Microphone capture started")
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        logger.info("Microphone capture stopped")
    }

    enum MicError: Error {
        case invalidFormat
        case converterFailed
    }
}
```

- [ ] **Step 3: Write AudioRecorder.swift**

Create `Caddie/Sources/Recording/AudioRecorder.swift`:

```swift
import Foundation
import AudioToolbox
import os

/// Orchestrates SystemAudioCapture + MicrophoneCapture into a stereo WAV file.
/// Channel 0 = system audio (remote participants), Channel 1 = microphone (you).
final class AudioRecorder {
    private let logger = Logger(subsystem: "com.caddie.app", category: "AudioRecorder")
    private let systemCapture = SystemAudioCapture()
    private let micCapture = MicrophoneCapture()
    private var audioFile: ExtAudioFileRef?
    private var isRecording = false

    private let sampleRate: Float64 = 16000
    private let lock = NSLock()
    private var systemBuffer: [Int16] = []
    private var micBuffer: [Int16] = []

    /// Start recording to a stereo WAV file
    func start(outputPath: URL, processID: pid_t?) throws {
        guard !isRecording else { return }

        try AudioFileManager.ensureDirectoryExists()

        // Create stereo WAV file (2 channels, 16kHz, 16-bit)
        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,  // 2 bytes * 2 channels
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        var file: ExtAudioFileRef?
        let status = ExtAudioFileCreateWithURL(
            outputPath as CFURL,
            kAudioFileWAVEType,
            &format,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &file
        )
        guard status == noErr, let audioFile = file else {
            throw RecorderError.cannotCreateFile(status)
        }
        self.audioFile = audioFile

        // Start capturing both streams
        try systemCapture.start(processID: processID) { [weak self] buffer, count in
            self?.lock.lock()
            self?.systemBuffer.append(contentsOf: buffer)
            self?.lock.unlock()
            self?.flushIfReady()
        }

        try micCapture.start { [weak self] buffer, count in
            self?.lock.lock()
            self?.micBuffer.append(contentsOf: buffer)
            self?.lock.unlock()
            self?.flushIfReady()
        }

        isRecording = true
        logger.info("Recording started: \(outputPath.lastPathComponent)")
    }

    /// Stop recording
    func stop() {
        guard isRecording else { return }
        isRecording = false

        systemCapture.stop()
        micCapture.stop()

        // Flush remaining buffers
        flushRemaining()

        if let file = audioFile {
            ExtAudioFileDispose(file)
            audioFile = nil
        }

        logger.info("Recording stopped")
    }

    /// Interleave and write when both buffers have enough samples
    private func flushIfReady() {
        lock.lock()
        let minCount = min(systemBuffer.count, micBuffer.count)
        guard minCount >= 1600 else { // ~100ms at 16kHz
            lock.unlock()
            return
        }

        let count = minCount
        let sys = Array(systemBuffer.prefix(count))
        let mic = Array(micBuffer.prefix(count))
        systemBuffer.removeFirst(count)
        micBuffer.removeFirst(count)
        lock.unlock()

        writeInterleavedStereo(system: sys, mic: mic)
    }

    private func flushRemaining() {
        lock.lock()
        let count = min(systemBuffer.count, micBuffer.count)
        if count > 0 {
            let sys = Array(systemBuffer.prefix(count))
            let mic = Array(micBuffer.prefix(count))
            lock.unlock()
            writeInterleavedStereo(system: sys, mic: mic)
        } else {
            lock.unlock()
        }
    }

    private func writeInterleavedStereo(system: [Int16], mic: [Int16]) {
        guard let file = audioFile else { return }

        // Interleave: [sys0, mic0, sys1, mic1, ...]
        var interleaved = [Int16](repeating: 0, count: system.count * 2)
        for i in 0..<system.count {
            interleaved[i * 2] = system[i]
            interleaved[i * 2 + 1] = mic[i]
        }

        interleaved.withUnsafeBufferPointer { ptr in
            var bufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32(ptr.count * MemoryLayout<Int16>.size),
                    mData: UnsafeMutableRawPointer(mutating: ptr.baseAddress!)
                )
            )
            ExtAudioFileWrite(file, UInt32(system.count), &bufferList)
        }
    }

    enum RecorderError: Error {
        case cannotCreateFile(OSStatus)
    }
}
```

- [ ] **Step 4: Build to verify compilation**

```bash
cd Caddie
xcodegen generate
xcodebuild -project Caddie.xcodeproj -scheme Caddie build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Caddie/
git commit -m "feat: add audio recording — CoreAudio Taps + AVAudioEngine → stereo WAV"
```

---

## Task 7: Transcription Pipeline + Transcript Merger

**Files:**
- Create: `Caddie/Sources/Transcription/TranscriptMerger.swift`
- Create: `Caddie/Sources/Transcription/ASREngine.swift`
- Create: `Caddie/Sources/Transcription/DiarizationEngine.swift`
- Create: `Caddie/Sources/Transcription/TranscriptionPipeline.swift`
- Test: `Caddie/Tests/TranscriptMergerTests.swift`

**Context:** The transcription pipeline runs after meeting ends. FluidAudio provides both Parakeet ASR and pyannote diarization. The TranscriptMerger aligns ASR segments with speaker labels by temporal overlap — this is pure algorithm and fully testable. The ASR/diarization engines are thin wrappers around FluidAudio APIs.

**Note:** FluidAudio's exact Swift API will need to be verified against their documentation. The code below uses placeholder API calls that should be updated once the SDK is integrated.

- [ ] **Step 1: Write TranscriptMerger tests**

Create `Caddie/Tests/TranscriptMergerTests.swift`:

```swift
import XCTest
@testable import Caddie

final class TranscriptMergerTests: XCTestCase {

    func testSimpleMerge_noOverlap() {
        let asrSegments: [ASRSegment] = [
            ASRSegment(start: 0.0, end: 3.0, text: "Hello everyone"),
            ASRSegment(start: 3.5, end: 7.0, text: "Let's get started"),
        ]
        let speakerSegments: [SpeakerSegment] = [
            SpeakerSegment(start: 0.0, end: 4.0, speaker: "SPEAKER_00"),
            SpeakerSegment(start: 4.0, end: 8.0, speaker: "SPEAKER_01"),
        ]

        let merged = TranscriptMerger.merge(asr: asrSegments, speakers: speakerSegments)

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].speaker, "SPEAKER_00")
        XCTAssertEqual(merged[0].text, "Hello everyone")
        XCTAssertEqual(merged[1].speaker, "SPEAKER_01")
        XCTAssertEqual(merged[1].text, "Let's get started")
    }

    func testMerge_overlappingSpeakers() {
        let asrSegments: [ASRSegment] = [
            ASRSegment(start: 2.0, end: 5.0, text: "This segment spans two speakers"),
        ]
        let speakerSegments: [SpeakerSegment] = [
            SpeakerSegment(start: 0.0, end: 3.0, speaker: "SPEAKER_00"), // 1s overlap
            SpeakerSegment(start: 3.0, end: 6.0, speaker: "SPEAKER_01"), // 2s overlap
        ]

        let merged = TranscriptMerger.merge(asr: asrSegments, speakers: speakerSegments)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].speaker, "SPEAKER_01") // More overlap
    }

    func testMerge_noSpeakerSegments() {
        let asrSegments: [ASRSegment] = [
            ASRSegment(start: 0.0, end: 3.0, text: "Hello"),
        ]

        let merged = TranscriptMerger.merge(asr: asrSegments, speakers: [])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].speaker, "Speaker")
    }

    func testFullTextGeneration() {
        let segments: [TranscriptSegment] = [
            TranscriptSegment(start: 0.0, end: 3.0, text: "Hello", speaker: "SPEAKER_00", words: []),
            TranscriptSegment(start: 3.0, end: 6.0, text: "Hi there", speaker: "SPEAKER_01", words: []),
            TranscriptSegment(start: 6.0, end: 9.0, text: "Let's begin", speaker: "SPEAKER_00", words: []),
        ]

        let fullText = TranscriptMerger.generateFullText(segments: segments)

        XCTAssertTrue(fullText.contains("[SPEAKER_00]"))
        XCTAssertTrue(fullText.contains("Hello"))
        XCTAssertTrue(fullText.contains("[SPEAKER_01]"))
        XCTAssertTrue(fullText.contains("Hi there"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: `ASRSegment`, `SpeakerSegment`, `TranscriptMerger` not defined.

- [ ] **Step 3: Write TranscriptMerger.swift**

Create `Caddie/Sources/Transcription/TranscriptMerger.swift`:

```swift
import Foundation

/// A segment from the ASR engine (Parakeet)
struct ASRSegment {
    let start: Double
    let end: Double
    let text: String
    var words: [WordTimestamp] = []
}

struct WordTimestamp: Codable {
    let word: String
    let start: Double
    let end: Double
}

/// A segment from the diarization engine (pyannote)
struct SpeakerSegment {
    let start: Double
    let end: Double
    let speaker: String
}

/// A merged transcript segment with speaker label
struct TranscriptSegment: Codable {
    let start: Double
    let end: Double
    let text: String
    let speaker: String
    let words: [WordTimestamp]
}

/// The complete transcript for a meeting
struct Transcript: Codable {
    let language: String
    let duration: Double
    let numSegments: Int
    let numSpeakers: Int
    let processingTimeSeconds: Double
    let fullText: String
    let segments: [TranscriptSegment]
}

enum TranscriptMerger {
    /// Align ASR segments with speaker segments by maximum temporal overlap
    static func merge(asr: [ASRSegment], speakers: [SpeakerSegment]) -> [TranscriptSegment] {
        return asr.map { asrSeg in
            let speaker = bestSpeaker(for: asrSeg, from: speakers)
            return TranscriptSegment(
                start: asrSeg.start,
                end: asrSeg.end,
                text: asrSeg.text.trimmingCharacters(in: .whitespaces),
                speaker: speaker,
                words: asrSeg.words
            )
        }
    }

    /// Find the speaker with maximum temporal overlap for a given ASR segment
    private static func bestSpeaker(for segment: ASRSegment, from speakers: [SpeakerSegment]) -> String {
        guard !speakers.isEmpty else { return "Speaker" }

        var bestSpeaker = "Unknown"
        var bestOverlap: Double = 0

        for sp in speakers {
            let overlapStart = max(segment.start, sp.start)
            let overlapEnd = min(segment.end, sp.end)
            let overlap = max(0, overlapEnd - overlapStart)

            if overlap > bestOverlap {
                bestOverlap = overlap
                bestSpeaker = sp.speaker
            }
        }

        return bestSpeaker
    }

    /// Generate readable full text with speaker labels
    static func generateFullText(segments: [TranscriptSegment]) -> String {
        var lines: [String] = []
        var currentSpeaker: String?

        for seg in segments {
            if seg.speaker != currentSpeaker {
                if !lines.isEmpty { lines.append("") }
                lines.append("[\(seg.speaker)]")
                currentSpeaker = seg.speaker
            }
            lines.append(seg.text)
        }

        return lines.joined(separator: "\n")
    }
}
```

- [ ] **Step 4: Write ASREngine.swift and DiarizationEngine.swift (FluidAudio wrappers)**

Create `Caddie/Sources/Transcription/ASREngine.swift`:

```swift
import Foundation
import os

/// Wrapper around FluidAudio Parakeet ASR.
/// TODO: Update API calls once FluidAudio SDK is integrated.
final class ASREngine {
    private let logger = Logger(subsystem: "com.caddie.app", category: "ASREngine")

    /// Transcribe a WAV file and return ASR segments with word timestamps
    func transcribe(audioURL: URL) async throws -> (segments: [ASRSegment], language: String, duration: Double) {
        logger.info("Starting ASR transcription: \(audioURL.lastPathComponent)")

        // TODO: Replace with actual FluidAudio Parakeet API
        // Example expected API:
        //   let recognizer = FluidASR(model: .parakeetTDT06Bv3)
        //   let result = try await recognizer.transcribe(audioURL)
        //   return result.segments.map { ASRSegment(start: $0.start, end: $0.end, text: $0.text, words: ...) }

        throw ASRError.notImplemented("FluidAudio SDK integration pending")
    }

    enum ASRError: Error {
        case notImplemented(String)
        case modelNotLoaded
        case transcriptionFailed(String)
    }
}
```

Create `Caddie/Sources/Transcription/DiarizationEngine.swift`:

```swift
import Foundation
import os

/// Wrapper around FluidAudio pyannote diarization.
/// TODO: Update API calls once FluidAudio SDK is integrated.
final class DiarizationEngine {
    private let logger = Logger(subsystem: "com.caddie.app", category: "DiarizationEngine")

    /// Run speaker diarization on a WAV file and return speaker segments
    func diarize(audioURL: URL) async throws -> [SpeakerSegment] {
        logger.info("Starting diarization: \(audioURL.lastPathComponent)")

        // TODO: Replace with actual FluidAudio pyannote API
        // Example expected API:
        //   let diarizer = FluidDiarizer(model: .pyannoteV4)
        //   let result = try await diarizer.diarize(audioURL)
        //   return result.segments.map { SpeakerSegment(start: $0.start, end: $0.end, speaker: $0.speaker) }

        throw DiarizationError.notImplemented("FluidAudio SDK integration pending")
    }

    enum DiarizationError: Error {
        case notImplemented(String)
        case modelNotLoaded
        case diarizationFailed(String)
    }
}
```

- [ ] **Step 5: Write TranscriptionPipeline.swift**

Create `Caddie/Sources/Transcription/TranscriptionPipeline.swift`:

```swift
import Foundation
import os

/// Queued transcription pipeline: ASR → Diarization → Merge → Compress
/// Runs after meeting ends. Respects priority (recording > transcription).
actor TranscriptionPipeline {
    private let logger = Logger(subsystem: "com.caddie.app", category: "TranscriptionPipeline")
    private let asr = ASREngine()
    private let diarizer = DiarizationEngine()
    private var queue: [String] = [] // meeting IDs
    private var isProcessing = false

    func enqueue(meetingId: String) {
        queue.append(meetingId)
        logger.info("Transcription queued: \(meetingId)")
        Task { await processNext() }
    }

    private func processNext() async {
        guard !isProcessing, let meetingId = queue.first else { return }
        isProcessing = true
        queue.removeFirst()

        // TODO: Update meeting status to .transcribing in DB

        let wavURL = AudioFileManager.wavPath(for: meetingId)
        let alacURL = AudioFileManager.alacPath(for: meetingId)
        let startTime = Date()

        do {
            // Step 1: ASR (mono mixdown for Parakeet)
            logger.info("Step 1/4: ASR transcription for \(meetingId)")
            let (asrSegments, language, duration) = try await asr.transcribe(audioURL: wavURL)

            // Step 2: Diarization (uses stereo for channel-based speaker hints)
            logger.info("Step 2/4: Speaker diarization for \(meetingId)")
            let speakerSegments = try await diarizer.diarize(audioURL: wavURL)

            // Step 3: Merge
            logger.info("Step 3/4: Merging transcript with speakers for \(meetingId)")
            let merged = TranscriptMerger.merge(asr: asrSegments, speakers: speakerSegments)
            let fullText = TranscriptMerger.generateFullText(segments: merged)

            let transcript = Transcript(
                language: language,
                duration: duration,
                numSegments: merged.count,
                numSpeakers: Set(merged.map(\.speaker)).count,
                processingTimeSeconds: Date().timeIntervalSince(startTime),
                fullText: fullText,
                segments: merged
            )

            // Step 4: Compress WAV → ALAC
            logger.info("Step 4/4: Compressing audio for \(meetingId)")
            try AudioFileManager.compressToALAC(wavURL: wavURL, outputURL: alacURL)

            // Delete original WAV
            try? FileManager.default.removeItem(at: wavURL)

            // TODO: Save transcript to DB, update status to .done
            let transcriptJSON = try JSONEncoder().encode(transcript)
            let transcriptString = String(data: transcriptJSON, encoding: .utf8) ?? ""
            logger.info("Transcription complete: \(meetingId) (\(transcript.numSegments) segments, \(transcript.numSpeakers) speakers)")

        } catch {
            logger.error("Transcription failed for \(meetingId): \(error)")
            // TODO: Update meeting status to .error in DB
        }

        isProcessing = false
        await processNext() // Process next in queue
    }
}
```

- [ ] **Step 6: Run merger tests**

```bash
cd Caddie
xcodegen generate
xcodebuild test -project Caddie.xcodeproj -scheme CaddieTests -destination 'platform=macOS' 2>&1 | grep -E '(Test Case|PASS|FAIL)'
```

Expected: All TranscriptMergerTests pass.

- [ ] **Step 7: Commit**

```bash
git add Caddie/
git commit -m "feat: add transcription pipeline — ASR engine, diarization engine, transcript merger"
```

---

## Task 8: Model Manager + Utilities

**Files:**
- Create: `Caddie/Sources/Models/ModelManager.swift`
- Create: `Caddie/Sources/Utilities/Logger.swift`
- Create: `Caddie/Sources/Utilities/Permissions.swift`

**Context:** ModelManager downloads CoreML models from HuggingFace on first launch. Logger provides structured logging with file output. Permissions wraps TCC status checks.

- [ ] **Step 1: Write ModelManager.swift**

Create `Caddie/Sources/Models/ModelManager.swift`:

```swift
import Foundation
import os

/// Downloads and caches CoreML models from HuggingFace
@Observable
final class ModelManager {
    private let logger = Logger(subsystem: "com.caddie.app", category: "ModelManager")

    var isDownloading = false
    var downloadProgress: Double = 0
    var downloadError: String?

    var modelsReady: Bool {
        asrModelExists && diarizationModelExists
    }

    static var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Caddie/models", isDirectory: true)
    }

    private var asrModelExists: Bool {
        FileManager.default.fileExists(atPath: Self.modelsDirectory.appendingPathComponent("parakeet").path)
    }

    private var diarizationModelExists: Bool {
        FileManager.default.fileExists(atPath: Self.modelsDirectory.appendingPathComponent("diarization").path)
    }

    func downloadModelsIfNeeded() async {
        guard !modelsReady else {
            logger.info("Models already downloaded")
            return
        }

        isDownloading = true
        downloadProgress = 0
        downloadError = nil

        do {
            try FileManager.default.createDirectory(at: Self.modelsDirectory, withIntermediateDirectories: true)

            // TODO: Replace with actual FluidAudio model download API
            // FluidAudio likely handles model download internally.
            // If not, download from HuggingFace:
            //   - FluidInference/parakeet-tdt-0.6b-v3-coreml
            //   - FluidInference/speaker-diarization-coreml

            logger.info("Model download would start here")
            downloadProgress = 1.0
            isDownloading = false
        } catch {
            downloadError = error.localizedDescription
            isDownloading = false
            logger.error("Model download failed: \(error)")
        }
    }

    /// Check model integrity and re-download if corrupted
    func verifyModels() async -> Bool {
        // TODO: Verify CoreML model files are valid
        return modelsReady
    }
}
```

- [ ] **Step 2: Write Logger.swift**

Create `Caddie/Sources/Utilities/Logger.swift`:

```swift
import Foundation
import os

enum CaddieLogger {
    static let subsystem = "com.caddie.app"

    static let app = Logger(subsystem: subsystem, category: "App")
    static let detection = Logger(subsystem: subsystem, category: "Detection")
    static let recording = Logger(subsystem: subsystem, category: "Recording")
    static let transcription = Logger(subsystem: subsystem, category: "Transcription")
    static let storage = Logger(subsystem: subsystem, category: "Storage")

    /// Open the log directory in Finder
    static func showLogs() {
        let logDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/Caddie")
        NSWorkspace.shared.open(logDir)
    }
}
```

- [ ] **Step 3: Write Permissions.swift**

Create `Caddie/Sources/Utilities/Permissions.swift`:

```swift
import Foundation
import AVFoundation
import os

enum PermissionStatus {
    case granted, denied, undetermined
}

enum Permissions {
    private static let logger = Logger(subsystem: "com.caddie.app", category: "Permissions")

    /// Check microphone permission status
    static var microphone: PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .undetermined
        @unknown default: return .undetermined
        }
    }

    /// Request microphone permission
    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Check if Screen Recording permission is granted
    /// (No official API — we infer from CGWindowListCopyWindowInfo behavior)
    static var screenRecording: PermissionStatus {
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        // If we can read window names, we have permission
        let hasNames = windowList.contains { $0[kCGWindowName as String] != nil }
        return hasNames ? .granted : .denied
    }

    /// Check if Accessibility permission is granted
    static var accessibility: PermissionStatus {
        AXIsProcessTrusted() ? .granted : .denied
    }

    /// Prompt user to grant Accessibility permission
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
```

- [ ] **Step 4: Build and verify**

```bash
cd Caddie
xcodegen generate
xcodebuild -project Caddie.xcodeproj -scheme Caddie build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Caddie/
git commit -m "feat: add model manager, logger, and permission utilities"
```

---

## Task 9: Menu Bar UI + App State Integration

**Files:**
- Create: `Caddie/Sources/UI/MenuBar/MenuBarView.swift`
- Create: `Caddie/Sources/UI/MenuBar/RecordingIndicator.swift`
- Create: `Caddie/Sources/UI/Shared/StatusDot.swift`
- Create: `Caddie/Sources/UI/Shared/SpeakerBadge.swift`
- Modify: `Caddie/Sources/App/CaddieApp.swift` (wire up detection + recording)

**Context:** Connect the app shell to the detection and recording systems. The menu bar shows current state and provides quick access to recent meetings.

- [ ] **Step 1: Write RecordingIndicator.swift**

Create `Caddie/Sources/UI/MenuBar/RecordingIndicator.swift`:

```swift
import SwiftUI

struct RecordingIndicator: View {
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 8, height: 8)
            .shadow(color: .red.opacity(isPulsing ? 0.6 : 0), radius: 4)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}
```

- [ ] **Step 2: Write StatusDot.swift**

Create `Caddie/Sources/UI/Shared/StatusDot.swift`:

```swift
import SwiftUI

struct StatusDot: View {
    let status: MeetingStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
    }

    private var color: Color {
        switch status {
        case .done: .green
        case .recording: .red
        case .transcribing: .orange
        case .error: .red
        }
    }
}
```

- [ ] **Step 3: Write SpeakerBadge.swift**

Create `Caddie/Sources/UI/Shared/SpeakerBadge.swift`:

```swift
import SwiftUI

struct SpeakerBadge: View {
    let speaker: String

    private static let colors: [Color] = [.blue, .green, .purple, .orange, .pink, .teal, .indigo, .mint]

    var body: some View {
        Text(speaker)
            .font(.caption2.monospaced().bold())
            .foregroundStyle(color)
    }

    private var color: Color {
        let index = abs(speaker.hashValue) % Self.colors.count
        return Self.colors[index]
    }
}
```

- [ ] **Step 4: Write MenuBarView.swift**

Create `Caddie/Sources/UI/MenuBar/MenuBarView.swift`:

```swift
import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Status section
            switch appState.status {
            case .idle:
                Label("No active meeting", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            case .recording:
                HStack {
                    RecordingIndicator()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(appState.currentMeetingTitle ?? "Recording...")
                            .fontWeight(.medium)
                        Text(Formatters.duration(seconds: Int(appState.recordingDuration)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Button("Stop Recording") {
                    // TODO: Stop recording via AppState
                }
                .padding(.horizontal, 12)
            case .transcribing:
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Transcribing...")
                        .foregroundStyle(.orange)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            Divider()

            // Quick actions
            Button("Open Caddie") {
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("o")
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Divider()

            Button("Preferences...") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            .keyboardShortcut(",")
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Button("Quit Caddie") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .padding(.vertical, 4)
        .frame(width: 240)
    }
}
```

- [ ] **Step 5: Update CaddieApp.swift to wire everything together**

Replace `Caddie/Sources/App/CaddieApp.swift`:

```swift
import SwiftUI

@main
struct CaddieApp: App {
    @State private var appState = AppState()
    @State private var detector = MeetingDetector()
    @State private var recorder = AudioRecorder()
    @State private var pipeline = TranscriptionPipeline()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
        } label: {
            Image(systemName: menuBarIcon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(menuBarColor)
        }

        WindowGroup {
            ContentView()
                .environment(appState)
                .frame(minWidth: 700, minHeight: 500)
        }

        Settings {
            Text("Settings placeholder")
                .frame(width: 400, height: 300)
        }
    }

    private var menuBarIcon: String {
        switch appState.status {
        case .idle: "mic.badge.plus"
        case .recording: "record.circle.fill"
        case .transcribing: "waveform"
        }
    }

    private var menuBarColor: Color {
        switch appState.status {
        case .idle: .primary
        case .recording: .red
        case .transcribing: .orange
        }
    }
}
```

- [ ] **Step 6: Build and verify**

```bash
cd Caddie
xcodegen generate
xcodebuild -project Caddie.xcodeproj -scheme Caddie build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Commit**

```bash
git add Caddie/
git commit -m "feat: add menu bar UI with recording indicator and app state wiring"
```

---

## Task 10: Main Window UI — Meeting List + Transcript Viewer + Audio Player

**Files:**
- Modify: `Caddie/Sources/UI/MainWindow/ContentView.swift`
- Create: `Caddie/Sources/UI/MainWindow/MeetingListView.swift`
- Create: `Caddie/Sources/UI/MainWindow/MeetingDetailView.swift`
- Create: `Caddie/Sources/UI/MainWindow/TranscriptView.swift`
- Create: `Caddie/Sources/UI/MainWindow/AudioPlayerView.swift`
- Create: `Caddie/Sources/UI/MainWindow/ExportSheet.swift`
- Create: `Caddie/Sources/UI/Settings/SettingsView.swift`
- Create: `Caddie/Sources/UI/Onboarding/OnboardingView.swift`
- Test: `Caddie/Tests/ExportTests.swift`

**Context:** The main window is a two-pane NavigationSplitView: sidebar with search + date-grouped meeting list, detail pane with meeting header, audio player, and scrollable transcript. Export generates TXT/SRT format strings.

- [ ] **Step 1: Write export tests**

Create `Caddie/Tests/ExportTests.swift`:

```swift
import XCTest
@testable import Caddie

final class ExportTests: XCTestCase {
    let testSegments: [TranscriptSegment] = [
        TranscriptSegment(start: 0.0, end: 4.52, text: "Let's start with the Q3 numbers.", speaker: "SPEAKER_00", words: []),
        TranscriptSegment(start: 5.0, end: 9.3, text: "Sure, revenue is up 12%.", speaker: "SPEAKER_01", words: []),
    ]

    func testExportTXT() {
        let txt = ExportFormatter.toTXT(segments: testSegments)
        XCTAssertTrue(txt.contains("[SPEAKER_00]"))
        XCTAssertTrue(txt.contains("Let's start with the Q3 numbers."))
        XCTAssertTrue(txt.contains("[SPEAKER_01]"))
    }

    func testExportSRT() {
        let srt = ExportFormatter.toSRT(segments: testSegments)
        XCTAssertTrue(srt.contains("1\n"))
        XCTAssertTrue(srt.contains("00:00:00,000 --> 00:00:04,520"))
        XCTAssertTrue(srt.contains("[SPEAKER_00] Let's start with the Q3 numbers."))
        XCTAssertTrue(srt.contains("2\n"))
    }
}
```

- [ ] **Step 2: Write ExportSheet.swift with ExportFormatter**

Create `Caddie/Sources/UI/MainWindow/ExportSheet.swift`:

```swift
import SwiftUI
import UniformTypeIdentifiers

enum ExportFormatter {
    static func toTXT(segments: [TranscriptSegment]) -> String {
        TranscriptMerger.generateFullText(segments: segments)
    }

    static func toSRT(segments: [TranscriptSegment]) -> String {
        segments.enumerated().map { index, seg in
            let start = Formatters.srtTimestamp(seconds: seg.start)
            let end = Formatters.srtTimestamp(seconds: seg.end)
            let prefix = "[\(seg.speaker)] "
            return "\(index + 1)\n\(start) --> \(end)\n\(prefix)\(seg.text)\n"
        }.joined(separator: "\n")
    }
}

struct ExportSheet: View {
    let meeting: Meeting
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Export Transcript")
                .font(.headline)

            HStack(spacing: 12) {
                Button("Export as TXT") { exportAs(format: .txt) }
                Button("Export as SRT") { exportAs(format: .srt) }
            }

            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(width: 300)
    }

    private func exportAs(format: ExportFormat) {
        guard let transcriptData = meeting.transcript?.data(using: .utf8),
              let transcript = try? JSONDecoder().decode(Transcript.self, from: transcriptData)
        else { return }

        let content: String
        let ext: String
        switch format {
        case .txt:
            content = ExportFormatter.toTXT(segments: transcript.segments)
            ext = "txt"
        case .srt:
            content = ExportFormatter.toSRT(segments: transcript.segments)
            ext = "srt"
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .plainText]
        panel.nameFieldStringValue = "\(meeting.title).\(ext)"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? content.write(to: url, atomically: true, encoding: .utf8)
            }
        }
        dismiss()
    }

    enum ExportFormat { case txt, srt }
}
```

- [ ] **Step 3: Write MeetingListView.swift**

Create `Caddie/Sources/UI/MainWindow/MeetingListView.swift`:

```swift
import SwiftUI

struct MeetingListView: View {
    let meetings: [Meeting]
    @Binding var selectedMeetingId: Int64?
    @Binding var searchText: String

    var body: some View {
        List(selection: $selectedMeetingId) {
            if meetings.isEmpty {
                Text("No meetings yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 40)
            } else {
                ForEach(groupedByDate, id: \.key) { date, items in
                    Section(header: Text(Formatters.dateLabel(from: date)).font(.caption2.bold())) {
                        ForEach(items) { meeting in
                            MeetingRow(meeting: meeting)
                                .tag(meeting.id)
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search meetings...")
        .navigationTitle("Caddie")
    }

    private var groupedByDate: [(key: String, value: [Meeting])] {
        let grouped = Dictionary(grouping: meetings, by: \.date)
        return grouped.sorted { $0.key > $1.key }
    }
}

struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(meeting.title)
                .fontWeight(.medium)
                .lineLimit(1)
            HStack(spacing: 6) {
                StatusDot(status: meeting.status)
                Text(meeting.app)
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.fill.tertiary)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                Text(Formatters.duration(seconds: meeting.durationSeconds))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Formatters.time(from: meeting.startTime))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
```

- [ ] **Step 4: Write MeetingDetailView.swift**

Create `Caddie/Sources/UI/MainWindow/MeetingDetailView.swift`:

```swift
import SwiftUI

struct MeetingDetailView: View {
    let meeting: Meeting
    @State private var showingExport = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 6) {
                Text(meeting.title)
                    .font(.title2.bold())
                HStack(spacing: 16) {
                    Label(meeting.app, systemImage: "app")
                    Label(Formatters.dateLabel(from: meeting.date), systemImage: "calendar")
                    Label("\(Formatters.time(from: meeting.startTime)) – \(Formatters.time(from: meeting.endTime))", systemImage: "clock")
                    Label(Formatters.duration(seconds: meeting.durationSeconds), systemImage: "timer")
                    if let transcript = decodedTranscript {
                        Label("\(transcript.numSpeakers) speakers", systemImage: "person.2")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            // Audio Player
            if let audioFile = meeting.audioFile {
                AudioPlayerView(audioURL: AudioFileManager.alacPath(for: meeting.meetingId))
                Divider()
            }

            // Transcript or status
            if meeting.status == .done, let transcript = decodedTranscript {
                TranscriptView(segments: transcript.segments)
            } else if meeting.status == .transcribing {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Transcription in progress...")
                        .foregroundStyle(.orange)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if meeting.status == .error {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title)
                        .foregroundStyle(.red)
                    Text(meeting.error ?? "Transcription failed")
                        .foregroundStyle(.secondary)
                    Button("Retry Transcription") {
                        // TODO: Retry
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Recording in progress...")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Export") { showingExport = true }
                Button(role: .destructive) {
                    // TODO: Delete meeting
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .sheet(isPresented: $showingExport) {
            ExportSheet(meeting: meeting)
        }
    }

    private var decodedTranscript: Transcript? {
        guard let data = meeting.transcript?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Transcript.self, from: data)
    }
}
```

- [ ] **Step 5: Write TranscriptView.swift**

Create `Caddie/Sources/UI/MainWindow/TranscriptView.swift`:

```swift
import SwiftUI

struct TranscriptView: View {
    let segments: [TranscriptSegment]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    HStack(alignment: .top, spacing: 12) {
                        // Speaker label + timestamp
                        VStack(alignment: .trailing, spacing: 2) {
                            if shouldShowSpeaker(for: segment) {
                                SpeakerBadge(speaker: segment.speaker)
                            }
                            Text(Formatters.timestamp(seconds: segment.start))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 90, alignment: .trailing)

                        // Text
                        Text(segment.text)
                            .font(.body)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(20)
        }
    }

    private func shouldShowSpeaker(for segment: TranscriptSegment) -> Bool {
        guard let index = segments.firstIndex(where: { $0.start == segment.start }) else { return true }
        if index == 0 { return true }
        return segments[index - 1].speaker != segment.speaker
    }
}
```

- [ ] **Step 6: Write AudioPlayerView.swift**

Create `Caddie/Sources/UI/MainWindow/AudioPlayerView.swift`:

```swift
import SwiftUI
import AVFoundation

struct AudioPlayerView: View {
    let audioURL: URL
    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var playbackRate: Float = 1.0
    @State private var timer: Timer?

    private let rates: [Float] = [0.5, 1.0, 1.5, 2.0]

    var body: some View {
        HStack(spacing: 12) {
            // Play/Pause
            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)

            // Time
            Text(Formatters.timestamp(seconds: currentTime))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 50)

            // Scrub bar
            Slider(value: $currentTime, in: 0...max(duration, 1)) { editing in
                if !editing {
                    player?.currentTime = currentTime
                }
            }

            // Duration
            Text(Formatters.timestamp(seconds: duration))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 50)

            // Speed control
            Picker("Speed", selection: $playbackRate) {
                ForEach(rates, id: \.self) { rate in
                    Text("\(rate, specifier: "%.1f")x").tag(rate)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
            .onChange(of: playbackRate) { _, newRate in
                player?.rate = newRate
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .onAppear { loadAudio() }
        .onDisappear { stopPlayback() }
    }

    private func loadAudio() {
        guard FileManager.default.fileExists(atPath: audioURL.path) else { return }
        player = try? AVAudioPlayer(contentsOf: audioURL)
        player?.enableRate = true
        player?.prepareToPlay()
        duration = player?.duration ?? 0
    }

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            timer?.invalidate()
        } else {
            player.rate = playbackRate
            player.play()
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                currentTime = player.currentTime
                if !player.isPlaying { isPlaying = false; timer?.invalidate() }
            }
        }
        isPlaying.toggle()
    }

    private func stopPlayback() {
        player?.stop()
        timer?.invalidate()
    }
}
```

- [ ] **Step 7: Update ContentView.swift**

Replace `Caddie/Sources/UI/MainWindow/ContentView.swift`:

```swift
import SwiftUI
import GRDB

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedMeetingId: Int64?
    @State private var searchText = ""
    @State private var meetings: [Meeting] = []

    var body: some View {
        NavigationSplitView {
            MeetingListView(
                meetings: meetings,
                selectedMeetingId: $selectedMeetingId,
                searchText: $searchText
            )
        } detail: {
            if let id = selectedMeetingId, let meeting = meetings.first(where: { $0.id == id }) {
                MeetingDetailView(meeting: meeting)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "mic.badge.plus")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                    Text("Select a meeting to view its transcript")
                        .foregroundStyle(.secondary)
                    Text("Meetings appear here automatically when detected")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(minWidth: 700, minHeight: 500)
    }
}
```

- [ ] **Step 8: Write SettingsView.swift**

Create `Caddie/Sources/UI/Settings/SettingsView.swift`:

```swift
import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @State private var autoLaunch = false
    @State private var gracePeriod: Double = 15

    var body: some View {
        TabView {
            Form {
                Section("General") {
                    Toggle("Launch at login", isOn: $autoLaunch)
                        .onChange(of: autoLaunch) { _, enabled in
                            if enabled {
                                try? SMAppService.mainApp.register()
                            } else {
                                try? SMAppService.mainApp.unregister()
                            }
                        }
                }

                Section("Detection") {
                    HStack {
                        Text("Grace period")
                        Slider(value: $gracePeriod, in: 5...30, step: 5)
                        Text("\(Int(gracePeriod))s")
                            .monospacedDigit()
                    }
                }

                Section("Storage") {
                    let used = AudioFileManager.totalStorageUsed()
                    Text("Audio storage: \(ByteCountFormatter.string(fromByteCount: used, countStyle: .file))")
                }
            }
            .tabItem { Label("General", systemImage: "gear") }
            .padding(20)
        }
        .frame(width: 400, height: 300)
    }
}
```

- [ ] **Step 9: Write OnboardingView.swift (placeholder)**

Create `Caddie/Sources/UI/Onboarding/OnboardingView.swift`:

```swift
import SwiftUI

struct OnboardingView: View {
    @Binding var isComplete: Bool

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "mic.badge.plus")
                .font(.system(size: 64))
                .foregroundStyle(.accent)

            Text("Welcome to Caddie")
                .font(.title.bold())

            Text("Caddie automatically detects and records your meetings, then transcribes them with speaker identification — all on-device.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)

            VStack(alignment: .leading, spacing: 12) {
                PermissionRow(name: "Microphone", description: "To capture your voice", status: Permissions.microphone)
                PermissionRow(name: "Screen Recording", description: "To capture meeting audio", status: Permissions.screenRecording)
                PermissionRow(name: "Accessibility", description: "To detect meeting windows", status: Permissions.accessibility)
            }
            .padding()
            .background(.fill.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Button("Get Started") {
                Permissions.requestAccessibility()
                Task {
                    _ = await Permissions.requestMicrophone()
                }
                isComplete = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(40)
        .frame(width: 500, height: 500)
    }
}

struct PermissionRow: View {
    let name: String
    let description: String
    let status: PermissionStatus

    var body: some View {
        HStack {
            Image(systemName: status == .granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(status == .granted ? .green : .secondary)
            VStack(alignment: .leading) {
                Text(name).fontWeight(.medium)
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
```

- [ ] **Step 10: Run export tests + build**

```bash
cd Caddie
xcodegen generate
xcodebuild test -project Caddie.xcodeproj -scheme CaddieTests -destination 'platform=macOS' 2>&1 | grep -E '(Test Case|PASS|FAIL)'
xcodebuild -project Caddie.xcodeproj -scheme Caddie build 2>&1 | tail -5
```

Expected: All tests pass, build succeeds.

- [ ] **Step 11: Commit**

```bash
git add Caddie/
git commit -m "feat: add full window UI — meeting list, transcript viewer, audio player, export, settings, onboarding"
```

---

## Task 11: Lifecycle Wiring + Database Integration

**Files:**
- Modify: `Caddie/Sources/App/AppState.swift`
- Modify: `Caddie/Sources/App/CaddieApp.swift`
- Modify: `Caddie/Sources/Transcription/TranscriptionPipeline.swift`
- Modify: `Caddie/Sources/UI/MainWindow/ContentView.swift`

**Context:** This task connects the three independent systems — detection, recording, and transcription — into a working lifecycle. It also wires the TranscriptionPipeline to write results back to the database, and connects the UI to live database observations via GRDB's `ValueObservation`.

- [ ] **Step 1: Update AppState to own the lifecycle**

Update `Caddie/Sources/App/AppState.swift` to add lifecycle methods:

```swift
import SwiftUI
import Observation
import GRDB
import os

enum AppStatus: String {
    case idle, recording, transcribing
}

@Observable
final class AppState {
    private let logger = Logger(subsystem: "com.caddie.app", category: "AppState")

    var status: AppStatus = .idle
    var currentMeetingTitle: String?
    var recordingStartTime: Date?
    var transcriptionProgress: Double = 0
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    private(set) var database: AppDatabase?
    private let detector = MeetingDetector()
    private let recorder = AudioRecorder()
    private let pipeline = TranscriptionPipeline()
    private var currentMeetingId: String?

    var recordingDuration: TimeInterval {
        guard let start = recordingStartTime else { return 0 }
        return Date().timeIntervalSince(start)
    }

    func initialize() throws {
        database = try AppDatabase()
        try AudioFileManager.ensureDirectoryExists()

        // Wire detection → recording
        detector.onMeetingStarted = { [weak self] meeting in
            self?.startRecording(meeting: meeting)
        }
        detector.onMeetingEnded = { [weak self] in
            self?.stopRecording()
        }

        detector.start()
        logger.info("App initialized and detection started")
    }

    func shutdown() {
        detector.stop()
        if status == .recording {
            stopRecording()
        }
    }

    private func startRecording(meeting: DetectedMeeting) {
        let meetingId = UUID().uuidString.prefix(12).lowercased()
        currentMeetingId = String(meetingId)
        currentMeetingTitle = meeting.title
        recordingStartTime = Date()
        status = .recording

        // Create DB record
        if let db = database {
            var record = Meeting(
                meetingId: String(meetingId),
                title: meeting.title,
                app: meeting.app,
                date: DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none),
                startTime: ISO8601DateFormatter().string(from: Date()),
                endTime: "",
                durationSeconds: 0,
                status: .recording
            )
            record.audioFile = "\(meetingId).m4a"
            try? db.dbPool.write { db in try record.insert(db) }
        }

        let wavPath = AudioFileManager.wavPath(for: String(meetingId))
        try? recorder.start(outputPath: wavPath, processID: meeting.processId)
        logger.info("Recording started: \(meeting.title)")
    }

    private func stopRecording() {
        recorder.stop()
        let endTime = Date()

        guard let meetingId = currentMeetingId else { return }

        // Update DB record with end time and duration
        if let db = database {
            let duration = Int(endTime.timeIntervalSince(recordingStartTime ?? endTime))
            try? db.dbPool.write { dbConn in
                try dbConn.execute(
                    sql: "UPDATE meetings SET end_time = ?, duration_seconds = ?, status = 'transcribing' WHERE meeting_id = ?",
                    arguments: [ISO8601DateFormatter().string(from: endTime), duration, meetingId]
                )
            }
        }

        status = .transcribing
        logger.info("Recording stopped, queuing transcription for \(meetingId)")

        // Enqueue transcription
        Task {
            await pipeline.enqueue(meetingId: meetingId, database: database)
        }

        recordingStartTime = nil
        currentMeetingId = nil
    }
}
```

- [ ] **Step 2: Update TranscriptionPipeline to write to DB**

Update the `processNext()` method in `Caddie/Sources/Transcription/TranscriptionPipeline.swift` to accept a database reference and write results:

```swift
actor TranscriptionPipeline {
    private let logger = Logger(subsystem: "com.caddie.app", category: "TranscriptionPipeline")
    private let asr = ASREngine()
    private let diarizer = DiarizationEngine()
    private var queue: [(meetingId: String, database: AppDatabase?)] = []
    private var isProcessing = false

    func enqueue(meetingId: String, database: AppDatabase?) {
        queue.append((meetingId, database))
        logger.info("Transcription queued: \(meetingId)")
        Task { await processNext() }
    }

    private func processNext() async {
        guard !isProcessing, let job = queue.first else { return }
        isProcessing = true
        queue.removeFirst()

        let meetingId = job.meetingId
        let db = job.database
        let wavURL = AudioFileManager.wavPath(for: meetingId)
        let alacURL = AudioFileManager.alacPath(for: meetingId)
        let startTime = Date()

        do {
            // Update status
            try db?.dbPool.write { dbConn in
                try dbConn.execute(sql: "UPDATE meetings SET status = 'transcribing' WHERE meeting_id = ?", arguments: [meetingId])
            }

            let (asrSegments, language, duration) = try await asr.transcribe(audioURL: wavURL)
            let speakerSegments = try await diarizer.diarize(audioURL: wavURL)
            let merged = TranscriptMerger.merge(asr: asrSegments, speakers: speakerSegments)
            let fullText = TranscriptMerger.generateFullText(segments: merged)

            let transcript = Transcript(
                language: language, duration: duration,
                numSegments: merged.count,
                numSpeakers: Set(merged.map(\.speaker)).count,
                processingTimeSeconds: Date().timeIntervalSince(startTime),
                fullText: fullText, segments: merged
            )

            try AudioFileManager.compressToALAC(wavURL: wavURL, outputURL: alacURL)
            try? FileManager.default.removeItem(at: wavURL)

            // Save transcript to DB
            let transcriptJSON = String(data: try JSONEncoder().encode(transcript), encoding: .utf8) ?? ""
            try db?.dbPool.write { dbConn in
                try dbConn.execute(
                    sql: "UPDATE meetings SET transcript = ?, status = 'done' WHERE meeting_id = ?",
                    arguments: [transcriptJSON, meetingId]
                )
            }
            logger.info("Transcription complete: \(meetingId)")

        } catch {
            logger.error("Transcription failed for \(meetingId): \(error)")
            try? db?.dbPool.write { dbConn in
                try dbConn.execute(
                    sql: "UPDATE meetings SET status = 'error', error = ? WHERE meeting_id = ?",
                    arguments: [error.localizedDescription, meetingId]
                )
            }
        }

        isProcessing = false
        await processNext()
    }
}
```

- [ ] **Step 3: Update ContentView to observe database**

Update `Caddie/Sources/UI/MainWindow/ContentView.swift` to use GRDB `ValueObservation`:

```swift
import SwiftUI
import GRDB

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedMeetingId: Int64?
    @State private var searchText = ""
    @State private var meetings: [Meeting] = []
    @State private var observationTask: AnyDatabaseCancellable?

    var body: some View {
        NavigationSplitView {
            MeetingListView(
                meetings: meetings,
                selectedMeetingId: $selectedMeetingId,
                searchText: $searchText
            )
        } detail: {
            if let id = selectedMeetingId, let meeting = meetings.first(where: { $0.id == id }) {
                MeetingDetailView(meeting: meeting)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "mic.badge.plus")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                    Text("Select a meeting to view its transcript")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .onAppear { startObserving() }
        .onDisappear { observationTask?.cancel() }
        .onChange(of: searchText) { _, query in startObserving(search: query) }
    }

    private func startObserving(search: String = "") {
        guard let db = appState.database?.dbPool else { return }
        observationTask?.cancel()

        let observation = ValueObservation.tracking { db -> [Meeting] in
            if search.isEmpty {
                return try Meeting.order(Column("created_at").desc).fetchAll(db)
            } else {
                return try Meeting
                    .filter(sql: "id IN (SELECT rowid FROM meetings_fts WHERE meetings_fts MATCH ?)", arguments: [search])
                    .order(Column("created_at").desc)
                    .fetchAll(db)
            }
        }

        observationTask = observation.start(in: db, onError: { _ in }) { newMeetings in
            meetings = newMeetings
        }
    }
}
```

- [ ] **Step 4: Update CaddieApp.swift to initialize**

Update `Caddie/Sources/App/CaddieApp.swift`:

```swift
import SwiftUI

@main
struct CaddieApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
        } label: {
            Image(systemName: menuBarIcon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(menuBarColor)
        }

        WindowGroup {
            ContentView()
                .environment(appState)
                .frame(minWidth: 700, minHeight: 500)
                .task {
                    do {
                        try appState.initialize()
                    } catch {
                        print("Failed to initialize: \(error)")
                    }
                }
        }

        Settings {
            SettingsView()
        }
    }

    private var menuBarIcon: String {
        switch appState.status {
        case .idle: "mic.badge.plus"
        case .recording: "record.circle.fill"
        case .transcribing: "waveform"
        }
    }

    private var menuBarColor: Color {
        switch appState.status {
        case .idle: .primary
        case .recording: .red
        case .transcribing: .orange
        }
    }
}
```

- [ ] **Step 5: Build and verify**

```bash
cd Caddie
xcodegen generate
xcodebuild -project Caddie.xcodeproj -scheme Caddie build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add Caddie/
git commit -m "feat: wire detection → recording → transcription lifecycle with DB integration"
```

---

## Summary

| Task | What It Builds | Key Files | Testable? |
|------|---------------|-----------|-----------|
| 1 | Xcode project + app shell | CaddieApp, AppState, project.yml | Build check |
| 2 | Storage layer | Meeting, Database, Migrations, AudioFileManager, Formatters | Unit tests |
| 3 | Meeting patterns | MeetingPatterns | Unit tests |
| 4 | Detection signals | 4 monitors (AudioProcess, MicState, WindowTitle, Calendar) | Build check |
| 5 | Meeting detector | MeetingDetector + DecisionEngine | Unit tests |
| 6 | Audio capture | SystemAudioCapture, MicrophoneCapture, AudioRecorder | Build check + manual |
| 7 | Transcription | ASREngine, DiarizationEngine, TranscriptMerger, Pipeline | Unit tests (merger) |
| 8 | Model + utilities | ModelManager, Logger, Permissions | Build check |
| 9 | Menu bar UI | MenuBarView, RecordingIndicator, StatusDot, SpeakerBadge | Build check |
| 10 | Main window UI | MeetingList, MeetingDetail, Transcript, AudioPlayer, Export, Settings | Unit tests (export) |
| 11 | Lifecycle wiring + DB | AppState lifecycle, pipeline DB writes, UI database observation | Build check |

**After all 11 tasks:** The app compiles and has a fully wired lifecycle: detection triggers recording, recording end triggers transcription, transcription writes to SQLite, UI reactively updates via GRDB observation. The main TODO remaining is:
1. Integrate FluidAudio SDK (replace placeholder API calls in ASREngine + DiarizationEngine with actual FluidAudio Parakeet + pyannote calls) — this requires the FluidAudio CocoaPod/SPM package and its documentation
2. App icon and assets
3. Code signing + notarization for distribution
