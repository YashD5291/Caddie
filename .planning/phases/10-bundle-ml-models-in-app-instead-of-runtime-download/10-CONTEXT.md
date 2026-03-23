# Phase 10: Bundle ML Models in App Instead of Runtime Download - Context

**Gathered:** 2026-03-23
**Status:** Ready for planning

<domain>
## Phase Boundary

Replace runtime model downloads (ASR via HuggingFace, diarization via HuggingFace) with models bundled inside the app. After install, Caddie requires zero network access. Models are baked into the .app at build time via a build-phase download script.

</domain>

<decisions>
## Implementation Decisions

### Model bundling strategy
- **D-01:** Build-phase Run Script downloads models from known URLs during xcodebuild, placing them into the app's Resources directory
- **D-02:** Models are NOT stored in git — the script downloads them fresh each build (cached by CI where possible)
- **D-03:** Research must determine whether FluidAudio supports loading from a custom local path (Bundle.main) or whether models need to be copied to FluidAudio's expected cache directory on first launch

### ModelManager lifecycle change
- **D-04:** ModelManager changes from download-first to load-from-bundle — `downloadModelsIfNeeded()` becomes `loadModelsFromBundle()` or similar
- **D-05:** The 5-minute download timeout (Phase 7) becomes irrelevant for model loading but may be retained for backward compatibility or removed
- **D-06:** Model loading from disk should be fast (seconds, not minutes) — progress UI updates messaging accordingly

### Onboarding UX
- **D-07:** Onboarding KEEPS the model-readiness gate — main UI only shown when models are fully loaded and functional
- **D-08:** "Downloading AI Models (~1GB)" messaging replaced with "Loading AI models" or similar — no download size mentioned since models are local
- **D-09:** The retry/error path changes: download errors become load errors (file missing from bundle = build issue, not user issue)

### Build & distribution
- **D-10:** Accept ~1.2GB DMG size — GitHub Releases supports up to 2GB per asset
- **D-11:** CI release workflow (release.yml) needs the build-phase script to run before xcodebuild
- **D-12:** CI timeout may need increasing from 45 minutes if model download adds significant time

### Claude's Discretion
- Exact script implementation (shell script vs Swift script vs Makefile target)
- Model file naming and directory structure within Resources/
- Whether to use Xcode's "Copy Bundle Resources" phase or a custom Run Script phase
- How to handle model version pinning (hardcoded URLs vs version file)

</decisions>

<specifics>
## Specific Ideas

- FluidAudio currently uses `AsrModels.downloadAndLoad(version: .v3)` and `SortformerModels.loadFromHuggingFace(config: .default)` — research needs to find the local-load equivalents
- Model sizes from spec: ASR ~600MB–1.2GB (depending on quantization), Sortformer diarizer ~129MB
- The `nonisolated(unsafe)` pattern in AppState.initialize() for passing FluidAudio types to engines should remain unchanged

</specifics>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Model management
- `Sources/Models/ModelManager.swift` — Current download-based model loading, progress tracking, timeout logic
- `Sources/App/AppState.swift` lines 50-95 — Model initialization flow, engine creation, nonisolated(unsafe) pattern

### ML engines (consumers of models)
- `Sources/Transcription/ASREngine.swift` — Consumes AsrModels, initialize(models:) API
- `Sources/Transcription/DiarizationEngine.swift` — Consumes SortformerDiarizer, initialize(diarizer:) API
- `Sources/Transcription/ASREngineProtocol.swift` — Protocol abstraction (Phase 2)
- `Sources/Transcription/DiarizationEngineProtocol.swift` — Protocol abstraction (Phase 2)

### Onboarding
- `Sources/UI/Onboarding/OnboardingView.swift` — Model download section (lines 107-163), progress bar, retry UI

### Build configuration
- `project.yml` — XcodeGen config, Resources directory, build settings
- `.github/workflows/release.yml` — Release build pipeline, DMG creation
- `.github/workflows/ci.yml` — CI pipeline

### Prior design
- `docs/superpowers/specs/2026-03-20-phase1-ml-pipeline-design.md` §Model Management — Original model architecture, sizes, FluidAudio API usage

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `ModelManager` — Already has @Observable progress tracking, error state, modelsReady flag — just needs download logic swapped for load-from-bundle logic
- Protocol abstractions (`ASREngineProtocol`, `DiarizationEngineProtocol`) — Engine consumers don't care where models come from, only that they're initialized

### Established Patterns
- `nonisolated(unsafe)` for passing non-Sendable FluidAudio types across actor boundaries (AppState.swift)
- `withTimeout` race pattern (ModelManager.swift) — may be removable if loading is fast
- `@Observable` for progress tracking — reuse for loading state

### Integration Points
- `AppState.initialize()` calls `modelManager.downloadModelsIfNeeded()` — this call site changes
- `OnboardingView.modelDownloadSection` — messaging and error handling change
- `project.yml` resources section — new model files added here
- `release.yml` — build pipeline needs model download step before xcodebuild

</code_context>

<deferred>
## Deferred Ideas

- Model quantization/compression to reduce app size — evaluate after bundling works
- Delta model updates via Sparkle — separate feature, not hardening scope
- Multiple model versions (quality tiers) — future enhancement

</deferred>

---

*Phase: 10-bundle-ml-models-in-app-instead-of-runtime-download*
*Context gathered: 2026-03-23*
