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

## Manual Gate Results

Plan 20-08 hardware gate. Pre-state captured 2026-11-19 at 20:09–20:13 IST (Task 1), before the gate's first app launch.

### Gate prep (20-08 Task 1)

| Item | Measured value |
|------|----------------|
| `make test` | `** TEST SUCCEEDED **`: 426 tests, 0 failures (41.3 s test time) |
| `make build` | `** BUILD SUCCEEDED **` |
| App path | `/Users/yashdesai/Library/Developer/Xcode/DerivedData/Caddie-gaujkvsybzcmwgepbihhspvvoeyo/Build/Products/Debug/Caddie.app` |
| Bundle id / signing | `com.caddie.app`, TeamIdentifier `WBUPX3432S` |
| DB backup (plan step 2, after `make test`) | `/private/tmp/claude-501/-Users-yashdesai-Codebase-Fun-Caddie/bf261333-25c1-4294-950d-fba816e2e076/scratchpad/caddie-db-backup-20261119-201211/`: `caddie.db` 2,793,472 B, `caddie.db-wal` 1,540,912 B, `caddie.db-shm` 32,768 B. Sizes and SHA-256 match the originals; `PRAGMA integrity_check` on the copy = `ok`, 17 meetings |
| Extra DB backup (before `make test`) | `/private/tmp/claude-501/-Users-yashdesai-Codebase-Fun-Caddie/bf261333-25c1-4294-950d-fba816e2e076/scratchpad/caddie-db-backup-pre-maketest-20261119-200918/`: same three sizes and SHA-256 match (the test run did not change the DB) |
| `screenRecordingEnabled` | `defaults read com.caddie.app screenRecordingEnabled` → `1` |
| Screen Recording TCC for the Debug build | unknown: both TCC.db files deny reads without Full Disk Access. 19-05's `tccutil reset ScreenCapture` revoked the grant, so assume a re-grant is needed (Task 2 check 0) |
| Log stream | started by the orchestrator for Task 2 (not part of Task 1) |

### Pre-state (read with `sqlite3 -readonly`)

| Query | Result |
|-------|--------|
| `SELECT identifier FROM grdb_migrations` | `v1_create_meetings`, `v2_add_video_columns` (already at v2; see finding P-1) |
| `SELECT count(*) FROM meetings` | 17 |
| `pragma_table_info('meetings')` column count | 15 |
| rows with `video_file` or `video_start_offset` NOT NULL | 0 |

Pre-existing `.mov` files in `~/Library/Application Support/Caddie/audio/`, each checked for a row:

| File | Size (bytes) | mtime | Row (`meeting_id`, `status`) | `video_file` / `video_start_offset` |
|------|--------------|-------|------------------------------|-------------------------------------|
| `24204cea-ff5.mov` | 6,497,721 | Jul 31 02:09 | `24204cea-ff5`, `recording` | NULL / NULL |
| `68d4c389-96d.mov` | 5,273,362 | Jul 31 02:08 | `68d4c389-96d`, `done` | NULL / NULL |
| `884dbf89-a39.mov` | 94,581,489 | Jul 31 02:06 | `884dbf89-a39`, `done` | NULL / NULL |

**Finding P-1: the real DB was already migrated before the gate.** The test bundle is hosted in `Caddie.app`. Under XCTest, the menu-bar label auto-opens the main window, and `ContentView.task` then runs `AppState.initialize()` against the real `caddie.db`. That open migrated the real library to v2 during 20-01's test runs: the `caddie.db-wal` mtime is 18:35, which matches the 20-01 migration commits. Since 20-02, every test run has also run the orphan `.mov` sweep on the real `audio/` directory. All 3 real `.mov` files have rows and survived. Check 1 therefore cannot observe the migration live. It can still verify the result: v2 present, 17 meetings, 15 columns, all pre-existing `video_file` NULL, search works. Logged as D-1 in `deferred-items.md`, together with D-2: the tests leave 1791 row-less `.wav`/`.m4a` stems in the real `audio/` directory.

### Checks (20-08 Task 2)

| # | Check | Requirement | Measured value |
|---|-------|-------------|----------------|
| 0 | Screen Recording TCC re-grant | — | pending (Task 2) |
| 1 | Migration on real data | STOR-01 / D-04 | pending (Task 2) |
| 2 | Launch sweep kept real videos | D-10 / D-14 | pending (Task 2) |
| 3 | Real capture links the row (`video_file`, `video_start_offset`) | STOR-01 / D-05 / D-08 | pending (Task 2) |
| 4 | Quit mid-recording keeps the partial linked | D-06 | pending (Task 2) |
| 5 | Delete removes `.mov` + `.m4a` | STOR-02 / D-09 | pending (Task 2) |
| 6 | Planted orphan swept | D-10 | pending (Task 2) |
| 7 | Kill-9 crash-safety gate | D-13 / VID-07 | pending (Task 2) |
| 8 | Low-disk tier | STOR-03 | pending (Task 2) |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 90s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
