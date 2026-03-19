# Caddie — Design Specification

**Date:** 2026-03-19
**Status:** Review
**Author:** Yash Desai + Claude

---

## Overview

Caddie is a native macOS menu bar app that automatically detects meetings, records audio, transcribes with speaker diarization, and stores everything locally. All processing happens on-device using Apple Neural Engine — no server, no cloud, no Python.

### Goals

- Detect meetings automatically across Zoom, Teams, Google Meet, Slack, Discord, Webex, FaceTime — native apps and browser-based
- Record system audio (other participants) + microphone (your voice)
- Transcribe with speaker identification after the meeting ends
- Store transcripts and compressed audio locally with full-text search
- Zero cloud dependency for core functionality

### Non-Goals (v1)

- Real-time / live transcription during meetings
- Meeting summaries via LLM (future)
- Action item extraction (future)
- iCloud sync (future)
- Custom speaker names / voice profiles (future)
- Calendar-based notification prompt before meetings (future — designed for but not built in v1)

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Caddie.app (Swift)                        │
│                    Menu Bar + Full Window                    │
│                                                             │
│  ┌──────────────────────┐  ┌─────────────────────────────┐ │
│  │   Meeting Detector    │  │      Recording Engine        │ │
│  │                       │  │                              │ │
│  │ • Audio process enum  │  │ • CoreAudio Taps (system)   │ │
│  │   (macOS 14+, by PID)│──│ • AVAudioEngine (mic)       │ │
│  │ • CoreAudio mic       │  │ • 2-ch stereo WAV           │ │
│  │                       │  │   (ch0=system, ch1=mic)     │ │
│  │   listener (no perm)  │  │                              │ │
│  │ • AXObserver window   │  └──────────────┬──────────────┘ │
│  │   titles (event-      │                 │                 │
│  │   driven, no polling) │                 │ meeting ends    │
│  │ • EventKit calendar   │                 ▼                 │
│  │   (fallback + title)  │  ┌─────────────────────────────┐ │
│  └──────────────────────┘  │   Transcription Pipeline     │ │
│                             │         (FluidAudio)          │ │
│                             │                              │ │
│                             │ 1. Parakeet ASR (CoreML/ANE) │ │
│                             │    → text + word timestamps  │ │
│                             │                              │ │
│                             │ 2. pyannote diarization      │ │
│                             │    (CoreML/ANE)              │ │
│                             │    → speaker segments        │ │
│                             │                              │ │
│                             │ 3. Merge: align speakers     │ │
│                             │    with transcribed text     │ │
│                             │                              │ │
│                             │ 4. Compress WAV → ALAC       │ │
│                             └──────────────┬──────────────┘ │
│                                            │                 │
│                                            ▼                 │
│  ┌──────────────────────────────────────────────────────┐   │
│  │              Local Storage (SQLite + Files)           │   │
│  │  ~/Library/Application Support/Caddie/                │   │
│  │  ├── caddie.db          (meetings, transcripts, FTS5) │   │
│  │  ├── audio/             (compressed ALAC files)        │   │
│  │  └── models/            (cached CoreML models)        │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                             │
│  ┌────────────────────┐  ┌───────────────────────────────┐ │
│  │   Menu Bar UI       │  │       Full Window UI          │ │
│  │ • Status indicator  │  │ • Meeting list (sidebar)      │ │
│  │ • Current meeting   │  │ • Transcript viewer           │ │
│  │ • Quick actions     │  │ • Audio player                │ │
│  │ • "Open Caddie"     │  │ • Full-text search            │ │
│  └────────────────────┘  │ • Export (TXT, SRT)            │ │
│                           └───────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

---

## Meeting Detection

### Strategy

Multi-signal detection requiring 2+ signals to confirm a meeting. Priority order:

#### Signal 1: Audio Process Enumeration (Primary — macOS 14+)

Uses `kAudioHardwarePropertyProcessObjectList` + `kAudioProcessPropertyPID` to enumerate which processes are actively using audio. If a known meeting app (Zoom, Teams, Slack, etc.) is using audio, that's a strong meeting signal.

- **Permission:** None required for enumeration
- **Implementation reference:** AudioCap's `CoreAudioUtils.swift` (`readProcessList()`)
- **Advantage:** Tells you exactly *which app* is using audio, not just that the mic is active
- **macOS requirement:** 14.0+ (Sonoma)

#### Signal 2: CoreAudio Mic State Listener (Supporting)

`kAudioDevicePropertyDeviceIsRunningSomewhere` — event-driven callback when any app activates/deactivates the microphone. No polling.

- **Permission:** None required
- **Implementation:** SimplyCoreAudio (MIT, Swift Package Manager) wraps this as `isRunningSomewhere()` with NotificationCenter callbacks
- **Advantage:** Zero-cost, event-driven, fires instantly when mic state changes
- **Limitation:** Tells you mic is active, not which app is using it (Signal 1 covers this gap)

#### Signal 3: Window Title Observation (Supporting)

AXObserver for event-driven window title changes. When a meeting app's window title changes to a meeting pattern, that's a signal.

- **Permission:** Accessibility
- **Implementation:** AXSwift (MIT, SPM) — `AXObserver` with `kAXTitleChangedNotification` and `kAXWindowCreatedNotification`
- **No polling** — purely event-driven
- **Patterns:**
  - Zoom: "Zoom Meeting" or "Zoom Meeting-ID: XXX-XXX-XXXX" (Zoom does NOT show meeting name)
  - Teams: Shows meeting name in window title
  - Google Meet (browser): Tab title starts with "Meet - "
  - Slack huddle: Separate huddle window appears
- **Browser tabs:** AppleScript via NSAppleScript for Chrome/Safari/Arc tab titles. Firefox not supported via AppleScript.

#### Signal 4: Calendar Integration (Fallback + Title Source)

EventKit — query current calendar events to check if a meeting is scheduled right now.

- **Permission:** Calendar access
- **Primary value:** Provides the meeting title when the app doesn't (Zoom just shows "Zoom Meeting")
- **Secondary value:** Confirms a meeting should be happening right now
- **Reference implementation:** MeetingBar (Apache 2.0) for parsing meeting URLs from calendar events
- **Future use:** Calendar-based notification prompt ("Recording this meeting?" yes/no) before meetings start

### Decision Logic

```
Meeting confirmed when:
  (audio_process_is_meeting_app AND mic_active)
  OR (audio_process_is_meeting_app AND window_title_matches)
  OR (mic_active AND calendar_event_now)
  OR (window_title_matches AND calendar_event_now)

Meeting title priority:
  1. Calendar event name (most reliable)
  2. Window title (cleaned of app chrome)
  3. "{App Name} Meeting" (fallback)
```

### Meeting End Detection

- Grace period: 15 seconds of "no meeting signals" before declaring meeting over
- Prevents false stops from brief audio drops, app switching, muting
- Configurable in settings

### Known Meeting Apps

| App | Process Names | Window Title Pattern |
|-----|--------------|---------------------|
| Zoom | `zoom.us` | "Zoom Meeting" |
| Microsoft Teams | `Microsoft Teams`, `Teams` | Shows meeting name |
| Google Meet | Chrome/Safari/Arc/Firefox | Tab: "Meet - {name}" |
| Slack | `Slack` | Separate huddle window |
| Discord | `Discord` | Shows channel/call name |
| Webex | `Webex`, `CiscoWebex` | Shows meeting name |
| FaceTime | `FaceTime` | Shows contact name |
| Skype | `Skype` | Shows call info |

---

## Audio Capture

### System Audio: CoreAudio Taps (macOS 14.2+)

Captures the meeting app's audio output (what you hear — other participants' voices) using Apple's native process tap API. No virtual audio drivers needed.

- **API:** `CATapDescription` + `AudioHardwareCreateProcessTap`
- **Can target specific process by PID** — captures only the meeting app's audio, not all system sounds
- **Permission:** Screen Recording (TCC `kTCCServiceScreenCapture`)
- **Output:** Raw PCM audio fed into an aggregate device
- **Reference implementations:**
  - AudioCap (github.com/insidegui/AudioCap) — best reference for the tap API
  - AudioTee (github.com/makeusabrew/audiotee) — CLI that pipes PCM to stdout

### Microphone: AVAudioEngine

Captures the user's voice from the default input device.

- **API:** `AVAudioEngine` input tap
- **Permission:** Microphone (TCC `kTCCServiceMicrophone`)
- **Output:** PCM audio buffer

### Mixing

Both streams are recorded as a **2-channel stereo WAV** (16kHz, 16-bit signed LE):
- **Channel 0:** System audio (remote participants)
- **Channel 1:** Microphone (your voice)

This stereo separation significantly improves diarization accuracy — channel energy ratios provide a strong prior for speaker assignment (you are always channel 1). A mono mixdown is created for ASR input. No ffmpeg dependency.

### File Format

- **During recording:** WAV stereo (uncompressed, for maximum quality during capture)
- **After transcription:** Compressed to ALAC (Apple Lossless Audio Codec, native AudioToolbox support, ~50% size reduction)
- **1-hour meeting:** ~230 MB stereo WAV → ~100 MB ALAC
- **Why ALAC over FLAC:** AudioToolbox natively supports ALAC encoding. FLAC encoding is not guaranteed by Apple's framework — would require bundling libFLAC.

---

## Transcription Pipeline

Runs after the meeting ends. Entirely on-device using FluidAudio SDK with CoreML models on Apple Neural Engine.

### Step 1: Speech-to-Text (Parakeet TDT 0.6B v3)

- **Model:** `FluidInference/parakeet-tdt-0.6b-v3-coreml` from HuggingFace
- **Runtime:** CoreML on Apple Neural Engine
- **Performance:** ~110-145x real-time on M4 Pro (1-hour meeting transcribed in ~30 seconds)
- **Languages:** 25 European languages with dynamic switching
- **Output:** Text segments with word-level timestamps

### Step 2: Speaker Diarization (pyannote v4 → CoreML)

- **Model:** `FluidInference/speaker-diarization-coreml` from HuggingFace
- **Components:**
  - Segmentation model (pyannote segmentation-3.0, CoreML) — detects speaker activity regions
  - Embedding model (WeSpeaker ResNet34, CoreML) — generates speaker embedding vectors
  - Clustering (VBx / agglomerative) — groups segments by speaker
- **Runtime:** CoreML on Apple Neural Engine
- **Performance:** ~60x real-time on M1 (1-hour meeting diarized in ~1 minute)
- **Model size:** ~129 MB total
- **Output:** Speaker-labeled time segments

### Step 3: Merge

Align Parakeet's transcription segments with pyannote's speaker segments by temporal overlap. Each transcribed segment is assigned the speaker label with the maximum temporal overlap.

- **Output format:**
  ```json
  {
    "segments": [
      {
        "start": 0.0,
        "end": 4.52,
        "text": "Let's start with the Q3 numbers.",
        "speaker": "SPEAKER_00",
        "words": [
          {"word": "Let's", "start": 0.0, "end": 0.38}
        ]
      }
    ],
    "language": "en",
    "num_speakers": 4,
    "duration": 3542.5
  }
  ```

### Step 4: Compress Audio

Convert the stereo WAV to ALAC (Apple Lossless) using AudioToolbox's `ExtAudioFile` API. Delete the WAV after successful compression and verification.

### Model Management

- Models downloaded from HuggingFace on first launch
- Cached in `~/Library/Application Support/Caddie/models/`
- Total download: ~129 MB (diarization) + ~600 MB-1.2 GB (Parakeet, depending on quantization)
- Progress shown in UI during first-launch setup
- Corrupted/incomplete downloads detected on startup and re-downloaded

### Error Recovery

- **Transcription failure (OOM, model error):** Status set to `error` with message. User can retry from the UI via "Retry Transcription" button.
- **App crash during recording:** On next launch, scan for orphaned WAV files in the temp directory. Offer to transcribe them.
- **Model download failure:** Retry with exponential backoff. Show clear error in UI with manual retry option.
- **Back-to-back meetings:** Transcription is queued. Active recording always takes priority over transcription. If ANE is busy with transcription and a new meeting starts, transcription is paused (CoreML supports this via `MLComputeUnits` configuration) and recording begins.

---

## Storage

### Database: SQLite with WAL + FTS5

- **Location:** `~/Library/Application Support/Caddie/caddie.db`
- **Mode:** WAL (Write-Ahead Logging) for concurrent read/write safety
- **FTS5:** Full-text search index on meeting title + transcript text

#### Schema

```sql
CREATE TABLE meetings (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    meeting_id TEXT NOT NULL UNIQUE,  -- UUID for external reference
    title TEXT NOT NULL,
    app TEXT NOT NULL DEFAULT 'Unknown',
    date TEXT NOT NULL,
    start_time TEXT NOT NULL,
    end_time TEXT NOT NULL,
    duration_seconds INTEGER DEFAULT 0,
    audio_file TEXT,
    status TEXT NOT NULL DEFAULT 'recording',
    -- status: recording → transcribing → done → error
    transcript TEXT,  -- JSON string
    error TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_meetings_date ON meetings(date);
CREATE INDEX idx_meetings_status ON meetings(status);
CREATE INDEX idx_meetings_meeting_id ON meetings(meeting_id);

-- FTS5 for full-text search on titles and transcripts
CREATE VIRTUAL TABLE meetings_fts USING fts5(
    title, transcript,
    content=meetings, content_rowid=id,
    tokenize='porter unicode61'
);

-- Sync triggers to keep FTS5 index up to date
CREATE TRIGGER meetings_ai AFTER INSERT ON meetings BEGIN
    INSERT INTO meetings_fts(rowid, title, transcript)
    VALUES (new.id, new.title, new.transcript);
END;

CREATE TRIGGER meetings_ad AFTER DELETE ON meetings BEGIN
    INSERT INTO meetings_fts(meetings_fts, rowid, title, transcript)
    VALUES ('delete', old.id, old.title, old.transcript);
END;

CREATE TRIGGER meetings_au AFTER UPDATE ON meetings BEGIN
    INSERT INTO meetings_fts(meetings_fts, rowid, title, transcript)
    VALUES ('delete', old.id, old.title, old.transcript);
    INSERT INTO meetings_fts(rowid, title, transcript)
    VALUES (new.id, new.title, new.transcript);
END;
```

**Note:** `id` is `INTEGER PRIMARY KEY` (SQLite rowid alias) for FTS5 compatibility. `meeting_id` (TEXT UUID) is used for external/display reference.

### Audio Files

- **Location:** `~/Library/Application Support/Caddie/audio/`
- **Format:** ALAC (compressed lossless after transcription)
- **Naming:** `{meeting_id}.m4a` (ALAC in M4A container)
- **Lifecycle:** WAV during recording → ALAC after transcription → user can delete from UI

### SQLite Library

Use GRDB.swift (MIT, SPM) — the standard Swift SQLite wrapper with:
- Type-safe record types via `Codable`
- Migration support
- FTS5 integration
- WAL mode configuration
- Observation for reactive UI updates (`ValueObservation`)

---

## User Interface

### Menu Bar

A `MenuBarExtra` (macOS 13+) with a small icon showing current state:

| State | Icon | Dropdown Content |
|-------|------|-----------------|
| **Idle** | Caddie icon (grey) | "No active meeting" + recent meetings list |
| **Recording** | Caddie icon (red, pulsing) | Meeting title, duration timer, "Stop" button |
| **Transcribing** | Caddie icon (orange) | "Transcribing: {title}..." with progress |

Dropdown includes:
- Current meeting info (when recording/transcribing)
- Last 5 meetings (quick access)
- "Open Caddie" button → opens full window
- "Preferences..." → settings
- "Quit Caddie"

### Full Window

A `WindowGroup` with a two-pane layout:

**Left sidebar:**
- Search field (FTS5-powered)
- Meeting list grouped by date ("Today", "Yesterday", "Mon, Mar 17")
- Each item shows: title, app badge, duration, status dot (green=done, orange=transcribing, red=error)

**Right main area:**
- Meeting header: title, app, date, start–end time, duration, number of speakers
- Audio player: native playback controls, scrub bar, speed control (0.5x, 1x, 1.5x, 2x)
- Transcript: speaker-labeled segments with timestamps
  - Speaker labels color-coded (SPEAKER_00 = blue, SPEAKER_01 = green, etc.)
  - Click timestamp to seek audio player to that point
  - Text is selectable and copyable
- Actions: Export (TXT, SRT), Delete meeting

**Empty state:** "No meetings yet. Caddie will automatically detect and record your meetings."

### Settings

- Auto-launch at login (toggle, via `SMAppService`)
- Meeting detection sensitivity (grace period slider)
- Audio: select mic input device
- Storage: show total space used, option to delete all audio
- Calendar: connect/disconnect calendars
- About: version, model info, licenses

---

## macOS Permissions

| Permission | Why | Requested When |
|------------|-----|---------------|
| **Microphone** | Record user's voice | First meeting detected |
| **Screen Recording** | Capture system audio via CoreAudio Taps (primary reason). Also enables `CGWindowListCopyWindowInfo` as a fallback for window titles. | First meeting detected |
| **Accessibility** | Event-driven window title monitoring via AXObserver (primary window title mechanism — event-driven, no polling) | App launch |
| **Calendar** | Read current events for meeting detection + titles | Settings or first launch |

Permissions are requested with clear explanations via `NSMicrophoneUsageDescription`, `NSScreenCaptureUsageDescription`, etc. in Info.plist.

---

## Auto-Launch

Use `SMAppService.mainApp.register()` (macOS 13+) to register as a Login Item. No LaunchAgent plist needed. Toggled via Settings.

---

## Dependencies

| Dependency | Purpose | License | Integration |
|------------|---------|---------|-------------|
| **FluidAudio** | Parakeet ASR + pyannote diarization (CoreML/ANE) | Apache 2.0 (SDK) + CC-BY-4.0 (models) | CocoaPods (or SPM if available) |
| **SimplyCoreAudio** | CoreAudio HAL wrapper (mic state listener) | MIT | SPM |
| **AXSwift** | Accessibility API wrapper (window title observer) | MIT | SPM |
| **GRDB.swift** | SQLite wrapper with FTS5 + WAL + migrations | MIT | SPM |
| **Sparkle** | Auto-update framework (non-App Store distribution) | MIT | SPM |

All dependencies are MIT or Apache 2.0. No GPL code.

### Fallback Strategy

If FluidAudio becomes unavailable or unsuitable:
- **ASR fallback:** WhisperKit (MIT, by Argmax) — proven CoreML/ANE Whisper implementation. Same team as SpeakerKit.
- **Diarization fallback:** speech-swift (Apache 2.0, by soniqo) — pure Swift, MLX/CoreML, pyannote models. Or build a custom pipeline using pre-exported CoreML models from `FluidInference/speaker-diarization-coreml` on HuggingFace.

---

## Distribution

This app **cannot be sandboxed** due to the permissions required (Accessibility, Screen Recording, CoreAudio Taps). It will be distributed outside the Mac App Store:

- **Direct download** from website (signed + notarized with Developer ID)
- **Homebrew Cask** for command-line installation
- **Sparkle** for automatic updates

---

## Privacy & Recording Consent

- On first launch, display a notice that the app records meeting audio and users are responsible for compliance with local recording consent laws (one-party vs two-party consent jurisdictions)
- The app does NOT notify other meeting participants that recording is active — this is the user's responsibility
- All data stays on-device — no cloud, no analytics, no telemetry
- Users can delete individual meetings or all data from Settings

---

## First-Launch Onboarding

1. **Welcome screen** — what Caddie does, privacy commitment
2. **Permission requests** — step-by-step with clear explanations:
   - Microphone: "To capture your voice during meetings"
   - Screen Recording: "To capture meeting audio from other participants"
   - Accessibility: "To detect when you join a meeting"
   - Calendar (optional): "To get meeting titles and improve detection"
3. **Model download** — progress bar, estimated time, can happen in background
4. **Auto-launch** — offer to enable "Start at login"
5. **Ready** — "Caddie is now monitoring for meetings. You'll see a notification when a meeting is detected."

---

## Logging

- Log file: `~/Library/Logs/Caddie/caddie.log`
- Log levels: `debug`, `info`, `warning`, `error`
- Logged events: meeting detection signals, recording start/stop, transcription progress, errors
- Log rotation: keep last 7 days
- Accessible from Settings > "Show Logs" button

---

## Project Structure

```
Caddie/
├── App/
│   ├── CaddieApp.swift              # @main, MenuBarExtra + WindowGroup
│   └── AppState.swift               # Observable: idle/recording/transcribing
├── Detection/
│   ├── MeetingDetector.swift         # Orchestrates all detection signals
│   ├── AudioProcessMonitor.swift     # kAudioProcessPropertyPID enumeration
│   ├── MicStateMonitor.swift         # SimplyCoreAudio mic listener
│   ├── WindowTitleMonitor.swift      # AXSwift observer per meeting app
│   ├── CalendarMonitor.swift         # EventKit current event lookup
│   └── MeetingPatterns.swift         # Known apps, process names, title patterns
├── Recording/
│   ├── AudioRecorder.swift           # Orchestrates system + mic capture
│   ├── SystemAudioCapture.swift      # CATapDescription → aggregate device
│   └── MicrophoneCapture.swift       # AVAudioEngine input tap
├── Transcription/
│   ├── TranscriptionPipeline.swift   # ASR → diarize → merge → compress
│   ├── ASREngine.swift               # FluidAudio Parakeet wrapper
│   ├── DiarizationEngine.swift       # FluidAudio pyannote wrapper
│   └── TranscriptMerger.swift        # Align speaker labels with text
├── Storage/
│   ├── Database.swift                # GRDB setup, queries
│   ├── Migrations.swift              # Schema versioning for future updates
│   ├── Meeting.swift                 # Codable record type
│   └── AudioFileManager.swift        # WAV → ALAC, file lifecycle
├── UI/
│   ├── MenuBar/
│   │   ├── MenuBarView.swift         # StatusBarItem dropdown
│   │   └── RecordingIndicator.swift  # Animated recording dot
│   ├── MainWindow/
│   │   ├── ContentView.swift         # Two-pane layout
│   │   ├── MeetingListView.swift     # Sidebar with search + date groups
│   │   ├── MeetingDetailView.swift   # Header + player + transcript
│   │   ├── TranscriptView.swift      # Speaker-labeled segments
│   │   ├── AudioPlayerView.swift     # Playback controls
│   │   └── ExportSheet.swift         # TXT/SRT export
│   ├── Settings/
│   │   └── SettingsView.swift        # Preferences window
│   └── Shared/
│       ├── SpeakerBadge.swift        # Color-coded speaker labels
│       └── StatusDot.swift           # Green/orange/red status indicator
├── Models/
│   └── ModelManager.swift            # Download + cache CoreML models from HF
└── Utilities/
    ├── Formatters.swift              # Duration, date, timestamp, SRT
    └── Permissions.swift             # Permission request helpers
```

---

## System Requirements

- **macOS:** 14.2+ (Sonoma) — for CoreAudio Taps
- **Hardware:** Apple Silicon (M1 or later) — for CoreML/ANE
- **RAM:** 8 GB minimum
- **Disk:** ~1.5 GB for models + audio storage grows with usage

---

## Future Features (Designed For, Not Built in v1)

### Calendar Notification Prompt

When a calendar event with 2+ attendees starts:
1. Show a macOS notification: "{Meeting Name} — Record this meeting?"
2. User taps "Yes" or "No"
3. If "Yes", recording starts immediately
4. Auto-stops when meeting ends (via existing detection)

The v1 architecture includes EventKit integration and notification infrastructure to support this.

### Meeting Summaries via LLM

After transcription, send transcript to a local LLM (Ollama) or cloud API (Claude) for:
- 3-5 sentence summary
- Action items with owners
- Key decisions

The `Meeting` data model has room for a `summary` field.

### Semantic Search

Embed transcript chunks using a small embedding model (all-MiniLM-L6-v2) and store vectors for meaning-based search ("discussions about budget" finding mentions of "Q3 numbers" and "revenue targets").

---

## Risk Assessment

| Risk | Mitigation |
|------|-----------|
| FluidAudio SDK changes or becomes unavailable | Models are CC-BY-4.0 on HuggingFace; can build own CoreML pipeline using pyannote-rs or speech-swift as fallback |
| macOS changes CoreAudio Tap API | Apple is investing in this API (introduced 14.2, refined 14.4); direction is stable |
| Screen Recording permission re-consent prompts (Sequoia) | Clear user onboarding explaining why each permission is needed |
| Large model download on first launch | Show progress UI, allow background download, models cached permanently |
| Zoom doesn't show meeting name in title | Calendar integration provides the title; fallback to "Zoom Meeting" |
| FaceTime blocks system audio capture | Known macOS limitation; mic-only recording as fallback, noted in UI |
