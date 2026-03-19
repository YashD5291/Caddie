# Caddie UX Overhaul — Design Specification

**Date:** 2026-03-20
**Status:** Approved
**Author:** Yash Desai + Claude

---

## Overview

This spec covers a comprehensive UX overhaul of Caddie to bring it from a compiling prototype to a production-quality macOS app. The existing backend logic (detection, recording, transcription, storage) is untouched — this is purely about how the app looks, feels, and behaves as a user-facing product.

### Design Principles

- **Polished Productivity + Pro Tool hybrid** — looks like Bear/Things, thinks like Audio Hijack
- **System native chrome** with a warm orange `#F97316` brand accent
- **Information density** without visual clutter — pro users want data, presented cleanly
- **macOS conventions respected** — native menus, dynamic dock behavior, system colors for light/dark mode

---

## 1. App Lifecycle & Dock Behavior

### Current Problem
`LSUIElement=true` permanently hides the dock icon. When the main window opens, there's no dock presence — feels broken.

### Design
- Keep `LSUIElement=true` in Info.plist (starts as accessory)
- `AppDelegate` dynamically switches activation policy:
  - When main window becomes key: `NSApp.setActivationPolicy(.regular)` — dock icon appears
  - When all main windows close: `NSApp.setActivationPolicy(.accessory)` — dock icon hides
- `applicationShouldTerminateAfterLastWindowClosed` returns `false` — app stays alive in menu bar
- Window detection via `NSWindow.didBecomeKeyNotification` / `NSWindow.willCloseNotification`
- Filter out Settings and MenuBar windows — only main Caddie window triggers dock icon

### Initialization
- `AppState.initialize()` changes from `throws` to non-throwing — catches errors internally
- New observable properties on AppState:
  - `var isInitialized: Bool = false` — guards against double-init
  - `var initError: String? = nil` — set to `error.localizedDescription` on failure
- Call `initialize()` in ContentView's `.task` modifier so it fires when any window appears
- If `initError` is non-nil, ContentView shows a centered error view with the message and a "Retry" button that calls `initialize()` again

### retryTranscription()
- New method: `func retryTranscription(meetingId: String) async`
- Sets meeting status to `.transcribing` and clears the `error` column in the database
- Verifies the WAV file exists at `AudioFileManager.wavPath(for: meetingId)` — if missing, sets status to `.error` with message "Audio file not found"
- If WAV exists, calls `pipeline.enqueue(meetingId: meetingId, database: database)`

---

## 2. Menu Bar Dropdown

### Current Problem
Uses `.menuBarExtraStyle(.window)` with a custom VStack — misaligned items, weird backgrounds, non-native feel.

### Design
- Use `.menuBarExtraStyle(.menu)` — renders as a native NSMenu
- Use label closure for dynamic menu bar icon (idle/recording/transcribing states) — this works with `.menu` style:
  ```swift
  MenuBarExtra { content } label: {
      Image(systemName: iconForStatus).symbolRenderingMode(.monochrome)
  }
  ```
  - Idle: `mic.badge.plus`
  - Recording: `record.circle.fill`
  - Transcribing: `waveform`
- Content uses only menu-compatible SwiftUI views: `Button`, `Text`, `Divider`, `Section`

### Menu Structure

**Idle state:**
```
No Active Meeting          (disabled Text)
─────────────────
Recent
  Sprint Planning    45m   (Button → opens main window to this meeting)
  1:1 with Alex      28m
  Design Review    1h 12m
─────────────────
Open Caddie                (Button → opens main window)
Settings...                (SettingsLink)
─────────────────
Quit Caddie                (Button → NSApp.terminate)
```

**Recording state:**
```
🔴 Sprint Planning         (disabled Text)
   Recording · 23m         (disabled Text)
Stop Recording             (Button → activates app, opens confirmation, then stops)
─────────────────
Open Caddie
Settings...
─────────────────
Quit Caddie
```

**Transcribing state:**
```
Transcribing...            (disabled Text)
─────────────────
[same actions as idle]
```

### Stop Recording Confirmation
When "Stop Recording" is clicked from the menu:
1. Call `NSApp.activate(ignoringOtherApps: true)` to bring app to front
2. Present `NSAlert` as a modal dialog (the app is now frontmost, so this works):
   - Title: "Stop Recording?"
   - Message: "This will stop recording 'Sprint Planning'."
   - Buttons: "Stop" (destructive), "Cancel"
3. If confirmed, call `appState.stopRecording()`

This is implemented in the Button action in MenuBarView, using `DispatchQueue.main.async` to allow the menu to dismiss before presenting the alert.

### Recent Meetings
- Query last 3 meetings from database ordered by `created_at DESC`
- Each item shows: title + duration right-aligned (or status text if `durationSeconds` is nil — e.g. "Transcribing" or "Error")
- Clicking opens main window and navigates to that meeting

### Opening the Main Window
- MenuBarView uses `@Environment(\.openWindow) private var openWindow`
- "Open Caddie" and recent meeting buttons call `openWindow(id: "main")` then `NSApp.activate(ignoringOtherApps: true)`
- This works because `CaddieApp` declares `Window("Caddie", id: "main")` (not `WindowGroup`) — SwiftUI creates the window if it doesn't exist, or brings it forward if it does

---

## 3. Main Window

### Layout: NavigationSplitView

**Sidebar** (220–350pt width):
- Search field at top (`.searchable`)
- Date-grouped meeting list: "Today", "Yesterday", "Mon, Mar 17"
- Section headers: `.subheadline.weight(.semibold)`, `.secondary` color
- Meeting rows: `.listRowSeparator(.hidden)` for clean look
  - Line 1: Title (semibold) | Time right-aligned (monospaced digits)
  - Line 2: StatusDot + App name + " · " + Duration
- Empty state: centered icon + "No meetings yet" + subtitle

**Detail Pane — Stats Dashboard + Transcript:**

1. **Header**
   - Title: `.title.bold()`, text-selectable
   - Metadata chips in horizontal flow with dot separators:
     - App name (with `app.fill` icon)
     - Time range (with `clock` icon)
     - Duration (with `timer` icon)
     - Speaker count (with `person.2` icon)

2. **Stats Cards Row**
   - 4 cards in HStack, each with:
     - Large value (`.title2.bold()`, orange accent color)
     - Label below (`.caption`, `.secondary`)
   - Cards: Duration | Speakers | Words (computed: `fullText.split(separator: " ").count`) | Language
   - Background: `.quaternary.opacity(0.4)`, rounded rect

3. **Audio Player**
   - Card container with `.quaternary` background, 10pt corner radius
   - Play/pause button (28pt `play.circle.fill` / `pause.circle.fill`)
   - Scrubber slider (`.controlSize(.small)`)
   - Time display: "current / duration" with monospaced digits
   - Speed picker: segmented control (0.5x, 1x, 1.5x, 2x)

4. **Transcript**
   - Section header: "Transcript" in `.headline`, `.secondary`
   - Speaker changes separated by Divider with padding
   - Speaker badge (colored capsule) + timestamp on speaker-change rows
   - Continuation segments: subtle quaternary timestamp in fixed-width column
   - Body text: `.lineSpacing(4)`, `.textSelection(.enabled)`

5. **Status States**
   - Recording: status card with red mic icon, "Recording in progress...", progress spinner
   - Transcribing: status card with orange icon, "Transcribing audio...", progress spinner
   - Error: card with red warning icon, error message, "Retry Transcription" button

### Toolbar
- Export button (primary action) — disabled unless status is `.done`
- Delete button (destructive) — shows confirmation dialog:
  - Title: "Delete Meeting?"
  - Message: "This will permanently delete the recording and transcript for '[title]'."
  - Buttons: "Delete" (destructive), "Cancel"
  - On confirm: delete database record via `Meeting.deleteOne(db, id:)`, delete audio files via `AudioFileManager.deleteAudio(meetingId:)`

### Export Sheet
- Centered layout with export icon
- Meeting title as subtitle
- Two full-width buttons: "Export as TXT" (prominent), "Export as SRT" (bordered)
- Cancel link below

---

## 4. Onboarding

### Design
First-launch wizard that blocks until all permissions are granted.

- App icon: `mic.badge.plus` SF Symbol, hierarchical rendering, large
- Title: "Welcome to Caddie" in rounded bold font
- Privacy subtitle: "Everything stays on your Mac." in tertiary
- Permission card with rows:
  - Microphone: "Record meeting audio"
  - Screen Recording: "Capture system audio from meeting apps"
  - Accessibility: "Detect active meeting windows"
- Each row shows status: green checkmark (granted), "Not set" (undetermined), red "Denied" (denied)
- Rows separated by inset dividers, card has subtle shadow and border
- Primary button: "Grant Permissions" (when not all granted) → "Get Started" (when all granted)
- Loading state during permission requests
- "Refresh" link to re-check permissions
- Frame: minWidth 520, minHeight 520

### Permission Flow
1. User clicks "Grant Permissions"
2. App requests Accessibility (shows system prompt), then Microphone (shows system prompt)
3. Screen Recording cannot be requested programmatically — a dedicated "Open System Settings" button opens Privacy & Security > Screen Recording. The detection heuristic (`CGWindowListCopyWindowInfo`) can return `.denied` even when undetermined, so treat Screen Recording as optional: if Microphone and Accessibility are granted, enable "Get Started" regardless of Screen Recording status, but show a warning that system audio capture requires it.
4. Microphone and Accessibility must be `.granted` to proceed. Screen Recording is strongly recommended but does not block.

---

## 5. Settings

### Structure
Form with `.formStyle(.grouped)`, width ~450pt.

**General Section:**
- Launch at login toggle (SMAppService)
- Grace period slider (5–30 seconds) with value label and caption explanation

**Permissions Section:**
- Three rows: Microphone, Screen Recording, Accessibility
- Each shows current status with colored label (Granted/Denied/Not Set)
- "Open System Settings" button

**Storage Section:**
- Total storage used (formatted with ByteCountFormatter)
- "Show in Finder" button → opens ~/Library/Application Support/Caddie/
- "Clean Up Orphaned Files" button

**About Section:**
- Version from bundle info
- "View Logs" button → CaddieLogger.showLogs()

---

## 6. Visual Language

### Colors
- **Chrome:** System colors — `.background`, `.secondary`, `.tertiary`, `.quaternary`
- **Accent:** `#F97316` (warm orange) for buttons, selections, active states, stat values
- **Status:** Green (done), Red pulsing (recording), Orange (transcribing), Red static (error)
- **Speaker badges:** Curated 8-color palette:
  - Blue, Teal, Rose, Forest, Amber, Rust, Indigo, Slate
  - Each badge is a capsule with white text on gradient background
  - Deterministic color assignment using a stable hash (NOT Swift's `hashValue` which is randomized per process). Use: `speaker.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }` for a DJB2-style hash that's consistent across launches

### Typography
- System fonts throughout, proper hierarchy: `.title`, `.headline`, `.subheadline`, `.caption`
- Monospaced digits for timestamps and durations
- `.lineSpacing(4)` for transcript body text

### Components
- **StatusDot:** 8pt circle, colored by status, pulsing animation for recording state
- **SpeakerBadge:** Capsule pill, white text, gradient background from curated palette
- **Stats Card:** Quaternary background, rounded rect, large value + small label
- **Status Card:** Quaternary background, icon + message + optional progress spinner

### Interactions
- All transcript text is selectable
- Meeting titles are selectable
- Confirmation dialogs for destructive actions (stop recording, delete meeting)

---

## 7. Deferred to v2

- Audio waveform visualization with click-to-seek and speaker-colored regions
- Calendar notification prompt before meetings start

---

## 8. Files Changed

Almost all changes are to existing files. One new file: `Resources/Assets.xcassets/Contents.json`.

**App lifecycle:**
- `Sources/App/CaddieApp.swift` — MenuBarExtra style, AppDelegate with dynamic dock, Window scene
- `Sources/App/AppState.swift` — non-throwing initialize(), isInitialized guard, retryTranscription()

**Menu bar:**
- `Sources/UI/MenuBar/MenuBarView.swift` — native NSMenu content, recent meetings, stop confirmation

**Main window:**
- `Sources/UI/MainWindow/ContentView.swift` — onboarding gate, initialization task, sidebar width
- `Sources/UI/MainWindow/MeetingListView.swift` — polished sidebar rows, clean sections, empty state
- `Sources/UI/MainWindow/MeetingDetailView.swift` — stats dashboard, metadata chips, wired actions
- `Sources/UI/MainWindow/TranscriptView.swift` — speaker grouping, readable layout
- `Sources/UI/MainWindow/AudioPlayerView.swift` — card container, refined controls
- `Sources/UI/MainWindow/ExportSheet.swift` — centered layout, full-width buttons

**Onboarding & settings:**
- `Sources/UI/Onboarding/OnboardingView.swift` — permission blocking, polished wizard
- `Sources/UI/Settings/SettingsView.swift` — 4 sections, permissions dashboard, storage management

**Shared components:**
- `Sources/UI/Shared/SpeakerBadge.swift` — capsule badge, curated palette, deterministic hashing
- `Sources/UI/Shared/StatusDot.swift` — larger size, recording pulse animation

**Project config:**
- `project.yml` — fix Assets.xcassets inclusion for asset catalog compilation
- `Resources/Assets.xcassets/Contents.json` — root asset catalog manifest

**Assets (user-provided):**
- `Resources/Assets.xcassets/AppIcon.appiconset/` — user will create the app icon separately
