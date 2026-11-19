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

Filled in by the planner (2026-11-19). Requirement → test mapping, keyed to plan/task IDs:

| Plan/Task | Requirement | Behavior | Test Type | Automated Command | File Exists | Status |
|-----------|-------------|----------|-----------|-------------------|-------------|--------|
| 20-01 T1 | STOR-01 / D-04 | Fresh schema has `video_file` + `video_start_offset` (15 cols); v1 DB upgrades in place; `video_file` never searchable; FTS columns exactly title/transcript/app | unit | `-only-testing:CaddieTests/MigrationTests` | ✅ extend | ⬜ pending |
| 20-01 T2 | STOR-01 / D-08 | `Meeting` round-trips `videoFile` / `videoStartOffset`; defaults nil; search decodes them | unit | `-only-testing:CaddieTests/MeetingModelTests` | ✅ extend | ⬜ pending |
| 20-02 T1 | STOR-02 / D-09 / D-11 | `deleteMedia` removes wav/m4a/mov in temp dir; missing `.mov` fine; traversal ids rejected | unit | `-only-testing:CaddieTests/MediaFileTests` | ❌ W0 | ⬜ pending |
| 20-02 T2 | D-10 / D-14 / D-15 | sweep deletes only row-less `.mov`; DB error → nothing; empty ID set → nothing; list-then-read; dirs ignored | unit | `-only-testing:CaddieTests/MediaFileTests` | ❌ W0 | ⬜ pending |
| 20-03 T1 | D-07 | `isUsable` truth table; mock scripted results | unit | `-only-testing:CaddieTests/VideoFileInspectorTests` | ❌ W0 | ⬜ pending |
| 20-03 T2 | D-07 | Inspector: playable → usable; 0-byte/no-session/garbage → unreadable; missing → `.missing` | unit | `-only-testing:CaddieTests/VideoFileInspectorTests` | ❌ W0 | ⬜ pending |
| 20-04 T1 | D-13 | `onFinalized` fires exactly once on every finalize path (real AVAssetWriter) | unit | `-only-testing:CaddieTests/WriterSinkFinalizeTests` (+ Phase 18 engine suites) | ❌ W0 | ⬜ pending |
| 20-04 T2 | D-13 / D-06 | seam requirement; mock mirrors exactly-once, late, never, simulate | unit | `-only-testing:CaddieTests/ProtocolDITests` | ✅ extend | ⬜ pending |
| 20-05 T1 | STOR-03 / D-02 | per-preset thresholds 1,874,288,000 / 2,774,288,000 / 4,124,288,000; exact boundaries; message copy | unit (pure) | `-only-testing:CaddieTests/DiskSpaceTierTests` | ❌ W0 | ⬜ pending |
| 20-05 T2 | STOR-03 / D-01 / D-03 | <500 MB blocks; between → audio-only + disk warning after `.recording`; ≥ threshold → video; feature off unaffected | unit | `-only-testing:CaddieTests/RecordingCoordinatorDiskGuardTests` | ❌ W0 | ⬜ pending |
| 20-06 T1 | STOR-01 / D-05 / D-07 / D-08 / D-11 | first frame → row linked + offset; unusable finalize → delete + NULL; start throw → NULL, no file; no factory → NULL; transcription never waits | unit | `-only-testing:CaddieTests/RecordingCoordinatorVideoStorageTests` | ❌ W0 | ⬜ pending |
| 20-06 T2 | D-06 | late finalize / meeting #2 / stream death / never-finalize / missing / deleted row → per-meeting reconciliation | unit | `-only-testing:CaddieTests/RecordingCoordinatorVideoStorageTests` (+ all coordinator suites) | ❌ W0 | ⬜ pending |
| 20-07 T1-T2 | D-12 / D-01 / D-08 | README, Settings label, REQUIREMENTS/ROADMAP wording | grep + build | `make build` + grep gates in 20-07 | n/a | ⬜ pending |
| 20-08 T1-T2 | STOR-01..04 / D-13 | hardware gate (see Manual-Only Verifications) | manual | — | n/a | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `Tests/Mocks/MockScreenRecorder.swift`: `onFinalized` support (`finalizeDelay`, `neverFinalize`, `simulateFinalize()`, `createsFileOnStart`), lock-guarded (20-04)
- [ ] `Tests/Mocks/MockVideoInspector.swift`: scripted results + lock-guarded call log
- [ ] `RecordingCoordinator` init seams: available-disk-space provider (20-05), video inspector + video directory (20-06); production defaults unchanged
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
