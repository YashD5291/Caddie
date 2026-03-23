---
phase: 10-bundle-ml-models-in-app-instead-of-runtime-download
plan: 03
subsystem: ci
tags: [github-actions, ci-cache, ml-models, actions-cache]

# Dependency graph
requires:
  - 10-01
provides:
  - GitHub Actions cache for ML models in release workflow
  - GitHub Actions cache for ML models in CI workflow
  - Increased timeouts for model download on cache miss
affects: []

# Tech tracking
tech-stack:
  added: [actions/cache@v4]
  patterns: [stable version-based cache keys, shared cache namespace between workflows]

key-files:
  created: []
  modified:
    - .github/workflows/release.yml
    - .github/workflows/ci.yml

key-decisions:
  - "Stable cache key ml-models-parakeet-v3-sortformer-v2 -- only changes when model versions change"
  - "restore-keys prefix ml-models- allows partial cache hits across model version bumps"
  - "Shared cache namespace between release and CI workflows on same runner type (macos-15)"
  - "Release timeout 45->60 min, CI timeout 30->45 min for first-run model downloads"

patterns-established:
  - "ML model caching with version-pinned keys in GitHub Actions"

requirements-completed: [D-11, D-12]

# Metrics
duration: 3min
completed: 2026-03-23
---

# Phase 10 Plan 03: CI/CD Model Caching Summary

**GitHub Actions cache for ~711MB ML models with stable version-keyed caching and increased timeouts for both release and CI workflows**

## Performance

- **Duration:** 3 min
- **Started:** 2026-03-23T11:24:15Z
- **Completed:** 2026-03-23T11:27:00Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments
- Release workflow caches Resources/Models with actions/cache@v4 and increased timeout (45->60 min)
- CI workflow caches Resources/Models with same key (shared cache namespace on macos-15)
- CI workflow timeout increased from 30 to 45 minutes
- Cache steps positioned after xcodegen generate but before xcodebuild build in both workflows
- Both workflows validated as correct YAML

## Task Commits

Each task was committed atomically:

1. **Task 1: Add model caching and timeout increase to release.yml** - `76d2c4a` (chore)
2. **Task 2: Add model caching to ci.yml** - `34a2bb6` (chore)

## Files Modified
- `.github/workflows/release.yml` - ML model cache step, timeout 45->60 minutes
- `.github/workflows/ci.yml` - ML model cache step, timeout 30->45 minutes

## Decisions Made
- Stable cache key `ml-models-parakeet-v3-sortformer-v2` tied to model versions, not content hashes -- models are downloaded from HuggingFace with known versions, so the key only needs updating when model versions change
- `restore-keys: ml-models-` prefix enables partial cache restoration if one model set is updated
- Both workflows share the same cache key on the same runner type (macos-15), so a release build's cache benefits CI builds and vice versa
- Release timeout increased to 60 min (from 45) and CI to 45 min (from 30) to accommodate first-run model downloads (~711MB from HuggingFace)

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None

## User Setup Required

None - no external service configuration required.

## Self-Check: PASSED

All files exist, all commits verified.
