---
phase: 10-bundle-ml-models-in-app-instead-of-runtime-download
plan: 02
subsystem: models
tags: [fluidaudio, coreml, bundle-loading, onboarding, model-manager]

# Dependency graph
requires:
  - phase: 10-01
    provides: Build-phase download script placing models in Resources/Models/
provides:
  - Bundle-based ModelManager with loadModelsFromBundle() API
  - ModelLoadError enum with bundleNotFound, modelsNotFound, loadFailed cases
  - AsrModels.modelsExist() pre-check guard preventing DownloadUtils auto-recovery
  - Updated OnboardingView copy for loading-based UX
affects: [10-03]

# Tech tracking
tech-stack:
  added: []
  patterns: [bundle-based model loading via AsrModels.load(from:), pre-check guard pattern]

key-files:
  created: []
  modified:
    - Sources/Models/ModelManager.swift
    - Sources/App/AppState.swift
    - Sources/UI/Onboarding/OnboardingView.swift
    - Tests/ModelManagerTests.swift

key-decisions:
  - "AsrModels.load(from:) takes the repo folder directly -- internally derives parent via deletingLastPathComponent()"
  - "modelsExist() pre-check prevents DownloadUtils auto-recovery from triggering in read-only bundle context"
  - "5-minute download timeout removed entirely (D-05) -- local I/O does not need timeout"
  - "SortformerModels.loadFromHuggingFace(cacheDirectory: modelsDir) accepts parent Models/ directory"

patterns-established:
  - "Bundle-based model loading: guard modelsExist -> load(from:) for safe local loading"
  - "ModelLoadError with specific cases for bundle issues vs load failures"

requirements-completed: [D-03, D-04, D-05, D-06, D-07, D-08, D-09]

# Metrics
duration: 7min
completed: 2026-03-23
---

# Phase 10 Plan 02: ModelManager Transformation Summary

**Bundle-based ModelManager using AsrModels.load(from:) with modelsExist() pre-check guard, all download terminology replaced across ModelManager/AppState/OnboardingView**

## Performance

- **Duration:** 7 min
- **Started:** 2026-03-23T11:26:14Z
- **Completed:** 2026-03-23T11:33:33Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments
- ModelManager rewritten from download-based to bundle-based loading with AsrModels.load(from:) and SortformerModels.loadFromHuggingFace(cacheDirectory:)
- AsrModels.modelsExist() pre-check prevents FluidAudio's DownloadUtils auto-recovery from triggering in read-only bundle context
- All download-related terminology (downloadModelsIfNeeded, isDownloading, downloadProgress, downloadError, ModelDownloadError, withTimeout) fully removed from Sources/
- OnboardingView copy updated per UI-SPEC: "Loading AI Models", "Preparing speech recognition...", "Model Loading Failed", "Retry Loading"
- 4 new tests replacing 3 old download/timeout tests

## Task Commits

Each task was committed atomically:

1. **Task 1: Rewrite ModelManager for bundle-based loading and update tests** - `81995af` (feat)
2. **Task 2: Update AppState and OnboardingView for new ModelManager API** - `f5bc593` (feat)

## Files Created/Modified
- `Sources/Models/ModelManager.swift` - Replaced ModelDownloadError with ModelLoadError, downloadModelsIfNeeded() with loadModelsFromBundle()
- `Sources/App/AppState.swift` - Updated model init call and error handling to use load terminology
- `Sources/UI/Onboarding/OnboardingView.swift` - Updated all copy per UI-SPEC and property bindings to load* names
- `Tests/ModelManagerTests.swift` - 4 new tests for ModelLoadError descriptions and ModelManager initial state

## Decisions Made
- Verified AsrModels.load(from:) takes the repo folder directly (e.g., modelsDir/parakeet-tdt-0.6b-v3-coreml) by reading FluidAudio source -- it calls deletingLastPathComponent() internally to derive the parent directory
- SortformerModels.loadFromHuggingFace(cacheDirectory:) takes the parent Models/ directory and internally appends the sortformer folder name
- modelsExist(at:, version:) uses the same repoPath derivation as load(from:), so both accept the same directory parameter
- Removed withTimeout entirely (D-05) since local I/O loading does not need a timeout mechanism

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- ModelManager transformation complete, ready for Plan 03 (CI/release workflow updates)
- Build-phase script (Plan 01) downloads models, ModelManager (Plan 02) loads them from bundle
- The full pipeline: build downloads -> bundle includes -> ModelManager loads from Bundle.main.resourceURL/Models/

## Self-Check: PASSED

All files exist, all commits verified.

---
*Phase: 10-bundle-ml-models-in-app-instead-of-runtime-download*
*Completed: 2026-03-23*
