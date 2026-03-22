<p align="center">
  <img src="Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" height="128" alt="Caddie icon">
</p>

<h1 align="center">Caddie</h1>

<p align="center">
  <strong>Your meetings, your Mac, your data.</strong><br>
  A native macOS menu bar app that automatically records, transcribes, and indexes your meetings — entirely on-device.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014.2+-black?logo=apple&logoColor=white" alt="macOS 14.2+">
  <img src="https://img.shields.io/badge/swift-6.0-F05138?logo=swift&logoColor=white" alt="Swift 6.0">
  <img src="https://img.shields.io/badge/ML-on--device-34C759?logo=apple&logoColor=white" alt="On-device ML">
  <img src="https://img.shields.io/badge/privacy-100%25%20local-007AFF" alt="100% local">
  <img src="https://img.shields.io/badge/tests-137%20passing-34C759" alt="137 tests">
  <img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT License">
</p>

---

## What It Does

Caddie lives in your menu bar and watches for meetings. When one starts, it records. When it ends, it transcribes. Everything stays on your Mac.

| | |
|---|---|
| **Detect** | Auto-detects Zoom, Teams, Meet, Slack, Discord, Webex, FaceTime |
| **Record** | Stereo capture — system audio + microphone in a single file |
| **Transcribe** | On-device ASR with speaker diarization via Apple Neural Engine |
| **Store** | Searchable local database with full-text search across all transcripts |
| **Notify** | macOS notifications on recording start, transcription complete, and errors |

**Zero cloud dependency.** No accounts. No uploads. No telemetry. Nothing leaves your Mac.

## How It Works

```
Meeting detected ──> Record (stereo WAV) ──> Transcribe (Parakeet ASR)
                                          ──> Diarize (Sortformer)
                                          ──> Merge + Store (SQLite/FTS5)
                                          ──> Compress (ALAC)
                                          ──> Notify
```

Caddie monitors active audio sessions via CoreAudio, window titles via Accessibility, and calendar events via EventKit. When a meeting is detected in a supported app, it captures two audio streams through a virtual tap: system audio (other participants) and your microphone.

After the meeting ends, a local ML pipeline runs Parakeet ASR and Sortformer speaker diarization on CoreML, accelerated by the Apple Neural Engine. The transcript with speaker labels is stored alongside ALAC-compressed audio in a GRDB-backed SQLite database, fully indexed for search.

## Architecture

Built on a hardened, production-solid foundation:

- **RecordingCoordinator** — Actor-based state machine managing the full lifecycle (`idle -> recording -> transcribing -> done/error`)
- **Lock-free audio** — SPSC ring buffers on the real-time CoreAudio thread (no locks, no priority inversion)
- **Protocol-based DI** — ML engines abstracted behind protocols for testability without hardware
- **137 tests** — covering state transitions, pipeline error paths, data integrity, migrations, and ring buffer behavior
- **Every error handled** — zero `try?`, zero force unwraps, all closures guarded

## Requirements

- **macOS 14.2** (Sonoma) or later
- **Apple Silicon** recommended (M1+) for Neural Engine acceleration
- Intel Macs supported but transcription will be slower

## Installation

### Download

Grab the latest `.dmg` from [Releases](../../releases), mount it, and drag Caddie to your Applications folder.

### Build from Source

```bash
brew install xcodegen
xcodegen generate
open Caddie.xcodeproj
```

Build and run with **Cmd+R** in Xcode.

## Permissions

| Permission | Why |
|---|---|
| **Microphone** | Record your voice during meetings |
| **Screen Recording** | Capture system audio from meeting apps |
| **Accessibility** | Detect active meeting windows |
| **Calendar** | Correlate recordings with calendar events |
| **Notifications** | Alert you when recordings start/stop and transcriptions complete |

All requested through standard macOS prompts. Revoke anytime in System Settings > Privacy & Security.

## Privacy

- All audio and transcripts stored locally on your Mac
- No data sent to any server, ever
- No analytics, telemetry, or crash reporting
- No account required
- ML models downloaded once, cached locally forever
- Recordings are yours — export, move, or delete anytime

## Tech Stack

| Layer | Technology |
|-------|-----------|
| **Language** | Swift 6.0, strict concurrency |
| **UI** | SwiftUI, AppKit (menu bar) |
| **Audio** | CoreAudio, AVFoundation, lock-free SPSC ring buffers |
| **ML** | FluidAudio (Parakeet ASR + Sortformer diarization on CoreML/ANE) |
| **Database** | GRDB 7.10 (SQLite with FTS5 full-text search) |
| **Detection** | CoreAudio process monitoring, AXSwift (Accessibility), EventKit |
| **Updates** | Sparkle |
| **Build** | XcodeGen, Swift Package Manager |

## Roadmap

### Recently Shipped

- Lock-free audio capture (SPSC ring buffers, no priority inversion)
- Actor-based recording coordinator with explicit state machine
- Protocol-based DI for ML engines (testable without hardware)
- Pipeline data integrity (no silent transcript loss, safe file lifecycle)
- Systematic error discipline (zero `try?`, zero force unwraps, all closures guarded)
- Precondition guards (disk space check, model download timeout)
- User feedback (recording mode in menu bar, transcription progress, macOS notifications)
- Device disconnection resilience (graceful stop, stale aggregate cleanup)

### Up Next

- **Crash recovery** — persist recording state to disk, recover incomplete sessions on relaunch
- **Auto-retry** — exponential backoff for transient transcription failures (30s, 60s, 120s)
- **Calendar prompts** — notification before meetings asking "Record?" with one-tap confirmation
- **AI summaries** — action items, key decisions, and highlights extracted from transcripts
- **Recording health dashboard** — success/failure stats, disk usage trends in Settings

### Future

- Proactive disk monitoring during recording
- Structured error logging for bug reports
- Meeting detection conflict resolution UI
- Accessibility audit / VoiceOver support

## License

MIT
