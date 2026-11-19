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
| 0 | Screen Recording TCC re-grant | — | Developer confirmed the Debug `Caddie.app` is ON in Screen Recording ("done", 21:53 IST). Launch log at 21:53:51: `Screen recording enabled` |
| 1 | Migration on real data | STOR-01 / D-04 | First gate launch `open -n` at 21:53:51 IST (PID 44670). `sqlite3 -readonly`: `grdb_migrations` = `v1_create_meetings`, `v2_add_video_columns`; `count(*)` = 17 (pre-state 17); `pragma_table_info` = 15 columns; rows with video columns NOT NULL = 0. Search: FTS query `meetings_fts MATCH 'Closure'` (same subquery as `Meeting.swift:107`) returns `73bdee7c-e1b` "Closure Overview" and `c774fa8c-82b`; `MATCH 'video_file'` returns 0. Search was checked with an FTS query, not in the app's UI. Migration observed as end-state only (P-1) |
| 2 | Launch sweep kept real videos | D-10 / D-14 | After launch, all 3 pre-state `.mov` files exist with unchanged sizes (6,497,721 / 5,273,362 / 94,581,489). The launch log has no `Removing orphaned video` / `Cleaned up … orphaned video` / `Skipping orphan video cleanup` line, which is the expected silent path when every `.mov` has a row. Only `Cleaned up 3 orphaned temp file(s)` (DATA-05). Note: the shipped log text is `Removing orphaned video <file>`, not the plan's `Removed orphaned video` |
| 3 | Real capture links the row (`video_file`, `video_start_offset`) | STOR-01 / D-05 / D-08 | Manual recording started 21:55:53 and stopped 21:56:45 IST, both through AX menu clicks. Meeting `f4ec2fee-1a8`; `ScreenRecorder started: target=display(main) preset=balanced dims=1920x1240 -> f4ec2fee-1a8.mov`. **Link early:** 0.02 s after the first frame, the log shows `Video anchor for <id>: audioTicks=4520922697069 firstFrameTicks=4520929624161 offset=0.289s` and then `Linked video <id> to meeting <id>`. `sqlite3 -readonly` while still recording: `f4ec2fee-1a8 \| f4ec2fee-1a8.mov \| 0.288628833339317 \| recording`. **Verify after finalize:** `ScreenRecorder writer finalized` at 21:56:45.326, then `Video verified for <id>: 50.5s, 1 track(s)` at 21:56:45.350, after transcription had already started at 21:56:45.237 (it did not wait). Row after transcription: `f4ec2fee-1a8 \| f4ec2fee-1a8.mov \| 0.288628833339317 \| done`, so the link was kept. `video_start_offset` = 0.288628833339317 s, within 0.05–1.5 s (19-05 measured 0.273 s). `--validate-mov`: `VALIDATE isPlayable=true duration=50.53333333333333`, exit 0; the wall-clock video span was 21:55:54.74 → 21:56:45.23 = 50.5 s. Files: `f4ec2fee-1a8.mov` 8,556,637 B, `f4ec2fee-1a8.m4a` 16,054 B. Note: the unified log redacts the meeting id as `<private>`; the id was correlated through the public ScreenRecorder line and the DB row |
| 4 | Quit mid-recording keeps the partial linked | D-06 | Manual recording started 21:57:55 IST, meeting `cab32fda-e3d`. Log: `Video anchor for <id>: audioTicks=4523847205373 firstFrameTicks=4523850831985 offset=0.151s`, then `Linked video <id> to meeting <id>`. "Quit Caddie" was clicked from the menu bar while recording, at 21:58:29 (log `Caddie terminating` 21:58:28.998). **Before relaunch:** `sqlite3 -readonly` = `cab32fda-e3d \| cab32fda-e3d.mov \| 0.151108833320905 \| recording`, so the link and offset persisted. `--validate-mov`: `VALIDATE isPlayable=true duration=30.2`, exit 0. Wall-clock span 21:57:56.45 → 21:58:29.0 ≈ 32.5 s, so tail loss ≈ 2.3 s (within the ~10 s allowance). Files: `cab32fda-e3d.mov` 4,169,608 B, `cab32fda-e3d.wav` 1,046,994 B. **Relaunch** `open -n` at 21:59:01 (PID 46209): the `.mov` still exists at the same size, the row is unchanged, and there is no orphan-video log line. Pre-existing observation, outside Phase 20: after a quit mid-recording, the row stays `status = recording` and the `.wav` is never compressed or transcribed. Pre-state row `24204cea-ff5` (Jul 31) is in the same state. Logged as follow-up D-3 |
| 5 | Delete removes `.mov` + `.m4a` | STOR-02 / D-09 | Done in the main window via AX, with no direct file or DB writes. Selected the sidebar row "Manual Recording / 9:55 PM". The detail pane read "9:55 PM – 9:56 PM", duration "0:50", which identifies `f4ec2fee-1a8`. Pressed toolbar **Delete**; the sheet read "Delete Meeting? This will permanently delete the recording and transcript for 'Manual Recording'." Pressed the sheet's **Delete** at 22:04:06 IST. After: `sqlite3 -readonly` returns `count(*) WHERE meeting_id='f4ec2fee-1a8'` = 0 and total meetings = 18 (17 pre-state + check 4's `cab32fda-e3d`). `ls audio/ \| grep -c f4ec2fee` = 0, so `f4ec2fee-1a8.mov` (8,556,637 B) and `f4ec2fee-1a8.m4a` (16,054 B) are gone. Log: one debug line `No <private> to delete`, for the already-compressed `.wav` (D-11: a missing file is not an error); no warning or error. Every other `.mov` is untouched (4 files, same sizes) |
| 6 | Planted orphan swept | D-10 | Quit Caddie via the menu (`Caddie terminating` 22:04:48). Confirmed `zz-phase20-orphan-test.mov` was absent, then `touch`ed it (0 B). Relaunched with `open -n` at 22:04:52 (PID 47049). Log: `Removing orphaned video <private>` 22:04:52.799764, then `Cleaned up 1 orphaned video file(s)` 22:04:52.799935, so exactly one file was removed. `ls zz-phase20-orphan-test.mov` → `No such file or directory`. All 4 `.mov` files with rows survived at the same sizes: `24204cea-ff5` 6,497,721, `68d4c389-96d` 5,273,362, `884dbf89-a39` 94,581,489 (pre-state), and `cab32fda-e3d` 4,169,608 (check 4). The filename is redacted in the unified log (D-4), so the planted file is identified by elimination: it is the only `.mov` without a row, and it is the one that disappeared |
| 7 | Kill-9 crash-safety gate | D-13 / VID-07 | **Run 1** (22:05:48 IST, `bash scripts/kill9-recovery-gate.sh`; Caddie quit first): the build succeeded, then `GATE FAIL: harness exited before becoming ready … HARNESS_ERROR The user declined TCCs for application, window, display capture`, after 28.0 s. Cause: the script runs the binary directly from the shell, so TCC attributes the capture to the responsible parent (the `claude` CLI's terminal), not to `Caddie.app`. That is an environment limitation, not an engine defect; the app's own captures in checks 3–4 had TCC. Logged as D-5. **Run 2** (23:10:54 IST) repeated the script's exact steps, but launched the same Debug binary through LaunchServices so `Caddie.app` is the responsible process: `open -n --stdout/--stderr <log> <app> --args --screen-record-harness <out>`. Log: `HARNESS_READY pid=48332`. Recorded 30 s, then `kill -9 48332` at 23:11:25. Output: `recording.mov` 3,418,613 B. `--validate-mov` → `VALIDATE isPlayable=true duration=30.166666666666668`, exit 0. Script criterion: duration ≥ 30 − 10 = 20 s → **PASS** (no fragment lost). This passes on the local OS (macOS 26) only; the macOS 14.2 floor re-run is still a milestone-close item |
| 8 | Low-disk tier | STOR-03 | Unit-verified only (RecordingCoordinatorDiskGuardTests + DiskSpaceTierTests via injected capacity); a real full disk is unsafe to produce. 426/426 green in `make test` (gate prep) |


### Cleanup (after check 8)

| Item | Result |
|------|--------|
| `defaults delete com.caddie.app screenRecordingEnabled` | done; `defaults read` → `The domain/default pair of (com.caddie.app, screenRecordingEnabled) does not exist` |
| Caddie | quit through the menu before check 7; `pgrep` finds no Caddie process |
| Log stream | stopped (capture kept at the scratchpad `phase20-gate-log.txt`) |
| Kill-9 temp output | removed |
| Test data left on the real library | meeting `cab32fda-e3d` (check 4 partial: row + `.mov` + `.wav`). It was kept on purpose as the live D-06 evidence; the developer can delete it from the main window |
| DB backups | kept in the scratchpad until the developer confirms they can go |

### Gate verdict

Checks 1–7 pass with measured values. Check 1 was observed as end-state only (P-1). Check 7 passed on the LaunchServices re-run (D-5); the 14.2-floor re-run is still a milestone-close item. Check 8 is unit-verified only. No Phase 20 defect was found. Out-of-scope findings D-3 (stuck `recording` rows after a quit), D-4 (log redaction) and D-5 (gate script TCC attribution) are logged in `deferred-items.md`.

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 90s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
