---
phase: 06-error-discipline
plan: 01
subsystem: error-handling
tags: [error-handling, logging, safety]
dependency_graph:
  requires: []
  provides: [explicit-error-logging, safe-directory-access]
  affects: [TranscriptionPipeline, AudioFileManager, Database, UI]
tech_stack:
  added: []
  patterns: [do-catch-with-logging, guard-let-with-fallback, DatabaseError-enum]
key_files:
  created: []
  modified:
    - Sources/Transcription/TranscriptionPipeline.swift
    - Sources/Storage/AudioFileManager.swift
    - Sources/Storage/Database.swift
    - Sources/UI/Settings/SettingsView.swift
    - Sources/UI/MainWindow/MeetingDetailView.swift
    - Sources/UI/MainWindow/ExportSheet.swift
    - Sources/UI/MenuBar/MenuBarView.swift
    - Sources/Detection/MeetingPatterns.swift
    - Sources/Utilities/Logger.swift
    - Sources/UI/MainWindow/MeetingListView.swift
decisions:
  - "File-level private loggers for SwiftUI view files (structs recreated on render)"
  - "print() fallback in CaddieLogger.showLogs to avoid circular logger dependency"
  - "fatalError with descriptive message for AudioFileManager.audioDirectory (guaranteed by macOS)"
  - "DatabaseError enum with LocalizedError conformance for guard-let throw pattern"
metrics:
  duration: 12min
  completed: "2026-03-22T00:02:00Z"
---

# Phase 06 Plan 01: Replace try? and Force Unwraps Summary

Zero silent error suppression and zero force unwraps on directory/dictionary access remaining in Sources/.

## What Changed

### Task 1: Replace all try? with do-catch + logging (ERR-01)
- Replaced 15 `try?` expressions across 8 files with explicit do-catch blocks
- Added `CaddieLogger.storage` to AudioFileManager for file operation errors
- Added file-level loggers: `settingsLogger`, `detailLogger`, `exportLogger`, `menuBarLogger`
- Used inline `Logger(subsystem:category:)` in MeetingPatterns init (struct context)
- Used `print()` fallback in CaddieLogger.showLogs (circular dependency avoidance)
- Fixed 2 additional `try?` from DATA-03/DATA-04 that were introduced by an earlier phase

### Task 2: Replace all force unwraps on directory/dictionary access (ERR-02)
- Database.swift: `guard let + throw DatabaseError.appSupportDirectoryUnavailable`
- AudioFileManager.swift: `guard let + fatalError` with descriptive message
- SettingsView.swift: `guard let + logger.error + return` (already fixed as part of Task 1)
- MeetingListView.swift: `(grouped[date] ?? [])` nil-coalescing fallback

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed DATA-03/DATA-04 reintroduced try? in TranscriptionPipeline**
- **Found during:** Task 2
- **Issue:** An earlier phase (pipeline-data-integrity) modified TranscriptionPipeline to move mono/WAV cleanup out of defer blocks, reintroducing `try?` on lines 75 and 121
- **Fix:** Applied same do-catch + logging pattern
- **Files modified:** Sources/Transcription/TranscriptionPipeline.swift
- **Commit:** e5baaf4

## Commits

| Task | Commit | Description |
|------|--------|-------------|
| 1 | 505d4b2 | Replace all try? with do-catch + logging |
| 2 | e5baaf4 | Replace all force unwraps on directory/dictionary access |

## Verification Results

- `grep -rn "try?" Sources/` -- 0 matches (was 15+)
- `grep -rn ".first!" Sources/` -- 0 matches (was 3)
- `grep -rn "grouped[.*]!" Sources/` -- 0 matches (was 1)
- Build: SUCCEEDED
- Tests: 128/128 passing

## Known Stubs

None.
