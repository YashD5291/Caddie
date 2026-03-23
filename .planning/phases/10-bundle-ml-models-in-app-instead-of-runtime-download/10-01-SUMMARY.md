---
phase: 10-bundle-ml-models-in-app-instead-of-runtime-download
plan: 01
subsystem: infra
tags: [huggingface, coreml, xcodegen, build-phase, ml-models]

# Dependency graph
requires: []
provides:
  - Idempotent model download script for all FluidAudio ML models
  - preBuildScript integration in project.yml for automatic download during xcodebuild
  - .gitignore entry preventing 711MB of models from entering git
affects: [10-02, 10-03]

# Tech tracking
tech-stack:
  added: [curl-based HuggingFace download]
  patterns: [build-phase model download, size-validated idempotent downloads]

key-files:
  created:
    - scripts/download-models.sh
  modified:
    - project.yml
    - .gitignore

key-decisions:
  - "SRCROOT fallback via dirname for standalone script execution outside Xcode"
  - "Size validation only for large weight files, existence-only check for small metadata"
  - "basedOnDependencyAnalysis: false to run idempotent script every build"
  - "Exclude .mlpackage from resources to prevent Xcode recompilation of already-compiled .mlmodelc"

patterns-established:
  - "Build-phase scripts in scripts/ directory with SRCROOT fallback"
  - "Size-validated idempotent file downloads from HuggingFace"

requirements-completed: [D-01, D-02, D-10]

# Metrics
duration: 4min
completed: 2026-03-23
---

# Phase 10 Plan 01: Build Infrastructure Summary

**Idempotent HuggingFace download script with size validation for all FluidAudio ML models (~711MB), integrated as XcodeGen preBuildScript**

## Performance

- **Duration:** 4 min
- **Started:** 2026-03-23T11:14:56Z
- **Completed:** 2026-03-23T11:19:12Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments
- Download script covering all 25+ ASR and Sortformer model files with size validation for weight files
- preBuildScript in project.yml triggers model download automatically during xcodebuild
- Resources/Models/ gitignored to prevent 711MB of binary files in repository

## Task Commits

Each task was committed atomically:

1. **Task 1: Create model download script and add .gitignore entry** - `c2b3c2c` (feat)
2. **Task 2: Add preBuildScript to project.yml and verify xcodegen generates** - `606da0c` (feat)

## Files Created/Modified
- `scripts/download-models.sh` - Idempotent model download from HuggingFace with size validation
- `project.yml` - preBuildScript for model download, .mlpackage exclude in resources
- `.gitignore` - Resources/Models/ exclusion

## Decisions Made
- SRCROOT fallback (`${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}`) enables running the script both from Xcode builds and standalone CLI
- Size validation applied only to large weight files (6 files with known byte sizes); small metadata files use existence-only check for simplicity
- `basedOnDependencyAnalysis: false` ensures the idempotent script runs on every build rather than being skipped by Xcode's dependency analysis
- Added `Models/**/*.mlpackage` to resources excludes to prevent Xcode from attempting to compile already-compiled .mlmodelc bundles

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- Download script and build configuration ready for Plan 02 (ModelManager transformation to load-from-bundle)
- Models will be available in app bundle at `Bundle.main.resourceURL/Models/` after build runs the download script
- Plan 03 (CI/release workflow updates) can proceed in parallel since it uses the same script

## Self-Check: PASSED

All files exist, all commits verified.

---
*Phase: 10-bundle-ml-models-in-app-instead-of-runtime-download*
*Completed: 2026-03-23*
