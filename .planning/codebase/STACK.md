# Technology Stack

**Analysis Date:** 2026-03-22

## Languages

**Primary:**
- Swift - macOS application development (entire codebase in `Sources/`)
- SwiftUI - User interface framework

## Runtime

**Environment:**
- macOS (10.13+ based on AudioToolbox and CoreAudio availability, SwiftUI features suggest 12.0+ minimum)
- Native application compiled via Xcode

**Package Manager:**
- Swift Package Manager (SPM) - Integrated with Xcode
- Lockfile: `.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (present)

## Frameworks

**Core Application:**
- SwiftUI - UI framework for app interface (CaddieApp.swift, ContentView.swift, MenuBarView.swift)
- AppKit - macOS window management, system integrations (`NSApplication`, `NSWindow`, `NSWorkspace`)
- Observation - State management with `@Observable` macro (AppState.swift)
- ServiceManagement - Launch at login functionality (SettingsView.swift)

**Audio Processing:**
- AudioToolbox - Low-level audio file operations (WAV creation, compression to ALAC)
- CoreAudio - Raw audio buffer handling and system audio capture
- AVFoundation - Microphone access and audio session management

**System Integration:**
- EventKit - Calendar event monitoring (CalendarMonitor.swift)
- AppKit - Window title monitoring (AXSwift wrapper for accessibility)
- CoreGraphics - Screen event handling

**ML/AI Pipeline:**
- FluidAudio v0.12.4 - ASR (Automatic Speech Recognition) and diarization models
  - Provides: AsrManager, AsrModels, SortformerDiarizer, SortformerModels
  - Handles model downloading from HuggingFace and caching
  - Located: `Sources/Models/`, `Sources/Transcription/`

**Database:**
- GRDB v7.10.0 - SQLite ORM and query builder
  - Migration system (Migrations.swift)
  - DatabaseWriter with DatabasePool/DatabaseQueue (Database.swift)
  - Models: Meeting.swift (codable records)

**System Audio:**
- SimplyCoreAudio v4.1.1 - Simplified CoreAudio wrapper for microphone capture
  - Used in: `Sources/Recording/MicrophoneCapture.swift`

**Accessibility:**
- AXSwift v0.3.2 - Accessibility API wrapper for window title monitoring
  - Used in: `Sources/Detection/WindowTitleMonitor.swift`

**Distribution:**
- Sparkle v2.9.0 - Automatic app updates (menu bar app updating)
  - Framework integrated via SPM

**Utility Libraries (Transitive):**
- swift-nio v2.96.0 - Async networking (used by FluidAudio for model downloads)
- swift-huggingface v0.9.0 - HuggingFace API client for model downloads
- swift-transformers v1.2.0 - ML transformer models (FluidAudio dependency)
- EventSource v1.4.1 - Server-sent events handling
- yyjson v0.12.0 - Fast JSON parsing
- swift-crypto v4.3.0 - Cryptographic operations
- swift-collections v1.4.1 - Advanced collection types
- swift-atomics v1.3.0 - Thread-safe operations
- swift-system v1.6.4 - System APIs
- swift-asn1 v1.6.0 - ASN.1 encoding/decoding (certificate handling)
- swift-jinja v2.3.2 - Template rendering

## Configuration

**Environment:**
- UserDefaults - App preferences (onboarding flag in AppState.swift)
- Application Support Directory (`~/Library/Application Support/Caddie/`) - Database and audio files
  - `caddie.db` - SQLite database (PRAGMA journal_mode = WAL)
  - `audio/` subdirectory - WAV, ALAC audio files

**Build:**
- Xcode project: `Caddie.xcodeproj`
- Target: macOS app with MenuBar (statusbar) and main window
- Architectures: arm64 and x86_64 (universal binary typical for macOS)

## Platform Requirements

**Development:**
- macOS 12.0 or later (for SwiftUI features and @Observable)
- Xcode 15+ (with Swift 5.9+ for @Observable macro)
- Microphone and/or system audio capture capability
- Permissions: Microphone, Screen Recording (for system audio), Accessibility (window title monitoring), Calendar

**Production:**
- macOS 12.0 or later
- Microphone access required for core functionality
- System audio capture requires Screen Recording permission
- Calendar and accessibility integrations optional but enabled by default
- Sparkle auto-update infrastructure active

**Deployment:**
- App Store (.pkg installer) or direct DMG distribution
- Code signing with Apple developer certificate
- Notarization required for Sparkle distribution
- MenuBar app with optional main window

---

*Stack analysis: 2026-03-22*
