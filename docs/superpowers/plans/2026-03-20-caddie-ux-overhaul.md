# Caddie UX Overhaul Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transform Caddie from a compiling prototype into a production-quality macOS menu bar app with polished UI, native menu behavior, dynamic dock icon, and professional visual design.

**Architecture:** All changes are UI/UX only — the existing backend (detection, recording, transcription, storage) is untouched. We modify 16 existing files and create 1 new file. Each task targets a self-contained layer: project config → app lifecycle → shared components → menu bar → main window views → onboarding → settings.

**Tech Stack:** Swift/SwiftUI, macOS 14.2+, GRDB, NSMenu via MenuBarExtra, NSWindow notifications, SMAppService

**Spec:** `docs/superpowers/specs/2026-03-20-caddie-ux-overhaul-design.md`

---

## File Map

Every file that will be created or modified, and what changes:

```
Sources/
├── App/
│   ├── CaddieApp.swift          # MenuBarExtra(.menu), Window(id:), AppDelegate with dynamic dock
│   └── AppState.swift           # Non-throwing init, isInitialized, initError, retryTranscription()
├── UI/
│   ├── MenuBar/
│   │   └── MenuBarView.swift    # Native NSMenu: status, recent meetings, stop confirm, open window
│   ├── MainWindow/
│   │   ├── ContentView.swift    # Onboarding gate, init task, sidebar width, error state
│   │   ├── MeetingListView.swift # Polished rows, sections, empty state, search
│   │   ├── MeetingDetailView.swift # Stats dashboard, metadata chips, delete/retry wired
│   │   ├── TranscriptView.swift # Speaker grouping, dividers, readable layout
│   │   ├── AudioPlayerView.swift # Card container, refined controls, speed picker
│   │   └── ExportSheet.swift    # Centered layout, full-width buttons
│   ├── Onboarding/
│   │   └── OnboardingView.swift # Permission blocking wizard, polished design
│   ├── Settings/
│   │   └── SettingsView.swift   # 4 sections: general, permissions, storage, about
│   └── Shared/
│       ├── SpeakerBadge.swift   # Capsule badge, curated palette, stable hash
│       └── StatusDot.swift      # 8pt, pulsing animation for recording
├── Resources/
│   └── Assets.xcassets/
│       └── Contents.json        # NEW: root asset catalog manifest
└── project.yml                  # Fix xcassets inclusion
```

---

## Task 1: Project Config + Asset Catalog Fix

**Files:**
- Modify: `project.yml`
- Create: `Resources/Assets.xcassets/Contents.json`

**Context:** The asset catalog is empty and not compiled into the build. xcodegen needs the xcassets listed as a source (not a folder resource) for actool to compile it. The root `Contents.json` is required for a valid xcassets bundle.

- [ ] **Step 1: Fix project.yml to compile asset catalog**

Replace the `sources` and `resources` section in the Caddie target:

```yaml
    sources:
      - Sources
      - path: Resources/Assets.xcassets
    resources:
      - path: Resources
        excludes:
          - "Assets.xcassets"
```

This tells xcodegen to treat `Assets.xcassets` as a compiled source (triggers actool) while still including other Resources (Info.plist, entitlements) as resources.

- [ ] **Step 2: Create Assets.xcassets/Contents.json**

```json
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

- [ ] **Step 3: Add .superpowers/ to .gitignore**

Append `.superpowers/` and `*.dmg` to `.gitignore` if not already present.

- [ ] **Step 4: Regenerate Xcode project and verify build**

```bash
xcodegen generate
xcodebuild -project Caddie.xcodeproj -scheme Caddie -configuration Debug build 2>&1 | grep -E "CompileAsset|actool|error:|BUILD"
```

Expected: `BUILD SUCCEEDED` with actool/CompileAssetCatalog lines visible.

- [ ] **Step 5: Run tests**

```bash
xcodebuild -project Caddie.xcodeproj -scheme CaddieTests -configuration Debug test 2>&1 | grep "Executed.*tests"
```

Expected: `Executed 38 tests, with 0 failures`

- [ ] **Step 6: Commit**

```bash
git add project.yml Resources/Assets.xcassets/Contents.json .gitignore
git commit -m "fix: asset catalog compilation and project config"
```

---

## Task 2: AppState — Non-throwing Init, retryTranscription, stopRecording Visibility

**Files:**
- Modify: `Sources/App/AppState.swift`

**Context:** `initialize()` currently throws, which makes callers awkward. We make it non-throwing with internal error capture. We also add `retryTranscription()` for the error retry flow, and ensure `stopRecording()` is public.

- [ ] **Step 1: Read current AppState.swift**

Read the file to understand current structure.

- [ ] **Step 2: Modify initialize() to be non-throwing**

Change `func initialize() throws` to `func initialize()`. Wrap the body in do/catch. Add two new properties before the `// MARK: - Lifecycle` section:

```swift
private(set) var isInitialized = false
var initError: String?
```

New `initialize()`:

```swift
func initialize() {
    guard !isInitialized else { return }

    do {
        database = try AppDatabase()
        try AudioFileManager.ensureDirectoryExists()

        detector.onMeetingStarted = { [weak self] meeting in
            self?.startRecording(meeting: meeting)
        }
        detector.onMeetingEnded = { [weak self] in
            self?.stopRecording()
        }
        detector.start()
        isInitialized = true
        logger.info("AppState initialized")
    } catch {
        initError = error.localizedDescription
        logger.error("Failed to initialize: \(error.localizedDescription)")
    }
}
```

- [ ] **Step 3: Add retryTranscription()**

Add before `stopRecording()`:

```swift
func retryTranscription(meetingId: String) async {
    let wavURL = AudioFileManager.wavPath(for: meetingId)

    guard FileManager.default.fileExists(atPath: wavURL.path) else {
        if let db = database {
            try? db.dbWriter.write { dbConn in
                try dbConn.execute(
                    sql: "UPDATE meetings SET status = ?, error = ? WHERE meeting_id = ?",
                    arguments: [MeetingStatus.error.rawValue, "Audio file not found", meetingId]
                )
            }
        }
        return
    }

    if let db = database {
        try? db.dbWriter.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE meetings SET status = ?, error = NULL WHERE meeting_id = ?",
                arguments: [MeetingStatus.transcribing.rawValue, meetingId]
            )
        }
    }

    await pipeline.enqueue(meetingId: meetingId, database: database)
}
```

- [ ] **Step 4: Build and run tests**

```bash
xcodebuild -project Caddie.xcodeproj -scheme CaddieTests -configuration Debug test 2>&1 | grep "Executed.*tests"
```

Expected: all tests pass (the existing `testAppStateInitialStatus` test checks default `.idle` which is unchanged).

- [ ] **Step 5: Commit**

```bash
git add Sources/App/AppState.swift
git commit -m "refactor: non-throwing AppState.initialize(), add retryTranscription()"
```

---

## Task 3: Shared Components — SpeakerBadge + StatusDot

**Files:**
- Modify: `Sources/UI/Shared/SpeakerBadge.swift`
- Modify: `Sources/UI/Shared/StatusDot.swift`

**Context:** SpeakerBadge needs a proper capsule design with stable hashing. StatusDot needs to be larger with a pulse animation for recording.

- [ ] **Step 1: Rewrite SpeakerBadge.swift**

```swift
import SwiftUI

struct SpeakerBadge: View {
    let speaker: String

    private static let palette: [(Color, Color)] = [
        (Color(red: 0.27, green: 0.46, blue: 0.90), Color(red: 0.22, green: 0.38, blue: 0.78)),
        (Color(red: 0.17, green: 0.60, blue: 0.55), Color(red: 0.13, green: 0.50, blue: 0.46)),
        (Color(red: 0.80, green: 0.30, blue: 0.55), Color(red: 0.68, green: 0.24, blue: 0.46)),
        (Color(red: 0.30, green: 0.55, blue: 0.35), Color(red: 0.24, green: 0.46, blue: 0.28)),
        (Color(red: 0.75, green: 0.52, blue: 0.20), Color(red: 0.64, green: 0.44, blue: 0.16)),
        (Color(red: 0.85, green: 0.42, blue: 0.28), Color(red: 0.74, green: 0.35, blue: 0.22)),
        (Color(red: 0.50, green: 0.40, blue: 0.75), Color(red: 0.42, green: 0.33, blue: 0.65)),
        (Color(red: 0.45, green: 0.50, blue: 0.55), Color(red: 0.38, green: 0.42, blue: 0.48)),
    ]

    var body: some View {
        Text(speaker)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [colors.0, colors.1],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .fixedSize()
    }

    private var colors: (Color, Color) {
        let hash = speaker.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        let index = abs(hash) % Self.palette.count
        return Self.palette[index]
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 6) {
        SpeakerBadge(speaker: "Speaker 1")
        SpeakerBadge(speaker: "Speaker 2")
        SpeakerBadge(speaker: "Speaker 3")
    }
    .padding()
}
```

- [ ] **Step 2: Rewrite StatusDot.swift**

```swift
import SwiftUI

struct StatusDot: View {
    let status: MeetingStatus
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: status == .recording ? color.opacity(0.5) : .clear, radius: isPulsing ? 4 : 0)
            .scaleEffect(status == .recording && isPulsing ? 1.3 : 1.0)
            .opacity(status == .recording && isPulsing ? 0.7 : 1.0)
            .animation(
                status == .recording
                    ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                    : .default,
                value: isPulsing
            )
            .onAppear {
                if status == .recording { isPulsing = true }
            }
            .onChange(of: status) { _, newValue in
                isPulsing = newValue == .recording
            }
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

#Preview {
    HStack(spacing: 16) {
        StatusDot(status: .recording)
        StatusDot(status: .transcribing)
        StatusDot(status: .done)
        StatusDot(status: .error)
    }
    .padding()
}
```

- [ ] **Step 3: Build and run tests**

```bash
xcodebuild -project Caddie.xcodeproj -scheme CaddieTests -configuration Debug test 2>&1 | grep "Executed.*tests"
```

Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/UI/Shared/SpeakerBadge.swift Sources/UI/Shared/StatusDot.swift
git commit -m "feat: polished SpeakerBadge capsules and StatusDot pulse animation"
```

---

## Task 4: CaddieApp — Menu Style, Window Scene, AppDelegate with Dynamic Dock

**Files:**
- Modify: `Sources/App/CaddieApp.swift`

**Context:** The entry point needs three changes: native menu style, `Window(id:)` instead of `WindowGroup`, and an `AppDelegate` that dynamically shows/hides the dock icon based on window state.

- [ ] **Step 1: Rewrite CaddieApp.swift**

```swift
import SwiftUI

@main
struct CaddieApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
        } label: {
            switch appState.status {
            case .idle:
                Image(systemName: "mic.badge.plus")
                    .symbolRenderingMode(.monochrome)
            case .recording:
                Image(systemName: "record.circle.fill")
                    .symbolRenderingMode(.monochrome)
            case .transcribing:
                Image(systemName: "waveform")
                    .symbolRenderingMode(.monochrome)
            }
        }
        .menuBarExtraStyle(.menu)

        Window("Caddie", id: "main") {
            ContentView()
                .environment(appState)
        }
        .defaultSize(width: 800, height: 600)

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        CaddieLogger.app.info("Caddie launched")

        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        CaddieLogger.app.info("Caddie terminating")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Dynamic Activation Policy

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              isMainAppWindow(window) else { return }
        NSApp.setActivationPolicy(.regular)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async {
            let hasVisibleMainWindow = NSApp.windows.contains {
                $0.isVisible && self.isMainAppWindow($0)
            }
            if !hasVisibleMainWindow {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    private func isMainAppWindow(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled)
            && !window.className.contains("Settings")
            && !window.className.contains("MenuBar")
            && window.title.contains("Caddie")
    }
}
```

- [ ] **Step 2: Build and run tests**

```bash
xcodebuild -project Caddie.xcodeproj -scheme CaddieTests -configuration Debug test 2>&1 | grep "Executed.*tests"
```

- [ ] **Step 3: Commit**

```bash
git add Sources/App/CaddieApp.swift
git commit -m "feat: native menu bar, Window scene, dynamic dock icon"
```

---

## Task 5: MenuBarView — Native NSMenu Content

**Files:**
- Modify: `Sources/UI/MenuBar/MenuBarView.swift`

**Context:** Rewrite the menu bar dropdown as native NSMenu items: status text, recent meetings section, stop recording with confirmation, open window, settings, quit.

- [ ] **Step 1: Rewrite MenuBarView.swift**

```swift
import SwiftUI
import GRDB

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        statusSection
        Divider()
        recentMeetingsSection
        Divider()
        actionsSection
        Divider()
        Button {
            NSApp.terminate(nil)
        } label: {
            Label("Quit Caddie", systemImage: "power")
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusSection: some View {
        switch appState.status {
        case .idle:
            Text("No Active Meeting")

        case .recording:
            Text("\u{1F534} \(appState.currentMeetingTitle ?? "Recording...")")
            Text("Recording \u{00B7} \(Formatters.duration(seconds: Int(appState.recordingDuration)))")
            Button {
                confirmStopRecording()
            } label: {
                Label("Stop Recording", systemImage: "stop.circle.fill")
            }

        case .transcribing:
            Text("Transcribing...")
        }
    }

    // MARK: - Recent Meetings

    @ViewBuilder
    private var recentMeetingsSection: some View {
        let meetings = fetchRecentMeetings()
        if !meetings.isEmpty {
            Section("Recent") {
                ForEach(meetings) { meeting in
                    Button {
                        openWindow(id: "main")
                        NSApp.activate(ignoringOtherApps: true)
                    } label: {
                        Text(menuLabel(for: meeting))
                    }
                }
            }
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionsSection: some View {
        Button {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        } label: {
            Label("Open Caddie", systemImage: "macwindow")
        }

        SettingsLink {
            Label("Settings...", systemImage: "gear")
        }
    }

    // MARK: - Helpers

    private func confirmStopRecording() {
        let title = appState.currentMeetingTitle ?? "this meeting"
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Stop Recording?"
            alert.informativeText = "This will stop recording '\(title)'."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Stop")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                appState.stopRecording()
            }
        }
    }

    private func fetchRecentMeetings() -> [Meeting] {
        guard let db = appState.database else { return [] }
        return (try? db.dbWriter.read { dbConn in
            try Meeting
                .order(Column("created_at").desc)
                .limit(3)
                .fetchAll(dbConn)
        }) ?? []
    }

    private func menuLabel(for meeting: Meeting) -> String {
        if let duration = meeting.durationSeconds {
            return "\(meeting.title)  \(Formatters.duration(seconds: duration))"
        } else {
            return "\(meeting.title)  \(meeting.status.rawValue.capitalized)"
        }
    }
}
```

- [ ] **Step 2: Build and run tests**

```bash
xcodebuild -project Caddie.xcodeproj -scheme CaddieTests -configuration Debug test 2>&1 | grep "Executed.*tests"
```

- [ ] **Step 3: Commit**

```bash
git add Sources/UI/MenuBar/MenuBarView.swift
git commit -m "feat: native NSMenu dropdown with recent meetings and stop confirmation"
```

---

## Task 6: ContentView — Onboarding Gate, Init Task, Error State

**Files:**
- Modify: `Sources/UI/MainWindow/ContentView.swift`

**Context:** ContentView needs to: show onboarding for first-time users, call `initialize()` on appear, show error state if init fails, and configure sidebar width.

- [ ] **Step 1: Rewrite ContentView.swift**

```swift
import SwiftUI
import GRDB

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedMeetingId: Int64?
    @State private var searchText = ""
    @State private var meetings: [Meeting] = []
    @State private var observationCancellable: AnyDatabaseCancellable?

    var body: some View {
        Group {
            if !appState.hasCompletedOnboarding {
                OnboardingView(isComplete: Binding(
                    get: { appState.hasCompletedOnboarding },
                    set: { appState.hasCompletedOnboarding = $0 }
                ))
            } else if let error = appState.initError {
                initErrorView(error)
            } else {
                mainContent
            }
        }
        .task {
            appState.initialize()
        }
    }

    // MARK: - Error State

    private func initErrorView(_ error: String) -> some View {
        ContentUnavailableView {
            Label("Failed to Start", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error)
        } actions: {
            Button("Retry") {
                appState.initError = nil
                appState.initialize()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(minWidth: 700, minHeight: 500)
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContent: some View {
        NavigationSplitView {
            MeetingListView(
                meetings: meetings,
                selectedMeetingId: $selectedMeetingId,
                searchText: $searchText
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 350)
        } detail: {
            if let id = selectedMeetingId,
               let meeting = meetings.first(where: { $0.id == id }) {
                MeetingDetailView(meeting: meeting)
            } else {
                ContentUnavailableView(
                    "No Meeting Selected",
                    systemImage: "waveform",
                    description: Text("Select a meeting from the sidebar to view its transcript.")
                )
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .onAppear { startObserving() }
        .onDisappear { observationCancellable?.cancel() }
        .onChange(of: searchText) { _, _ in startObserving() }
    }

    // MARK: - Database Observation

    private func startObserving() {
        guard let dbWriter = appState.database?.dbWriter else { return }
        observationCancellable?.cancel()

        let currentSearch = searchText
        let observation = ValueObservation.tracking { db -> [Meeting] in
            if currentSearch.isEmpty {
                return try Meeting
                    .order(Column("created_at").desc)
                    .fetchAll(db)
            } else {
                let escaped = currentSearch.replacingOccurrences(of: "\"", with: "\"\"")
                let ftsQuery = "\"\(escaped)\"*"
                return try Meeting
                    .filter(
                        sql: "id IN (SELECT rowid FROM meetings_fts WHERE meetings_fts MATCH ?)",
                        arguments: [ftsQuery]
                    )
                    .order(Column("created_at").desc)
                    .fetchAll(db)
            }
        }

        observationCancellable = observation.start(
            in: dbWriter,
            onError: { error in
                CaddieLogger.app.error("Database observation error: \(error.localizedDescription)")
            },
            onChange: { newMeetings in
                meetings = newMeetings
            }
        )
    }
}
```

- [ ] **Step 2: Build and run tests**

```bash
xcodebuild -project Caddie.xcodeproj -scheme CaddieTests -configuration Debug test 2>&1 | grep "Executed.*tests"
```

- [ ] **Step 3: Commit**

```bash
git add Sources/UI/MainWindow/ContentView.swift
git commit -m "feat: onboarding gate, init error handling, sidebar width"
```

---

## Task 7: MeetingListView — Polished Sidebar

**Files:**
- Modify: `Sources/UI/MainWindow/MeetingListView.swift`

**Context:** The sidebar needs polished rows with proper typography, hidden separators, date sections, and a professional empty state.

- [ ] **Step 1: Rewrite MeetingListView.swift**

```swift
import SwiftUI

struct MeetingListView: View {
    let meetings: [Meeting]
    @Binding var selectedMeetingId: Int64?
    @Binding var searchText: String

    var body: some View {
        List(selection: $selectedMeetingId) {
            if groupedMeetings.isEmpty {
                emptyState
            } else {
                ForEach(groupedMeetings, id: \.date) { group in
                    Section {
                        ForEach(group.meetings) { meeting in
                            MeetingRow(meeting: meeting)
                                .tag(meeting.id)
                                .listRowSeparator(.hidden)
                        }
                    } header: {
                        Text(Formatters.dateLabel(from: group.date))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText, prompt: "Search meetings")
        .navigationTitle("Caddie")
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No meetings yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Meetings will appear here once Caddie detects and records them.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    // MARK: - Grouping

    private struct DateGroup {
        let date: String
        let meetings: [Meeting]
    }

    private var filteredMeetings: [Meeting] {
        if searchText.isEmpty { return meetings }
        let query = searchText.lowercased()
        return meetings.filter {
            $0.title.lowercased().contains(query) ||
            ($0.app?.lowercased().contains(query) ?? false)
        }
    }

    private var groupedMeetings: [DateGroup] {
        let grouped = Dictionary(grouping: filteredMeetings) { $0.date }
        return grouped.keys.sorted(by: >).map { date in
            DateGroup(date: date, meetings: grouped[date]!.sorted { $0.startTime > $1.startTime })
        }
    }
}

// MARK: - MeetingRow

private struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(meeting.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if let time = Formatters.time(from: meeting.startTime) {
                    Text(time)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: 6) {
                StatusDot(status: meeting.status)

                if let app = meeting.app {
                    Text(app)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let duration = meeting.durationSeconds {
                    Text("\u{00B7} \(Formatters.duration(seconds: duration))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
```

- [ ] **Step 2: Build and run tests**

```bash
xcodebuild -project Caddie.xcodeproj -scheme CaddieTests -configuration Debug test 2>&1 | grep "Executed.*tests"
```

- [ ] **Step 3: Commit**

```bash
git add Sources/UI/MainWindow/MeetingListView.swift
git commit -m "feat: polished meeting list sidebar with sections and empty state"
```

---

## Task 8: MeetingDetailView — Stats Dashboard + Wired Actions

**Files:**
- Modify: `Sources/UI/MainWindow/MeetingDetailView.swift`

**Context:** The detail pane needs: header with metadata chips, stats cards row, audio player, transcript section, status states, and wired delete/retry actions.

- [ ] **Step 1: Rewrite MeetingDetailView.swift**

```swift
import SwiftUI

struct MeetingDetailView: View {
    @Environment(AppState.self) private var appState
    let meeting: Meeting
    @State private var showingExportSheet = false
    @State private var showingDeleteConfirm = false

    private let accentColor = Color(red: 0.976, green: 0.451, blue: 0.086) // #F97316

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerSection
                if meeting.status == .done, let transcript = decodedTranscript {
                    statsSection(transcript: transcript)
                }
                audioSection
                transcriptSection
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingExportSheet = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(meeting.status != .done)
            }
            ToolbarItem(placement: .destructiveAction) {
                Button(role: .destructive) {
                    showingDeleteConfirm = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .confirmationDialog("Delete Meeting?", isPresented: $showingDeleteConfirm) {
                    Button("Delete", role: .destructive) { deleteMeeting() }
                } message: {
                    Text("This will permanently delete the recording and transcript for '\(meeting.title)'.")
                }
            }
        }
        .sheet(isPresented: $showingExportSheet) {
            ExportSheet(meeting: meeting)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(meeting.title)
                .font(.title.bold())
                .textSelection(.enabled)

            HStack(spacing: 0) {
                if let app = meeting.app {
                    metadataChip(text: app, icon: "app.fill")
                }
                if let time = Formatters.time(from: meeting.startTime) {
                    if meeting.app != nil { metadataDivider }
                    if let endTime = meeting.endTime, let end = Formatters.time(from: endTime) {
                        metadataChip(text: "\(time) \u{2013} \(end)", icon: "clock")
                    } else {
                        metadataChip(text: time, icon: "clock")
                    }
                }
                if let duration = meeting.durationSeconds {
                    metadataDivider
                    metadataChip(text: Formatters.duration(seconds: duration), icon: "timer")
                }
                if let transcript = decodedTranscript {
                    metadataDivider
                    metadataChip(text: "\(transcript.numSpeakers) speaker\(transcript.numSpeakers == 1 ? "" : "s")", icon: "person.2")
                }
            }
        }
    }

    private func metadataChip(text: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2)
            Text(text)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private var metadataDivider: some View {
        Text("\u{00B7}")
            .font(.subheadline)
            .foregroundStyle(.quaternary)
            .padding(.horizontal, 8)
    }

    // MARK: - Stats

    private func statsSection(transcript: Transcript) -> some View {
        HStack(spacing: 12) {
            if let duration = meeting.durationSeconds {
                statCard(value: Formatters.duration(seconds: duration), label: "Duration")
            }
            statCard(value: "\(transcript.numSpeakers)", label: "Speakers")
            statCard(value: "\(transcript.fullText.split(separator: " ").count)", label: "Words")
            statCard(value: transcript.language.uppercased(), label: "Language")
        }
    }

    private func statCard(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2.bold())
                .foregroundStyle(accentColor)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Audio

    @ViewBuilder
    private var audioSection: some View {
        if let audioFile = meeting.audioFile {
            AudioPlayerView(audioURL: AudioFileManager.alacPath(for: meeting.meetingId))
        }
    }

    // MARK: - Transcript

    @ViewBuilder
    private var transcriptSection: some View {
        switch meeting.status {
        case .done:
            if let transcript = decodedTranscript {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Transcript")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    TranscriptView(segments: transcript.segments)
                }
            }
        case .recording:
            statusCard(icon: "mic.fill", iconColor: .red, message: "Recording in progress...")
        case .transcribing:
            statusCard(icon: "text.badge.checkmark", iconColor: .orange, message: "Transcribing audio...")
        case .error:
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Transcription Failed").font(.headline)
                        Text(meeting.error ?? "An unknown error occurred.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    Task { await appState.retryTranscription(meetingId: meeting.meetingId) }
                } label: {
                    Label("Retry Transcription", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func statusCard(icon: String, iconColor: Color, message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(iconColor).font(.title3)
            Text(message).foregroundStyle(.secondary)
            Spacer()
            ProgressView().controlSize(.small)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Helpers

    private var decodedTranscript: Transcript? {
        guard let json = meeting.transcript,
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Transcript.self, from: data)
    }

    private func deleteMeeting() {
        guard let db = appState.database else { return }
        do {
            try db.dbWriter.write { dbConn in
                _ = try Meeting.deleteOne(dbConn, id: meeting.id)
            }
            AudioFileManager.deleteAudio(meetingId: meeting.meetingId)
        } catch {
            CaddieLogger.storage.error("Failed to delete meeting: \(error.localizedDescription)")
        }
    }
}
```

- [ ] **Step 2: Build and run tests**

```bash
xcodebuild -project Caddie.xcodeproj -scheme CaddieTests -configuration Debug test 2>&1 | grep "Executed.*tests"
```

- [ ] **Step 3: Commit**

```bash
git add Sources/UI/MainWindow/MeetingDetailView.swift
git commit -m "feat: stats dashboard, metadata chips, wired delete/retry"
```

---

## Task 9: TranscriptView + AudioPlayerView + ExportSheet

**Files:**
- Modify: `Sources/UI/MainWindow/TranscriptView.swift`
- Modify: `Sources/UI/MainWindow/AudioPlayerView.swift`
- Modify: `Sources/UI/MainWindow/ExportSheet.swift`

**Context:** These three views are simpler — polish their layouts to match the design spec.

- [ ] **Step 1: Rewrite TranscriptView.swift**

```swift
import SwiftUI

struct TranscriptView: View {
    let segments: [TranscriptSegment]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                let isNewSpeaker = index == 0 || segments[index - 1].speaker != segment.speaker

                if isNewSpeaker && index > 0 {
                    Divider().padding(.vertical, 10)
                }

                if isNewSpeaker {
                    HStack(spacing: 8) {
                        SpeakerBadge(speaker: segment.speaker)
                        Text(Formatters.timestamp(seconds: segment.start))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.bottom, 4)
                }

                HStack(alignment: .top, spacing: 8) {
                    if !isNewSpeaker {
                        Text(Formatters.timestamp(seconds: segment.start))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.quaternary)
                            .frame(width: 36, alignment: .trailing)
                    }

                    Text(segment.text)
                        .textSelection(.enabled)
                        .lineSpacing(4)
                        .padding(.leading, isNewSpeaker ? 0 : 0)
                }
            }
        }
    }
}
```

- [ ] **Step 2: Rewrite AudioPlayerView.swift**

```swift
import SwiftUI
import AVFoundation

struct AudioPlayerView: View {
    let audioURL: URL

    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var playbackSpeed: Float = 1.0
    @State private var timer: Timer?
    @State private var fileExists = false

    private let speeds: [Float] = [0.5, 1.0, 1.5, 2.0]

    var body: some View {
        if fileExists {
            VStack(spacing: 12) {
                Slider(value: $currentTime, in: 0...max(duration, 1)) { editing in
                    if !editing { player?.currentTime = currentTime }
                }
                .controlSize(.small)

                HStack(spacing: 16) {
                    Button { togglePlayback() } label: {
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 28))
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.plain)

                    Text(Formatters.timestamp(seconds: currentTime))
                        .font(.subheadline.monospacedDigit())
                        .frame(width: 44, alignment: .trailing)

                    Text("/")
                        .font(.subheadline)
                        .foregroundStyle(.quaternary)

                    Text(Formatters.timestamp(seconds: duration))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .leading)

                    Spacer()

                    Picker("Speed", selection: $playbackSpeed) {
                        ForEach(speeds, id: \.self) { speed in
                            Text("\(speed, specifier: "%.1f")x").tag(speed)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                    .onChange(of: playbackSpeed) { _, newValue in
                        player?.rate = newValue
                    }
                }
            }
            .padding(16)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onAppear { loadAudio() }
            .onDisappear { stopTimer(); player?.stop() }
        } else {
            HStack(spacing: 8) {
                Image(systemName: "waveform.slash").foregroundStyle(.tertiary)
                Text("Audio file not found").foregroundStyle(.secondary).font(.subheadline)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onAppear {
                fileExists = FileManager.default.fileExists(atPath: audioURL.path)
            }
        }
    }

    private func loadAudio() {
        fileExists = FileManager.default.fileExists(atPath: audioURL.path)
        guard fileExists else { return }
        do {
            let audioPlayer = try AVAudioPlayer(contentsOf: audioURL)
            audioPlayer.enableRate = true
            audioPlayer.prepareToPlay()
            duration = audioPlayer.duration
            player = audioPlayer
        } catch { fileExists = false }
    }

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying { player.pause(); stopTimer() }
        else { player.rate = playbackSpeed; player.play(); startTimer() }
        isPlaying.toggle()
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            guard let player else { return }
            currentTime = player.currentTime
            if !player.isPlaying && isPlaying { isPlaying = false; stopTimer() }
        }
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }
}
```

- [ ] **Step 3: Rewrite ExportSheet.swift**

```swift
import SwiftUI
import AppKit

// MARK: - ExportFormatter

enum ExportFormatter {
    static func toTXT(segments: [TranscriptSegment]) -> String {
        TranscriptMerger.generateFullText(segments: segments)
    }

    static func toSRT(segments: [TranscriptSegment]) -> String {
        var result = ""
        for (index, segment) in segments.enumerated() {
            let number = index + 1
            let startTS = Formatters.srtTimestamp(seconds: segment.start)
            let endTS = Formatters.srtTimestamp(seconds: segment.end)
            result += "\(number)\n\(startTS) --> \(endTS)\n[\(segment.speaker)] \(segment.text)\n\n"
        }
        return result
    }
}

// MARK: - ExportSheet

struct ExportSheet: View {
    let meeting: Meeting
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                Text("Export Transcript").font(.title3.bold())
                Text(meeting.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 10) {
                Button { exportAs(format: .txt) } label: {
                    HStack { Image(systemName: "doc.text"); Text("Export as TXT") }.frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button { exportAs(format: .srt) } label: {
                    HStack { Image(systemName: "captions.bubble"); Text("Export as SRT") }.frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .frame(width: 220)

            Button("Cancel", role: .cancel) { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.subheadline)
        }
        .padding(32)
        .frame(minWidth: 320)
    }

    private enum ExportFormat { case txt, srt }

    private func exportAs(format: ExportFormat) {
        guard let transcriptJSON = meeting.transcript,
              let data = transcriptJSON.data(using: .utf8),
              let transcript = try? JSONDecoder().decode(Transcript.self, from: data) else { return }

        let content: String
        let fileExtension: String
        switch format {
        case .txt: content = ExportFormatter.toTXT(segments: transcript.segments); fileExtension = "txt"
        case .srt: content = ExportFormatter.toSRT(segments: transcript.segments); fileExtension = "srt"
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(meeting.title).\(fileExtension)"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? content.write(to: url, atomically: true, encoding: .utf8)
        dismiss()
    }
}
```

- [ ] **Step 4: Build and run tests**

```bash
xcodebuild -project Caddie.xcodeproj -scheme CaddieTests -configuration Debug test 2>&1 | grep "Executed.*tests"
```

- [ ] **Step 5: Commit**

```bash
git add Sources/UI/MainWindow/TranscriptView.swift Sources/UI/MainWindow/AudioPlayerView.swift Sources/UI/MainWindow/ExportSheet.swift
git commit -m "feat: polished transcript view, audio player, and export sheet"
```

---

## Task 10: OnboardingView — Permission Blocking Wizard

**Files:**
- Modify: `Sources/UI/Onboarding/OnboardingView.swift`

**Context:** First-launch wizard that blocks until Microphone and Accessibility are granted. Screen Recording is recommended but optional due to detection limitations.

- [ ] **Step 1: Rewrite OnboardingView.swift**

```swift
import SwiftUI

struct OnboardingView: View {
    @Binding var isComplete: Bool
    @State private var micStatus: PermissionStatus = Permissions.microphone
    @State private var screenStatus: PermissionStatus = Permissions.screenRecording
    @State private var accessibilityStatus: PermissionStatus = Permissions.accessibility
    @State private var isRequesting = false

    private var canProceed: Bool {
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
                if canProceed {
                    isComplete = true
                } else {
                    requestPermissions()
                }
            } label: {
                if isRequesting {
                    ProgressView().controlSize(.small)
                } else {
                    Text(canProceed ? "Get Started" : "Grant Permissions")
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

            Spacer()
        }
        .padding(40)
        .frame(minWidth: 520, minHeight: 520)
        .onAppear { refreshStatuses() }
    }

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

- [ ] **Step 2: Build and run tests**

```bash
xcodebuild -project Caddie.xcodeproj -scheme CaddieTests -configuration Debug test 2>&1 | grep "Executed.*tests"
```

- [ ] **Step 3: Commit**

```bash
git add Sources/UI/Onboarding/OnboardingView.swift
git commit -m "feat: polished onboarding wizard with permission blocking"
```

---

## Task 11: SettingsView — 4 Sections

**Files:**
- Modify: `Sources/UI/Settings/SettingsView.swift`

**Context:** Settings needs 4 sections: General, Permissions, Storage, About. Currently only has General and Storage.

- [ ] **Step 1: Rewrite SettingsView.swift**

```swift
import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @State private var launchAtLogin = false
    @State private var gracePeriod: Double = 10
    @State private var micStatus: PermissionStatus = .undetermined
    @State private var screenStatus: PermissionStatus = .undetermined
    @State private var accessibilityStatus: PermissionStatus = .undetermined
    @State private var storageUsed: String = "Calculating..."

    var body: some View {
        Form {
            generalSection
            permissionsSection
            storageSection
            aboutSection
        }
        .formStyle(.grouped)
        .frame(width: 450)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            refreshPermissions()
            refreshStorage()
        }
    }

    // MARK: - General

    private var generalSection: some View {
        Section("General") {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    do {
                        if newValue { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        CaddieLogger.app.error("Failed to update launch at login: \(error.localizedDescription)")
                        launchAtLogin = !newValue
                    }
                }

            VStack(alignment: .leading) {
                HStack {
                    Text("Grace period")
                    Spacer()
                    Text("\(Int(gracePeriod))s")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $gracePeriod, in: 5...30, step: 5)
                Text("Seconds to wait after meeting signals stop before ending recording.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        Section("Permissions") {
            permissionRow("Microphone", status: micStatus)
            permissionRow("Screen Recording", status: screenStatus)
            permissionRow("Accessibility", status: accessibilityStatus)

            Button("Open System Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
            }
        }
    }

    private func permissionRow(_ name: String, status: PermissionStatus) -> some View {
        HStack {
            Text(name)
            Spacer()
            switch status {
            case .granted:
                Text("Granted").foregroundStyle(.green).font(.caption)
            case .denied:
                Text("Denied").foregroundStyle(.red).font(.caption)
            case .undetermined:
                Text("Not Set").foregroundStyle(.secondary).font(.caption)
            }
        }
    }

    // MARK: - Storage

    private var storageSection: some View {
        Section("Storage") {
            HStack {
                Text("Audio storage used")
                Spacer()
                Text(storageUsed).foregroundStyle(.secondary)
            }

            Button("Show in Finder") {
                let appSupport = FileManager.default.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first!.appendingPathComponent("Caddie", isDirectory: true)
                NSWorkspace.shared.open(appSupport)
            }

            Button("Clean Up Orphaned Files") {
                let orphans = AudioFileManager.findOrphanedWAVs()
                for url in orphans {
                    try? FileManager.default.removeItem(at: url)
                }
                refreshStorage()
            }
            .disabled(AudioFileManager.findOrphanedWAVs().isEmpty)
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            HStack {
                Text("Version")
                Spacer()
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
                let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
                Text("\(version) (\(build))")
                    .foregroundStyle(.secondary)
            }

            Button("View Logs") {
                CaddieLogger.showLogs()
            }
        }
    }

    // MARK: - Helpers

    private func refreshPermissions() {
        micStatus = Permissions.microphone
        screenStatus = Permissions.screenRecording
        accessibilityStatus = Permissions.accessibility
    }

    private func refreshStorage() {
        let bytes = AudioFileManager.totalStorageUsed()
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        storageUsed = formatter.string(fromByteCount: Int64(bytes))
    }
}
```

- [ ] **Step 2: Build and run tests**

```bash
xcodebuild -project Caddie.xcodeproj -scheme CaddieTests -configuration Debug test 2>&1 | grep "Executed.*tests"
```

- [ ] **Step 3: Commit**

```bash
git add Sources/UI/Settings/SettingsView.swift
git commit -m "feat: settings with permissions, storage, and about sections"
```

---

## Task 12: Final Build + DMG + README

**Files:**
- Create: `README.md` (if not already present)

**Context:** Final verification — clean Release build, all tests pass, create DMG for distribution.

- [ ] **Step 1: Regenerate Xcode project**

```bash
xcodegen generate
```

- [ ] **Step 2: Run all tests**

```bash
xcodebuild -project Caddie.xcodeproj -scheme CaddieTests -configuration Debug test 2>&1 | grep "Executed.*tests"
```

Expected: all 38 tests pass.

- [ ] **Step 3: Release build**

```bash
rm -rf /tmp/CaddieBuild
xcodebuild -project Caddie.xcodeproj -scheme Caddie -configuration Release clean build CONFIGURATION_BUILD_DIR=/tmp/CaddieBuild 2>&1 | grep -E "error:|BUILD"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Verify app resources**

```bash
ls /tmp/CaddieBuild/Caddie.app/Contents/Resources/
```

Expected: `Assets.car` and `GRDB_GRDB.bundle` present. (AppIcon.icns will appear once user adds icon assets.)

- [ ] **Step 5: Create DMG**

```bash
rm -rf /tmp/CaddieDMG
mkdir -p /tmp/CaddieDMG
cp -R /tmp/CaddieBuild/Caddie.app /tmp/CaddieDMG/
ln -s /Applications /tmp/CaddieDMG/Applications
hdiutil create -volname "Caddie" -srcfolder /tmp/CaddieDMG -ov -format UDZO Caddie.dmg
```

- [ ] **Step 6: Write README.md**

Write a professional README with: features, requirements (macOS 14.2+), installation (DMG + build from source), permissions, privacy, tech stack, license.

- [ ] **Step 7: Install and smoke test**

```bash
killall Caddie 2>/dev/null
rm -rf /Applications/Caddie.app
cp -R /tmp/CaddieBuild/Caddie.app /Applications/Caddie.app
open /Applications/Caddie.app
```

Verify:
- Menu bar icon appears
- Clicking menu bar shows native dropdown with "No Active Meeting"
- "Open Caddie" opens the main window
- Dock icon appears when window opens
- Closing window hides dock icon
- Onboarding shows on first launch (reset with `defaults delete com.caddie.app`)
- Settings opens with all 4 sections

- [ ] **Step 8: Commit everything**

```bash
git add -A
git commit -m "feat: production-ready Caddie v1 with polished UX"
```
