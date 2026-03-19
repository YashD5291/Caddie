# Caddie

A native macOS menu bar app that automatically records, transcribes, and indexes your meetings — entirely on-device.

## Features

- **Auto-detects meetings** across Zoom, Microsoft Teams, Google Meet, Slack Huddles, Discord, Webex, and FaceTime (native and browser-based)
- **Stereo recording** — captures system audio (other participants) and microphone (your voice) into a single WAV file
- **On-device transcription** with speaker diarization, powered by Apple Neural Engine
- **Local storage** — transcripts and ALAC-compressed audio stored in a searchable local database
- **Full-text search** across all meeting transcripts
- **Zero cloud dependency** — no accounts, no uploads, no telemetry

## How It Works

Caddie runs as a lightweight menu bar app monitoring active audio sessions. When it detects a meeting in a supported app, it automatically begins recording two audio streams via CoreAudio: system audio (routed through a virtual tap) and your microphone input.

When the meeting ends, the recording is handed off to a local ML pipeline that runs Parakeet ASR and pyannote speaker diarization on CoreML, accelerated by the Apple Neural Engine. The resulting transcript with speaker labels is stored alongside the compressed audio in a GRDB-backed SQLite database, fully indexed for search.

Everything stays on your Mac. Nothing leaves the device.

## Requirements

- **macOS 14.2** (Sonoma) or later
- **Apple Silicon** recommended (M1 or later) for Neural Engine acceleration
- Intel Macs are supported but transcription will be significantly slower

## Installation

### Download

Grab the latest `.dmg` from [Releases](../../releases), mount it, and drag Caddie to your Applications folder.

### Build from Source

```bash
brew install xcodegen
xcodegen generate
open Caddie.xcodeproj
```

Then build and run with **Cmd+R** in Xcode.

## Permissions

Caddie requires the following macOS permissions on first launch:

| Permission | Why |
|---|---|
| **Microphone** | Record your voice during meetings |
| **Screen Recording** | Capture system audio from meeting apps |
| **Accessibility** | Detect active meeting windows |
| **Calendar** | Correlate recordings with calendar events |

All permissions are requested through standard macOS prompts and can be revoked at any time in System Settings > Privacy & Security.

## Privacy

- All audio and transcripts are stored locally on your Mac
- No data is sent to any server, ever
- No analytics, telemetry, or crash reporting
- No account required
- Recordings are yours — stored as standard files you can export, move, or delete

## Tech Stack

Swift, SwiftUI, CoreAudio, AVFoundation, GRDB (SQLite), FluidAudio (Parakeet ASR + pyannote diarization on CoreML/ANE)

## License

MIT
