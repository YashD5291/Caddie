# Requirements: Caddie v3.0 — Screen Recording

**Defined:** 2026-07-09
**Core Value:** Every meeting must be reliably captured, transcribed, and retrievable — no silent failures, no lost recordings, no data corruption.

## v3 Requirements

Requirements for optional screen video capture during meeting recordings. Each maps to roadmap phases.

### Video Capture

- [ ] **VID-01**: User can enable/disable screen recording via a Settings toggle (off by default)
- [ ] **VID-02**: User can choose the capture target in Settings: full display or meeting window
- [ ] **VID-03**: When enabled, video capture starts and stops automatically with the meeting recording lifecycle (manual and calendar-prompted recordings alike)
- [ ] **VID-04**: Video capture failure never aborts the audio recording — recording degrades to audio-only with the error logged and surfaced
- [x] **VID-05**: Caddie's own windows are excluded from the capture (SCContentFilter exclusion)
- [x] **VID-06**: User can choose a video quality preset in Settings (compact ~10 fps / balanced ~15 fps / high ~30 fps; HEVC with explicit bitrate caps)
- [ ] **VID-07**: A crash or power loss during recording loses at most the last ~10 seconds of video; the partial file remains playable (fragmented .mov)

### Storage

- [ ] **STOR-01**: Video is stored locally alongside the meeting's audio and linked to the meeting record (nullable `video_file` column; never in FTS5)
- [ ] **STOR-02**: Deleting a meeting deletes its video file along with its audio
- [ ] **STOR-03**: Recording is blocked pre-start when disk space is insufficient for video (disk guard raised above the current 500 MB when video is enabled)
- [x] **STOR-04**: Video/audio timeline alignment metadata (host-clock anchor) is persisted with the meeting so playback position maps to transcript time

### Playback

- [ ] **PLAY-01**: User can watch the recorded video in the meeting detail view (in-app AVKit player)
- [ ] **PLAY-02**: User can click a transcript segment to seek the video to that moment
- [ ] **PLAY-03**: Meetings without video keep the existing audio-only experience unchanged

### Export

- [ ] **EXP-01**: User can export the video file via the existing export sheet

## Future Requirements

Deferred to later milestones. Tracked but not in current roadmap.

### Resilience
- **RES-01**: Recording session crash recovery (audio side)
- **RES-02**: Automatic transcription retry with exponential backoff
- **RES-03**: Proactive disk space monitoring during recording

### Intelligence
- **INT-01**: AI summaries / action items from transcripts
- **INT-02**: Multi-language transcription support

### Polish
- **POL-01**: Structured error logging to file for bug reports
- **POL-02**: Recording health dashboard in Settings

## Out of Scope

Explicitly excluded. Documented to prevent scope creep.

| Feature | Reason |
|---------|--------|
| Third-party screen-recording library | Research verdict (2026-07-09): no viable maintained OSS library; native SCStream + AVAssetWriter, zero new dependencies |
| SCRecordingOutput implementation | macOS 15+ only — cannot serve the 14.2 deployment floor; revisit when the floor moves to 15 |
| Muxing audio into the video container | Audio pipeline (WAV → ASR → ALAC) stays untouched; alignment via persisted host-clock anchor instead |
| Consolidating system audio onto the video SCStream | System audio uses proven CoreAudio process taps; rewriting working capture code is pure risk |
| Low-FPS "context frames" mode (Dayflow-style) | Full-motion video chosen; frames-only mode is a different product pattern |
| Webcam/camera capture | Screen only — meeting apps already show participants on screen |
| Video editing/trimming | Out of product scope; users can edit exported files elsewhere |
| Cloud upload of video | Core value is local-only, privacy-first |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| VID-05 | Phase 18 | Complete |
| VID-06 | Phase 18 | Complete |
| VID-07 | Phase 18 | Pending |
| STOR-04 | Phase 18 | Complete |
| VID-03 | Phase 19 | Pending |
| VID-04 | Phase 19 | Pending |
| STOR-01 | Phase 20 | Pending |
| STOR-02 | Phase 20 | Pending |
| STOR-03 | Phase 20 | Pending |
| VID-01 | Phase 21 | Pending |
| VID-02 | Phase 21 | Pending |
| PLAY-01 | Phase 21 | Pending |
| PLAY-02 | Phase 21 | Pending |
| PLAY-03 | Phase 21 | Pending |
| EXP-01 | Phase 21 | Pending |

**Coverage:** 15/15 v3.0 requirements mapped — no orphans, no duplicates.
