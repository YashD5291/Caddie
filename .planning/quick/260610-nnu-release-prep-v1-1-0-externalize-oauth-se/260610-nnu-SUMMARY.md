---
phase: quick
plan: 260610-nnu
subsystem: release-prep
tags: [security, oauth, models, release, git-hygiene]
requires: []
provides:
  - Gitignored Google OAuth secrets file + committed template
  - Sortformer no-runtime-download guard
  - Version 1.1.0 (build 2)
  - Clean, secret-free, atomically-committed branch ready for PR
affects:
  - Sources/Calendar/GoogleOAuthConfig.swift
  - Sources/Calendar/GoogleOAuthSecrets.swift (gitignored)
  - Sources/Models/ModelManager.swift
  - project.yml
tech-stack:
  added: []
  patterns:
    - "Secrets externalized to a gitignored Swift file picked up by xcodegen Sources/**"
    - "Side-effect-free static existence check gating model load to prevent runtime network fetch"
key-files:
  created:
    - Sources/Calendar/GoogleOAuthSecrets.swift (gitignored, never committed)
    - Sources/Calendar/GoogleOAuthSecrets.swift.template
    - Resources/CaddieDebug.entitlements
    - scripts/build-dmg.sh
    - scripts/release.sh
    - scripts/fix-broken-transcripts.py
    - docs/superpowers/plans/2026-04-04-google-calendar-integration.md
    - docs/superpowers/specs/2026-04-04-google-calendar-integration-design.md
  modified:
    - Sources/Calendar/GoogleOAuthConfig.swift
    - Sources/Models/ModelManager.swift
    - project.yml
    - .gitignore
    - README.md
    - Sources/Calendar/GoogleAuthManager.swift
    - Sources/Calendar/GoogleAuthError.swift
    - Sources/Calendar/GoogleCalendarEvent.swift
    - Sources/Transcription/ASREngine.swift
    - Sources/Transcription/TranscriptionPipeline.swift
    - Sources/Recording/AudioDeviceManager.swift
    - Sources/UI/MainWindow/{ContentView,MeetingDetailView,MeetingListView,TodayScheduleView}.swift
    - Sources/UI/Onboarding/OnboardingView.swift
    - Sources/UI/Settings/SettingsView.swift
    - Tests/{ModelManagerTests,GoogleCalendarEventTests,ASREngineTests}.swift
    - Makefile
    - scripts/download-models.sh
decisions:
  - "Externalize BOTH clientID and clientSecret into the gitignored secrets file; derive callbackScheme from clientID for a single source of truth"
  - "Gate sortformer load with a side-effect-free static helper so the guard is unit-testable without a fake bundle harness"
  - "project.yml version bump and inseparable build-config restructuring committed together (single diff region); accurate message documents both"
metrics:
  duration_minutes: 11
  tasks: 3
  files_touched: 25
  completed: "2026-06-10T11:47:19Z"
---

# Phase quick Plan 260610-nnu: Release Prep v1.1.0 — Externalize OAuth Secret Summary

Externalized the Google OAuth client secret into a gitignored file, hardened the no-runtime-download guarantee for the sortformer diarization model, bumped to 1.1.0/2, and committed all branch work in eight clean atomic chunks — yielding a secret-free, tests-green branch ready to PR to the public main.

## What Was Done

### Task 1 — Externalize OAuth secret + harden .gitignore (commit 489ba44)
- Created `Sources/Calendar/GoogleOAuthSecrets.swift` (gitignored) holding the real `clientID`/`clientSecret`, plus a committed `GoogleOAuthSecrets.swift.template` with placeholders and setup instructions.
- Rewrote `GoogleOAuthConfig.swift` to reference `GoogleOAuthSecrets.*` and derive `callbackScheme` from the clientID (strip `.apps.googleusercontent.com`, prefix `com.googleusercontent.apps.`) — zero literal secret/clientID strings remain.
- Added `# Secrets` (`Sources/Calendar/GoogleOAuthSecrets.swift`) and `# Python cache` (`scripts/__pycache__/`) entries to `.gitignore`.
- Updated the README "Google Calendar Setup" section to the template-copy flow.
- Security gate verified before commit: `git diff --cached | grep -c "<secret-prefix>"` == 0, both paths `git check-ignore`d, secrets file untracked. `make test` green.

### Task 2 — Sortformer no-runtime-download guard + version bump (commit c9bc24e, TDD)
- RED: added two `ModelManagerTests` cases asserting `ModelManager.sortformerModelsExist(in:)` against a temp dir with/without `sortformer/SortformerV2.mlmodelc`; confirmed compile failure (helper absent).
- GREEN: added the `nonisolated static func sortformerModelsExist(in:)` helper and a guard in `loadModelsFromBundle()` that throws `ModelLoadError.modelsNotFound` instead of reaching `SortformerModels.loadFromHuggingFace(...)` when the bundled model is missing. 246 tests pass.
- Bumped `MARKETING_VERSION` 1.0.0 → 1.1.0 and `CURRENT_PROJECT_VERSION` 1 → 2 in `project.yml`.

### Task 3 — Commit remaining branch work in atomic chunks (commits 6eac90e, 677638f, 96cfe9e, 4ac3119, 29e8aee, b2cebbb)
- `feat(calendar)`: client_secret on token requests, richer auth error details, optional event summary/status + helpers, tests.
- `fix(transcription)`: ASR raw-token detokenization (fixes split sub-words), mono-cleanup no-op guard, ASREngineTests.
- `feat(ui)`: calendar schedule, meeting list/detail, settings, onboarding, and device-picker label support.
- `build`: debug entitlements, CoreML analytics download fix, DMG/notarize via scripts, Makefile.
- `chore(scripts)`: release/DMG pipeline + transcript repair utility.
- `docs`: Google Calendar integration spec + plan.
- Final full `make test` on the committed tree: **246 tests, 0 failures, TEST SUCCEEDED**.

## Deviations from Plan

**1. [Rule 3 - Blocking] project.yml version bump committed with build-config restructuring**
- **Found during:** Task 2 / Task 3 boundary.
- **Issue:** The working-tree `project.yml` had the version bump and a build-config restructuring (Debug/Release signing configs, CaddieDebug entitlements reference, hardened runtime) within the same contiguous diff region. The plan suggested keeping the version bump in Task 2 and any remaining hunks in Task 3's `build:` commit, but non-interactive staging (`git add -p`/`git apply --cached`) could not cleanly split the entangled, adjacent lines.
- **Resolution:** Committed the whole `project.yml` in Task 2; the commit body explicitly documents that it also carries the build-config restructuring. No information lost; messages remain accurate. Task 3's `build:` commit therefore had no `project.yml` hunks (anticipated by the plan: "any remaining project.yml hunks ... likely none").
- **Files modified:** project.yml
- **Commit:** c9bc24e

Note: Several files listed in the initial git-status snapshot (e.g. GoogleCalendarService.swift, AppState.swift, RecordingCoordinator.swift, NotificationManager.swift and their tests) were already committed in earlier branch commits (cfc4cad, 42eec43, etc.) and were clean by execution time — no action needed for them.

## Known Stubs

None. The committed `GoogleOAuthConfig.swift` references real values only via the gitignored secrets file; the template intentionally contains placeholders (documented setup flow, not a stub blocking functionality).

## Verification

- `git log -p | grep -c "<secret-prefix>"` → 0 (no secret anywhere in git history).
- `git check-ignore Sources/Calendar/GoogleOAuthSecrets.swift scripts/__pycache__/` → both print (ignored).
- `grep 'MARKETING_VERSION: "1.1.0"' project.yml` → matches; build 2.
- ModelManager throws `modelsNotFound` when bundled sortformer absent (no HuggingFace path reachable).
- `git ls-files | grep __pycache__` → empty (none tracked).
- `git status --short` → only this plan's `.planning/` artifact dir.
- `make test` → 246 tests, 0 failures, ** TEST SUCCEEDED **.

## Commits

- 489ba44 chore(security): externalize Google OAuth credentials to gitignored file
- c9bc24e feat(models): guard against runtime sortformer download; bump to 1.1.0
- 6eac90e feat(calendar): send client_secret on token requests; richer auth errors and event model
- 677638f fix(transcription): detokenize ASR via raw tokens; skip mono cleanup when mixdown is a no-op
- 96cfe9e feat(ui): calendar schedule, meeting list/detail, settings, and device-picker refinements
- 4ac3119 build: add debug entitlements, fetch CoreML analytics, route DMG/notarize via scripts
- 29e8aee chore(scripts): add release/DMG pipeline and transcript repair utility
- b2cebbb docs: add Google Calendar integration design spec and implementation plan

## Self-Check: PASSED

All created files exist on disk (GoogleOAuthSecrets.swift, .template, CaddieDebug.entitlements, scripts/build-dmg.sh) and all 8 commit hashes are present in git history.
