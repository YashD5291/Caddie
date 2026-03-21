# External Integrations

**Analysis Date:** 2026-03-22

## APIs & External Services

**ML Model Downloads:**
- HuggingFace Hub - Model hosting and download
  - SDK: swift-huggingface v0.9.0
  - Used by: `Sources/Models/ModelManager.swift`
  - Models: Parakeet ASR v3 (speech-to-text), Sortformer (speaker diarization)
  - Auth: HuggingFace token (environment or inline if public)
  - Models are cached locally after first download

**Update Infrastructure:**
- Sparkle appcast - App update checks via RSS feed
  - SDK: Sparkle v2.9.0
  - Configurable in app (future feature)
  - No active API call shown in current codebase

## Data Storage

**Databases:**
- SQLite local database
  - Location: `~/Library/Application Support/Caddie/caddie.db`
  - Client: GRDB v7.10.0
  - Schema: `Sources/Storage/Database.swift` + `Sources/Storage/Migrations.swift`
  - Tables: `meetings` (record metadata, transcripts, errors)
  - WAL mode enabled for concurrent access

**File Storage:**
- Local filesystem only (Application Support directory)
  - Audio files: `~/Library/Application Support/Caddie/audio/`
    - WAV stereo files (16kHz, 16-bit PCM, 2 channels: system + mic)
    - ALAC-compressed versions (.m4a, lossy-free)
  - Database: caddie.db
  - No cloud sync implemented

**Caching:**
- FluidAudio model cache - Local HuggingFace model caching
  - Location: OS-default cache directory (typically `~/Library/Caches/`)
  - Automatic invalidation: None (models persist until manually cleared)
  - Safe to call `downloadModelsIfNeeded()` multiple times (returns instantly if cached)

## Authentication & Identity

**Auth Provider:**
- None - Internal authentication

**Calendar Access:**
- EventKit framework - Native macOS calendar event reading
  - Full Calendar permission required (macOS 14+) or basic event access (macOS <14)
  - No OAuth, reads local/synced calendar only

**System Audio Access:**
- Screen Recording permission (macOS system prompt)
  - Not OAuth - user grants at OS level
  - Used for SystemAudioCapture (capture audio from other apps)

**Accessibility:**
- Accessibility permission (macOS system prompt)
  - Used for WindowTitleMonitor (read active app window title via AXSwift)

## Monitoring & Observability

**Error Tracking:**
- None detected in current code

**Logs:**
- OS unified logging framework (os.Logger)
  - Subsystems used:
    - `com.caddie.app` (main app and AppState)
    - `com.caddie.app` / "TranscriptionPipeline"
    - `com.caddie.app` / "AudioRecorder"
    - `com.caddie.app` / "MeetingDetector"
    - `com.caddie.app` / "CalendarMonitor"
    - `com.caddie.app` / "WindowTitleMonitor"
    - `com.caddie.app` / "AudioProcessMonitor"
    - `com.caddie.app` / "MicStateMonitor"
    - `com.caddie.app` / "AppState"
    - `com.caddie.app` / "ModelManager"
  - Logs visible in macOS Console.app
  - No remote log aggregation

## CI/CD & Deployment

**Hosting:**
- macOS distribution (App Store or DMG installer)
- No cloud backend required

**CI Pipeline:**
- Not detected in codebase (likely in separate GitHub Actions workflow or CI config)

**Update System:**
- Sparkle v2.9.0 for automatic app updates
  - Requires appcast URL configuration
  - No active update endpoint in current codebase

## Environment Configuration

**Required env vars:**
- None in core functionality
- Optional: HuggingFace token for private model repos (FluidAudio can handle)

**Secrets location:**
- No secrets management system implemented
- UserDefaults stores only onboarding flag

**Permissions Required at Runtime:**
1. Microphone - MicrophoneCapture for audio input
2. Screen Recording - SystemAudioCapture for app audio (optional, recording degrades to mic-only)
3. Accessibility - WindowTitleMonitor for meeting detection
4. Calendar - CalendarMonitor for meeting event detection
5. Full Disk Access (possibly) - For accessing other apps' audio

## Webhooks & Callbacks

**Incoming:**
- None

**Outgoing:**
- None (no remote backends)

**Internal Callbacks:**
- `MeetingDetector.onMeetingStarted` - Triggers recording when meeting detected
- `MeetingDetector.onMeetingEnded` - Stops recording when meeting ends
- Audio buffers from microphone and system audio: callback-based feed to AudioRecorder

## Model Pipeline

**ASR (Automatic Speech Recognition):**
- FluidAudio v0.12.4 → AsrManager
- Model: Parakeet v3 (from HuggingFace)
- Input: Mono audio WAV file (16kHz)
- Output: ASRSegment[] with token timings
- Location: `Sources/Transcription/ASREngine.swift`

**Diarization (Speaker Identification):**
- FluidAudio v0.12.4 → SortformerDiarizer
- Model: Sortformer (from HuggingFace, loaded via swift-huggingface)
- Input: Mono audio WAV file (16kHz)
- Output: SpeakerSegment[] with speaker IDs and time boundaries
- Location: `Sources/Transcription/DiarizationEngine.swift`

**Pipeline Orchestration:**
- TranscriptionPipeline (actor-based concurrency)
- Steps (in sequence):
  1. Mono mixdown: Stereo WAV → Mono WAV
  2. ASR: Mono → Text segments with word timings
  3. Diarization: Mono → Speaker segments
  4. Merge: Combine ASR + speaker segments
  5. Write transcript JSON to DB
  6. Compress WAV to ALAC
  7. Update meeting status to .done
  8. Delete stereo WAV file
- Location: `Sources/Transcription/TranscriptionPipeline.swift`

## Data Flow

**Meeting Detection:**
- Input: Calendar events + Window title monitoring + Audio process monitoring
- Detectors: CalendarMonitor, WindowTitleMonitor, AudioProcessMonitor
- Output: DetectedMeeting struct
- Handler: `MeetingDetector` aggregates signals

**Recording Flow:**
- Parallel capture:
  - Microphone (MicrophoneCapture via AVFoundation)
  - System audio (SystemAudioCapture via CoreAudio)
- Interleaved stereo WAV (left=system, right=mic)
- File written to: `~/Library/Application Support/Caddie/audio/{meetingId}.wav`

**Transcription Flow:**
- Input: Stereo WAV from recording
- Output: Meeting record in DB with transcript JSON
- Async queue: TranscriptionPipeline processes one meeting at a time
- User can retry failed transcriptions

**Storage:**
- Meetings table:
  - meeting_id (PK)
  - title, app, date, start_time, end_time, duration_seconds
  - status (recording → transcribing → done/error)
  - error (if failed)
  - audio_file (ALAC .m4a path)
  - transcript (JSON string with segments, speakers, full text)

---

*Integration audit: 2026-03-22*
