# Phase 20 — Deferred Items

Out-of-scope findings logged during execution. Not fixed in Phase 20.

## From 20-08 Task 1 (hardware gate prep, 2026-11-19)

### D-1: `make test` initializes the app against the user's real library

- **Observed:** the test bundle is hosted in `Caddie.app` (`TEST_HOST`). Under XCTest, the MenuBarExtra label's `.onAppear` opens the main window, `ContentView.task` calls `AppState.ensureInitialized()`, and that opens `~/Library/Application Support/Caddie/caddie.db` and runs `AudioFileManager.cleanupOrphanedVideos` on the real `audio/` directory.
- **Evidence:** the real DB already lists `v2_add_video_columns` before the gate's first app launch. The `caddie.db-wal` mtime is 18:35, which matches the 20-01 migration commits (18:35–18:36). The research inventory taken earlier the same day showed only `v1_create_meetings`. Since 20-02 (18:51), every `make test` run has also run the launch orphan-video sweep on the real media directory. All 3 real `.mov` files have rows, so all 3 survived.
- **Impact:** 20-08 check 1 ("migration observed live on first launch") cannot be observed live, because the migration already happened. A test run also performs a destructive sweep on real user data.
- **Suggested fix:** skip `AppState.initialize()` (or the DB and sweep steps) when running as a test host, for example by checking for `XCTestConfigurationFilePath` in the environment. Alternatively, run the tests without a host app.

### D-2: test runs leave row-less audio files in the real `audio/` directory

- **Observed:** the real `audio/` directory holds 1118 `.wav`, 643 `.m4a` and 3 `.mov` files. Out of 1806 distinct stems, 1791 have no `meetings` row (17 meetings exist). Several `.wav` files are written on every test run; a batch has 20:04 mtimes from today's runs. The oldest files date from March 2026, so this predates Phase 20.
- **Impact:** disk use and clutter. The orphan sweep handles `.mov` only, by design (D-10).
- **Suggested fix:** keep tests that write audio inside `FileManager.default.temporaryDirectory` (the D-15 discipline), then do a one-time cleanup of row-less `.wav`/`.m4a` files, with the user's consent.

## From 20-08 Task 2 (hardware gate, 2026-11-19)

### D-3: quitting mid-recording leaves the meeting stuck in `recording`, untranscribed

- **Observed:** in check 4, Caddie was quit from the menu bar while recording meeting `cab32fda-e3d`. After relaunch, the row still has `status = recording`, the `.wav` (1,046,994 B) is never compressed to `.m4a`, and no transcription is queued. Pre-state row `24204cea-ff5` (Jul 31) is in the same state. No startup pass recovers `recording` rows (`AppState` / `RecordingCoordinator` have none).
- **Impact:** the video side is correct: the partial `.mov` stays linked and playable (D-06). On the audio side, the captured meeting is never transcribed and shows as still recording. This conflicts with the core value ("no lost recordings").
- **Suggested fix:** at launch, before the coordinator starts, find `recording`/`processing` rows whose capture is not live, finalize their `.wav`, and enqueue transcription, or mark them `error` with a retry option. Needs its own phase or quick task.

### D-4: unified log redacts meeting ids
- **Observed:** `RecordingCoordinator` lines such as `Video anchor for <private>` and `Linked video <private> to meeting <private>` redact the meeting id, because os.Logger interpolations default to private. Only `ScreenRecorder` lines (which interpolate the filename as public) show the id.
- **Impact:** field debugging needs a sysdiagnose or a timestamp correlation. Low.
- **Suggested fix:** mark meeting ids (random, non-PII) `privacy: .public` in coordinator log lines.

### D-5: `scripts/kill9-recovery-gate.sh` fails Screen Recording TCC when run from a terminal without that permission
- **Observed:** gate check 7, run 1: `HARNESS_ERROR The user declined TCCs for application, window, display capture`. The script runs `"$BIN" --screen-record-harness` directly, so TCC attributes the capture to the responsible parent process (the terminal), not to `Caddie.app`. Re-running the same steps through LaunchServices (`open -n --stdout <log> --stderr <log> <app> --args --screen-record-harness <out>`) passed.
- **Impact:** the gate only works from a terminal that itself holds Screen Recording permission. This matters for the macOS 14.2 milestone-close re-run.
- **Suggested fix:** launch the harness with `open -n --stdout/--stderr … --args` and keep reading `HARNESS_READY pid=` from the log, or document the terminal permission requirement.
