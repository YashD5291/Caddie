# Caddie Roadmap

**Last updated:** 2026-03-20

---

## Current Status

v1 shell is architecturally complete: meeting detection, stereo audio recording, storage with FTS5 search, full UI with polished UX. The transcription pipeline orchestrator exists but ASR and diarization engines are stubs pending ML SDK integration.

---

## Phase 1: ML Pipeline Integration (Critical Path)

**Status:** Not started
**Priority:** Blocking — this is the single thing standing between a demo and a working product.

- Integrate ASR engine (FluidAudio Parakeet SDK or WhisperKit fallback)
- Integrate speaker diarization engine (FluidAudio pyannote SDK or speech-swift fallback)
- Wire up ModelManager with real HuggingFace model download + caching + integrity checks
- Add model download step to onboarding flow (spec calls for progress bar + background download)
- End-to-end validation: detect meeting → record → transcribe → view transcript with speaker labels

**Stubs to replace:**
- `Sources/Transcription/ASREngine.swift`
- `Sources/Transcription/DiarizationEngine.swift`
- `Sources/Models/ModelManager.swift`

---

## Phase 2: Calendar Notification Prompt

**Status:** Designed (in v1 spec), not built
**Priority:** High — intended as the primary user interaction model.

- When a calendar event with 2+ attendees starts, show a macOS notification: "{Meeting Name} — Record this meeting?"
- User taps Yes/No
- If Yes, recording starts immediately; auto-stops via existing detection
- EventKit infrastructure already exists in CalendarMonitor

---

## Phase 3: Polish & Reliability

**Status:** Not started
**Priority:** Medium — needed before public distribution.

- Wire up Sparkle for auto-updates
- Code signing + notarization (Developer ID for non-App Store distribution)
- Orphan WAV recovery on launch (spec describes it, partially wired in AudioFileManager)
- Logger file output + log rotation (currently only os.Logger, no file writing)
- Add missing AudioFileManagerTests.swift
- Homebrew Cask formula

---

## Phase 4: Intelligence Layer

**Status:** Future
**Priority:** Low — enhances value but core product works without it.

- Meeting summaries via local LLM (Ollama) or Claude API
- Action item extraction with owners
- Semantic search with embedding model (all-MiniLM-L6-v2)
- Custom speaker names / voice profiles

---

## Phase 5: Platform Expansion

**Status:** Future
**Priority:** Low

- iCloud sync across devices
- Real-time / live transcription during meetings
- Audio waveform visualization with click-to-seek and speaker-colored regions
