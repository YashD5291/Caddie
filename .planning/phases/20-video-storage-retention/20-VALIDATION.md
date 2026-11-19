---
phase: 20
slug: video-storage-retention
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-11-19
---

# Phase 20 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | XCTest (Xcode 26.2), hosted in `Caddie.app` (`TEST_HOST`) |
| **Config file** | `project.yml` (run `make setup` / `xcodegen generate` after adding files) |
| **Quick run command** | `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -configuration Debug -destination 'platform=macOS' -only-testing:CaddieTests/<ClassName>` |
| **Full suite command** | `make test` (require `** TEST SUCCEEDED **`; baseline 341 tests at Phase 19 end) |
| **Estimated runtime** | quick ~60–90 s (build-dominated) · full ~5–10 min |

---

## Sampling Rate

- **After every task commit:** Run the `-only-testing` quick command for the touched test class
- **After every plan wave:** Run `make test`
- **Before `/gsd:verify-work`:** Full suite must be green + manual hardware gate
- **Max feedback latency:** ~90 seconds

---

## Per-Task Verification Map

Filled in by the planner/executor. Requirement → test mapping (from 20-RESEARCH.md § Validation Architecture):

| Requirement | Behavior | Test Type | Automated Command | File Exists | Status |
|-------------|----------|-----------|-------------------|-------------|--------|
| STOR-01 | Fresh schema has `video_file` + `video_start_offset`; v1 DB upgrades in place; new cols NULL | unit | `-only-testing:CaddieTests/MigrationTests` | ✅ extend | ⬜ pending |
| STOR-01 / D-04 | `video_file` never searchable; FTS columns exactly title/transcript/app | unit | `-only-testing:CaddieTests/MigrationTests` | ✅ extend | ⬜ pending |
| STOR-01 | `Meeting` round-trips `videoFile` / `videoStartOffset` | unit | `-only-testing:CaddieTests/MeetingModelTests` | ✅ extend | ⬜ pending |
| D-07 | Inspector: playable → usable; 0-byte/no-session/garbage → unreadable; missing → `.missing` | unit | `-only-testing:CaddieTests/VideoFileInspectorTests` | ❌ W0 | ⬜ pending |
| D-13 | `onFinalized` fires exactly once on every finalize path | unit | `-only-testing:CaddieTests/WriterSinkFinalizeTests` | ❌ W0 | ⬜ pending |
| STOR-01 / D-05 / D-08 | first frame → row linked + offset; unusable finalize → NULL; start throw → NULL | unit | `-only-testing:CaddieTests/RecordingCoordinatorVideoStorageTests` | ❌ W0 | ⬜ pending |
| D-06 | stream death / late finalize / meeting #2 → per-meeting reconciliation | unit | `-only-testing:CaddieTests/RecordingCoordinatorVideoStorageTests` | ❌ W0 | ⬜ pending |
| SC4 | no factory → NULL, no inspector calls, no warning | unit | `-only-testing:CaddieTests/RecordingCoordinatorVideoStorageTests` | ❌ W0 | ⬜ pending |
| STOR-03 / D-02 | per-preset thresholds 1,874,288,000 / 2,774,288,000 / 4,124,288,000; exact boundaries | unit (pure) | `-only-testing:CaddieTests/DiskSpaceTierTests` | ❌ W0 | ⬜ pending |
| STOR-03 / D-01 / D-03 | <500 MB blocks; between → audio-only + disk warning; ≥ threshold → video; feature off unaffected | unit | `-only-testing:CaddieTests/RecordingCoordinatorVideoStorageTests` | ❌ W0 | ⬜ pending |
| STOR-02 / D-09 / D-11 | `deleteMedia` removes wav/m4a/mov in temp dir; missing `.mov` fine | unit | `-only-testing:CaddieTests/MediaFileTests` | ❌ W0 | ⬜ pending |
| D-10 / D-14 | sweep deletes only row-less `.mov`; DB error → nothing; empty ID set → nothing | unit | `-only-testing:CaddieTests/MediaFileTests` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `Tests/Mocks/MockScreenRecorder.swift`: `onFinalized` support (`finalizeDelay`, `neverFinalize`, `simulateFinalize()`), lock-guarded
- [ ] `Tests/Mocks/MockVideoInspector.swift`: scripted results + lock-guarded call log
- [ ] `RecordingCoordinator` init seams: video inspector + available-disk-space provider (production defaults unchanged)
- [ ] `AudioFileManager`: directory-injectable `deleteMedia` + orphan sweep
- [ ] Synthetic `.mov` fixture helper writing ONLY to `FileManager.default.temporaryDirectory` (D-15)
- [ ] New test files registered via `xcodegen generate`

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Real capture links row with offset ≈ 0.27 s | STOR-01 / D-08 | Needs Screen Recording TCC + real SCStream | Enable `screenRecordingEnabled`, record a short meeting, query `meetings.video_file` / `video_start_offset` |
| Delete removes `.mov` from disk | STOR-02 | End-to-end UI path | Delete the meeting in the main window, confirm `<id>.mov` is gone |
| Relaunch sweeps a planted orphan, keeps real videos | D-10 / D-14 | Launch-time behavior on real data dir | Plant `fake-id.mov`, relaunch, confirm removed and real `.mov` kept |
| Phase 18 engine still crash-safe after `onFinalized` edit | D-13 / VID-07 | Hardware + kill -9 | Re-run `scripts/kill9-recovery-gate.sh` if TCC available |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 90s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
