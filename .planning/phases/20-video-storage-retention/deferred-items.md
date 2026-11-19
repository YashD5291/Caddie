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
