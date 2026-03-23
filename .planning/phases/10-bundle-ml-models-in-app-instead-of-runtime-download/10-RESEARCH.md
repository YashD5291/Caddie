# Phase 10: Bundle ML Models in App Instead of Runtime Download - Research

**Researched:** 2026-03-23
**Domain:** CoreML model bundling, FluidAudio SDK local loading, XcodeGen build phases, macOS app distribution
**Confidence:** HIGH

## Summary

FluidAudio v0.12.4 has first-class support for loading models from local directories without any network access. Both `AsrModels.load(from:)` and `SortformerModels.loadFromHuggingFace(cacheDirectory:)` accept custom directory paths, and `SortformerDiarizer.initialize(mainModelPath:)` takes a direct URL to a compiled model. The key insight is that FluidAudio's `DownloadUtils.loadModels()` checks if files exist locally before attempting any download -- so placing model files in the right directory structure makes the existing `downloadAndLoad()` path work without network access. However, the cleanest approach is to use the explicit `load(from:)` methods.

The ASR models total ~482MB (Encoder 424.5MB, Decoder 22.5MB, JointDecision 12MB, Preprocessor 0.5MB, vocab 148KB). The Sortformer SortformerV2.mlmodelc model totals ~229MB (model0 weights 8.5MB, model1 weights 220MB, plus metadata). Combined total: ~711MB of model files to bundle. With the app binary, this puts the DMG at roughly 800MB-1GB, well within the 2GB GitHub Releases limit (D-10).

**Primary recommendation:** Use a preBuildScript in `project.yml` to download models from HuggingFace into a `Resources/Models/` directory during build. Load via `AsrModels.load(from:)` and `SortformerModels.loadFromHuggingFace(cacheDirectory:)` pointing at `Bundle.main.resourceURL`. ModelManager becomes a synchronous local-load wrapper with no timeout logic needed.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** Build-phase Run Script downloads models from known URLs during xcodebuild, placing them into the app's Resources directory
- **D-02:** Models are NOT stored in git -- the script downloads them fresh each build (cached by CI where possible)
- **D-03:** Research must determine whether FluidAudio supports loading from a custom local path (Bundle.main) or whether models need to be copied to FluidAudio's expected cache directory on first launch -- **ANSWERED: FluidAudio fully supports loading from custom local paths via `AsrModels.load(from:)` and `SortformerModels.loadFromHuggingFace(cacheDirectory:)`**
- **D-04:** ModelManager changes from download-first to load-from-bundle -- `downloadModelsIfNeeded()` becomes `loadModelsFromBundle()` or similar
- **D-05:** The 5-minute download timeout (Phase 7) becomes irrelevant for model loading but may be retained for backward compatibility or removed
- **D-06:** Model loading from disk should be fast (seconds, not minutes) -- progress UI updates messaging accordingly
- **D-07:** Onboarding KEEPS the model-readiness gate -- main UI only shown when models are fully loaded and functional
- **D-08:** "Downloading AI Models (~1GB)" messaging replaced with "Loading AI models" or similar -- no download size mentioned since models are local
- **D-09:** The retry/error path changes: download errors become load errors (file missing from bundle = build issue, not user issue)
- **D-10:** Accept ~1.2GB DMG size -- GitHub Releases supports up to 2GB per asset
- **D-11:** CI release workflow (release.yml) needs the build-phase script to run before xcodebuild
- **D-12:** CI timeout may need increasing from 45 minutes if model download adds significant time

### Claude's Discretion
- Exact script implementation (shell script vs Swift script vs Makefile target)
- Model file naming and directory structure within Resources/
- Whether to use Xcode's "Copy Bundle Resources" phase or a custom Run Script phase
- How to handle model version pinning (hardcoded URLs vs version file)

### Deferred Ideas (OUT OF SCOPE)
- Model quantization/compression to reduce app size -- evaluate after bundling works
- Delta model updates via Sparkle -- separate feature, not hardening scope
- Multiple model versions (quality tiers) -- future enhancement
</user_constraints>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| FluidAudio | 0.12.4 | ASR + Diarization ML models | Already in use; has load(from:) API |
| XcodeGen | latest | Build configuration via project.yml | Already in use; supports preBuildScripts |

### Supporting
| Tool | Purpose | When to Use |
|------|---------|-------------|
| `curl` | Download model files from HuggingFace | In preBuildScript during xcodebuild |
| `actions/cache` | Cache downloaded models in CI | In release.yml and ci.yml |

## Architecture Patterns

### Model File Layout in Bundle

FluidAudio's `AsrModels.load(from:)` expects a directory containing the repo folder structure. The `DownloadUtils.loadModels()` method constructs the path as `directory/repo.folderName/modelFile`. For ASR models with `Repo.parakeet`, the `folderName` is `"parakeet-tdt-0.6b-v3-coreml"`. For Sortformer, it is `"sortformer"`.

```
Resources/
  Models/
    parakeet-tdt-0.6b-v3-coreml/
      Preprocessor.mlmodelc/
        coremldata.bin
        metadata.json
        model.mil
        weights/weight.bin
      Encoder.mlmodelc/
        coremldata.bin
        metadata.json
        model.mil
        weights/weight.bin
      Decoder.mlmodelc/
        coremldata.bin
        metadata.json
        model.mil
        weights/weight.bin
      JointDecision.mlmodelc/
        coremldata.bin
        metadata.json
        model.mil
        weights/weight.bin
      parakeet_vocab.json
    sortformer/
      SortformerV2.mlmodelc/
        coremldata.bin
        metadata.json
        model0/
          coremldata.bin
          model.mil
          weights/0-weight.bin
        model1/
          coremldata.bin
          model.mil
          weights/1-weight.bin
```

### Pattern 1: AsrModels Local Loading

FluidAudio's `AsrModels.load(from:directory:version:)` accepts any URL as the repo directory. The `directory` parameter is the **parent** of the repo folder, because internally it appends `repo.folderName`.

**How it works (from source code analysis):**
```swift
// AsrModels.load(from:) calls DownloadUtils.loadModels() with parentDirectory
let parentDirectory = directory.deletingLastPathComponent()
// DownloadUtils.loadModels() checks:
let repoPath = directory.appendingPathComponent(repo.folderName)
// If all files exist at repoPath, NO download occurs
```

**Caddie usage:**
```swift
// Bundle.main.resourceURL points to Caddie.app/Contents/Resources/
let modelsDir = Bundle.main.resourceURL!.appendingPathComponent("Models")
// This creates: .../Resources/Models/parakeet-tdt-0.6b-v3-coreml/Encoder.mlmodelc etc.
let models = try await AsrModels.load(
    from: modelsDir.appendingPathComponent("parakeet-tdt-0.6b-v3-coreml"),
    version: .v3
)
```

**Confidence:** HIGH -- verified by reading `AsrModels.swift` lines 109-173 and `DownloadUtils.swift` lines 164-250 in FluidAudio source.

### Pattern 2: SortformerModels Local Loading

`SortformerModels.loadFromHuggingFace(config:cacheDirectory:)` accepts a `cacheDirectory` parameter. When provided, it uses that as the base directory instead of `~/Library/Application Support/FluidAudio/Models/`. Internally it calls `DownloadUtils.loadModels(.sortformer, ..., directory: directory)` which constructs path as `directory/sortformer/SortformerV2.mlmodelc`.

**Caddie usage:**
```swift
let modelsDir = Bundle.main.resourceURL!.appendingPathComponent("Models")
let sortformerModels = try await SortformerModels.loadFromHuggingFace(
    config: .default,
    cacheDirectory: modelsDir
)
```

**Confidence:** HIGH -- verified by reading `SortformerModelInference.swift` lines 109-159 in FluidAudio source.

### Pattern 3: Build-Phase Download Script

A shell script in `scripts/download-models.sh` runs as a preBuildScript in project.yml. It downloads model files from HuggingFace only if not already present (idempotent).

```yaml
# project.yml
targets:
  Caddie:
    preBuildScripts:
      - name: Download ML Models
        script: "${SRCROOT}/scripts/download-models.sh"
        basedOnDependencyAnalysis: false
```

The script structure:
```bash
#!/bin/bash
set -euo pipefail

MODELS_DIR="${SRCROOT}/Resources/Models"
PARAKEET_DIR="${MODELS_DIR}/parakeet-tdt-0.6b-v3-coreml"
SORTFORMER_DIR="${MODELS_DIR}/sortformer"

HF_BASE="https://huggingface.co"
PARAKEET_REPO="FluidInference/parakeet-tdt-0.6b-v3-coreml"
SORTFORMER_REPO="FluidInference/diar-streaming-sortformer-coreml"

# Download a file from HuggingFace if not already present
download_hf_file() {
    local repo="$1" file_path="$2" dest="$3"
    if [ -f "$dest" ]; then return 0; fi
    mkdir -p "$(dirname "$dest")"
    curl -sL "${HF_BASE}/${repo}/resolve/main/${file_path}" -o "$dest"
}

# ASR models
download_hf_file "$PARAKEET_REPO" "Encoder.mlmodelc/weights/weight.bin" \
    "$PARAKEET_DIR/Encoder.mlmodelc/weights/weight.bin"
# ... repeat for all model files
```

### Pattern 4: ModelManager Transformation

```swift
// Before (download-based):
func downloadModelsIfNeeded() async { ... }

// After (bundle-based):
func loadModelsFromBundle() async {
    guard !modelsReady else { return }
    isLoading = true
    loadProgress = 0
    loadError = nil

    do {
        guard let modelsDir = Bundle.main.resourceURL?
            .appendingPathComponent("Models") else {
            throw ModelLoadError.bundleNotFound
        }

        // Step 1: Load ASR models from bundle
        let asrDir = modelsDir.appendingPathComponent("parakeet-tdt-0.6b-v3-coreml")
        let models = try await AsrModels.load(from: asrDir, version: .v3)
        asrModels = models
        loadProgress = 0.6

        // Step 2: Load Sortformer models from bundle
        let sortformerModels = try await SortformerModels.loadFromHuggingFace(
            config: .default,
            cacheDirectory: modelsDir
        )
        let sortformer = SortformerDiarizer(config: .default)
        sortformer.initialize(models: sortformerModels)
        diarizer = sortformer
        loadProgress = 1.0

        modelsReady = true
    } catch {
        loadError = error.localizedDescription
    }
    isLoading = false
}
```

### Anti-Patterns to Avoid
- **Copying models to FluidAudio's default cache at first launch:** Wastes disk space and adds startup latency. FluidAudio's load APIs accept custom paths directly.
- **Storing models in git with LFS:** Bloats the repository. Build-phase download is the correct pattern.
- **Relying on DownloadUtils auto-recovery (cache delete + re-download):** With bundled models, the auto-recovery path in `DownloadUtils.loadModels()` would try to re-download from HuggingFace. The `load(from:)` path avoids this by not going through the download layer.
- **Hardcoding absolute paths in the download script:** Use `${SRCROOT}` and relative paths for portability across developer machines and CI.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| CoreML model loading | Custom MLModel loader | `AsrModels.load(from:)` | FluidAudio handles compilation, compute unit config, vocabulary loading |
| Sortformer initialization | Direct MLModel init | `SortformerModels.loadFromHuggingFace(cacheDirectory:)` | Handles model0/model1 sub-models, ANE memory optimizer setup |
| HuggingFace file download | Custom HTTP client | `curl -sL` in shell script | Simple, reliable, handles redirects |
| CI caching | Manual cache management | `actions/cache@v4` | Handles key-based caching with 10GB free tier |

## Model File Inventory

### ASR Models (Repo: parakeet-tdt-0.6b-v3-coreml)

| File | Size | Required |
|------|------|----------|
| Encoder.mlmodelc/weights/weight.bin | 424.5 MB | Yes |
| Decoder.mlmodelc/weights/weight.bin | 22.5 MB | Yes |
| JointDecision.mlmodelc/weights/weight.bin | 12.1 MB | Yes |
| Preprocessor.mlmodelc/weights/weight.bin | 480 KB | Yes |
| Encoder.mlmodelc/coremldata.bin | 485 B | Yes |
| Encoder.mlmodelc/metadata.json | 2.9 KB | Yes |
| Encoder.mlmodelc/model.mil | 960 KB | Yes |
| Decoder.mlmodelc/coremldata.bin | 554 B | Yes |
| Decoder.mlmodelc/metadata.json | 3.4 KB | Yes |
| Decoder.mlmodelc/model.mil | 13.1 KB | Yes |
| JointDecision.mlmodelc/coremldata.bin | ~500 B | Yes |
| JointDecision.mlmodelc/metadata.json | ~3 KB | Yes |
| JointDecision.mlmodelc/model.mil | ~10 KB | Yes |
| Preprocessor.mlmodelc/coremldata.bin | ~500 B | Yes |
| Preprocessor.mlmodelc/metadata.json | ~3 KB | Yes |
| Preprocessor.mlmodelc/model.mil | ~5 KB | Yes |
| parakeet_vocab.json | 148 KB | Yes |
| **ASR Subtotal** | **~482 MB** | |

### Diarization Models (Repo: diar-streaming-sortformer-coreml)

| File | Size | Required |
|------|------|----------|
| SortformerV2.mlmodelc/model1/weights/1-weight.bin | 220 MB | Yes |
| SortformerV2.mlmodelc/model0/weights/0-weight.bin | 8.5 MB | Yes |
| SortformerV2.mlmodelc/model1/model.mil | 1.1 MB | Yes |
| SortformerV2.mlmodelc/model0/model.mil | 31.8 KB | Yes |
| SortformerV2.mlmodelc/coremldata.bin | 1.1 KB | Yes |
| SortformerV2.mlmodelc/metadata.json | 5.2 KB | Yes |
| SortformerV2.mlmodelc/model0/coremldata.bin | 633 B | Yes |
| SortformerV2.mlmodelc/model1/coremldata.bin | 594 B | Yes |
| **Sortformer Subtotal** | **~229 MB** | |

### Combined Total: ~711 MB

**Confidence:** HIGH -- all sizes verified from HuggingFace API responses. Weight files are the bulk; metadata files are negligible.

## Common Pitfalls

### Pitfall 1: DownloadUtils auto-recovery deletes bundled models
**What goes wrong:** If CoreML compilation fails on first load, `DownloadUtils.loadModels()` has a retry mechanism that deletes the cache directory and re-downloads. Inside an app bundle, this would try to delete read-only files and then attempt a network download.
**Why it happens:** The `loadModels()` wrapper in `DownloadUtils.swift` (lines 103-128) catches errors from `loadModelsOnce()`, deletes the repo folder, then retries.
**How to avoid:** Use `AsrModels.load(from:)` which calls `DownloadUtils.loadModels()` but the bundle directory is read-only, so the delete would fail silently (try?). However, the re-download would also fail without network. Best approach: validate models exist before calling load. Use `AsrModels.modelsExist(at:)` as a pre-check to fail fast with a clear error.
**Warning signs:** "First load failed" in logs followed by "Deleting cache and re-downloading".

### Pitfall 2: Xcode compiles .mlmodelc bundles
**What goes wrong:** Xcode has built-in CoreML model compilation that automatically compiles `.mlpackage` files into `.mlmodelc` bundles. If Xcode sees `.mlmodelc` directories in Resources, it may try to process them.
**Why it happens:** Xcode's default build rules treat CoreML models as special resources.
**How to avoid:** The `.mlmodelc` bundles are already compiled -- they should be treated as plain folders/resources, not as CoreML sources. Place them in a subdirectory (Resources/Models/) and ensure they are included via "Copy Bundle Resources" without CoreML processing. In project.yml, they are already under the `resources` section which copies them as-is.
**Warning signs:** Build errors about CoreML model compilation, or duplicate model processing.

### Pitfall 3: Git LFS files downloaded as pointer files
**What goes wrong:** The download script uses HuggingFace's `/resolve/main/` URL endpoint to get actual file contents, but if the URL construction is wrong, you get an HTML page or a Git LFS pointer (128-byte text file) instead of the actual binary.
**Why it happens:** HuggingFace stores large files via Git LFS. The `/resolve/main/` endpoint handles the redirect to the actual content, but the URL must be exact (case-sensitive paths, proper encoding).
**How to avoid:** Always use `https://huggingface.co/{repo}/resolve/main/{path}` for direct file downloads. Validate downloaded file sizes match expected values. Add a size check in the script.
**Warning signs:** Model files that are 128 bytes (LFS pointer), or load failures with "Missing coremldata.bin".

### Pitfall 4: CI timeout exceeded
**What goes wrong:** Downloading ~711MB of model files during CI adds significant time. With the current 45-minute timeout on release.yml, the build could time out.
**Why it happens:** First build without cache downloads all models. HuggingFace may rate-limit or be slow.
**How to avoid:** Cache model files using `actions/cache@v4` with a key based on model versions. Set CI timeout to 60 minutes. The model download is a one-time cost per cache key.
**Warning signs:** CI job timing out at the "Build Release" step.

### Pitfall 5: Resources/Models added to git
**What goes wrong:** The downloaded model files (~711MB) accidentally get committed to git.
**Why it happens:** `Resources/Models/` is not in `.gitignore` and a developer runs the build script locally.
**How to avoid:** Add `Resources/Models/` to `.gitignore` immediately. This is critical since models are ~711MB.
**Warning signs:** Git operations becoming slow, repository size exploding.

### Pitfall 6: Analytics subdirectories missing
**What goes wrong:** The `.mlmodelc` bundles contain `analytics/` subdirectories that may be empty but required by CoreML.
**Why it happens:** The download script only downloads files, not empty directories.
**How to avoid:** After downloading files, create the `analytics/` directories explicitly with `mkdir -p`. CoreML may not strictly require them, but their presence in the original bundle suggests they should exist.
**Warning signs:** Warnings about missing analytics directories in CoreML logs.

## Code Examples

### Download Script (scripts/download-models.sh)

```bash
#!/bin/bash
set -euo pipefail

# Model download script for Caddie
# Downloads FluidAudio ML models from HuggingFace into Resources/Models/
# Idempotent: skips files that already exist with correct size

MODELS_DIR="${SRCROOT}/Resources/Models"
HF_BASE="https://huggingface.co"

# ASR: Parakeet TDT v3
PARAKEET_REPO="FluidInference/parakeet-tdt-0.6b-v3-coreml"
PARAKEET_DIR="${MODELS_DIR}/parakeet-tdt-0.6b-v3-coreml"

# Diarization: Sortformer V2
SORTFORMER_REPO="FluidInference/diar-streaming-sortformer-coreml"
SORTFORMER_DIR="${MODELS_DIR}/sortformer"

download_file() {
    local repo="$1" path="$2" dest="$3" expected_size="${4:-0}"

    if [ -f "$dest" ]; then
        if [ "$expected_size" -gt 0 ]; then
            local actual_size
            actual_size=$(stat -f%z "$dest" 2>/dev/null || echo 0)
            if [ "$actual_size" -eq "$expected_size" ]; then
                return 0
            fi
            echo "Size mismatch for $dest (expected $expected_size, got $actual_size), re-downloading"
        else
            return 0
        fi
    fi

    mkdir -p "$(dirname "$dest")"
    echo "Downloading: $path"
    curl -sL "${HF_BASE}/${repo}/resolve/main/${path}" -o "$dest"
}

echo "=== Downloading ASR Models ==="
# Weight files (large)
download_file "$PARAKEET_REPO" "Encoder.mlmodelc/weights/weight.bin" \
    "$PARAKEET_DIR/Encoder.mlmodelc/weights/weight.bin" 445187200
download_file "$PARAKEET_REPO" "Decoder.mlmodelc/weights/weight.bin" \
    "$PARAKEET_DIR/Decoder.mlmodelc/weights/weight.bin" 23604992
download_file "$PARAKEET_REPO" "JointDecision.mlmodelc/weights/weight.bin" \
    "$PARAKEET_DIR/JointDecision.mlmodelc/weights/weight.bin" 12642764
download_file "$PARAKEET_REPO" "Preprocessor.mlmodelc/weights/weight.bin" \
    "$PARAKEET_DIR/Preprocessor.mlmodelc/weights/weight.bin" 491072

# Metadata and MIL files (small)
for model in Encoder Decoder JointDecision Preprocessor; do
    download_file "$PARAKEET_REPO" "${model}.mlmodelc/coremldata.bin" \
        "$PARAKEET_DIR/${model}.mlmodelc/coremldata.bin"
    download_file "$PARAKEET_REPO" "${model}.mlmodelc/metadata.json" \
        "$PARAKEET_DIR/${model}.mlmodelc/metadata.json"
    download_file "$PARAKEET_REPO" "${model}.mlmodelc/model.mil" \
        "$PARAKEET_DIR/${model}.mlmodelc/model.mil"
    # Create analytics directory (may be empty but expected)
    mkdir -p "$PARAKEET_DIR/${model}.mlmodelc/analytics"
done

# Vocabulary
download_file "$PARAKEET_REPO" "parakeet_vocab.json" \
    "$PARAKEET_DIR/parakeet_vocab.json" 151122

echo "=== Downloading Diarization Models ==="
# Sortformer V2 weights
download_file "$SORTFORMER_REPO" "SortformerV2.mlmodelc/model0/weights/0-weight.bin" \
    "$SORTFORMER_DIR/SortformerV2.mlmodelc/model0/weights/0-weight.bin" 8948544
download_file "$SORTFORMER_REPO" "SortformerV2.mlmodelc/model1/weights/1-weight.bin" \
    "$SORTFORMER_DIR/SortformerV2.mlmodelc/model1/weights/1-weight.bin" 230428224

# Sortformer V2 metadata
download_file "$SORTFORMER_REPO" "SortformerV2.mlmodelc/coremldata.bin" \
    "$SORTFORMER_DIR/SortformerV2.mlmodelc/coremldata.bin"
download_file "$SORTFORMER_REPO" "SortformerV2.mlmodelc/metadata.json" \
    "$SORTFORMER_DIR/SortformerV2.mlmodelc/metadata.json"
download_file "$SORTFORMER_REPO" "SortformerV2.mlmodelc/model0/coremldata.bin" \
    "$SORTFORMER_DIR/SortformerV2.mlmodelc/model0/coremldata.bin"
download_file "$SORTFORMER_REPO" "SortformerV2.mlmodelc/model0/model.mil" \
    "$SORTFORMER_DIR/SortformerV2.mlmodelc/model0/model.mil"
download_file "$SORTFORMER_REPO" "SortformerV2.mlmodelc/model1/coremldata.bin" \
    "$SORTFORMER_DIR/SortformerV2.mlmodelc/model1/coremldata.bin"
download_file "$SORTFORMER_REPO" "SortformerV2.mlmodelc/model1/model.mil" \
    "$SORTFORMER_DIR/SortformerV2.mlmodelc/model1/model.mil"

# Create analytics directories
mkdir -p "$SORTFORMER_DIR/SortformerV2.mlmodelc/analytics"
mkdir -p "$SORTFORMER_DIR/SortformerV2.mlmodelc/model0/analytics"
mkdir -p "$SORTFORMER_DIR/SortformerV2.mlmodelc/model1/analytics"

echo "=== Models Ready ==="
```

### project.yml Changes

```yaml
targets:
  Caddie:
    preBuildScripts:
      - name: Download ML Models
        script: "${SRCROOT}/scripts/download-models.sh"
        basedOnDependencyAnalysis: false
    resources:
      - path: Resources
        excludes:
          - "Assets.xcassets"
          - "Models/**/*.mlpackage"  # Exclude any mlpackage if present
```

### ModelManager.loadModelsFromBundle()

```swift
enum ModelLoadError: Error, LocalizedError {
    case bundleNotFound
    case modelsNotFound(String)
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case .bundleNotFound:
            return "Model bundle directory not found in app resources"
        case .modelsNotFound(let detail):
            return "Model files missing from app bundle: \(detail)"
        case .loadFailed(let detail):
            return "Failed to load models: \(detail)"
        }
    }
}

@MainActor
@Observable
final class ModelManager {
    var isLoading = false
    var loadProgress: Double = 0
    var loadError: String?
    var modelsReady = false

    private(set) var asrModels: AsrModels?
    private(set) var diarizer: SortformerDiarizer?

    private let logger = Logger(subsystem: "com.caddie.app", category: "ModelManager")

    func loadModelsFromBundle() async {
        guard !modelsReady else {
            logger.info("Models already loaded")
            return
        }

        isLoading = true
        loadProgress = 0
        loadError = nil

        do {
            guard let modelsDir = Bundle.main.resourceURL?
                .appendingPathComponent("Models") else {
                throw ModelLoadError.bundleNotFound
            }

            // Verify ASR models exist before attempting load
            let asrDir = modelsDir.appendingPathComponent("parakeet-tdt-0.6b-v3-coreml")
            guard AsrModels.modelsExist(at: asrDir, version: .v3) else {
                throw ModelLoadError.modelsNotFound("ASR models missing at \(asrDir.path)")
            }

            // Step 1: Load ASR models (~60% of work)
            logger.info("Loading ASR models from bundle...")
            let models = try await AsrModels.load(from: asrDir, version: .v3)
            asrModels = models
            loadProgress = 0.6
            logger.info("ASR models loaded")

            // Step 2: Load Sortformer models (~40% of work)
            logger.info("Loading diarization models from bundle...")
            let sortformerModels = try await SortformerModels.loadFromHuggingFace(
                config: .default,
                cacheDirectory: modelsDir
            )
            let sortformer = SortformerDiarizer(config: .default)
            sortformer.initialize(models: sortformerModels)
            diarizer = sortformer
            loadProgress = 1.0
            logger.info("Diarization models loaded")

            modelsReady = true
        } catch {
            loadError = error.localizedDescription
            logger.error("Model loading failed: \(error.localizedDescription)")
        }

        isLoading = false
    }
}
```

### CI Cache Configuration

```yaml
# In release.yml, before the Build Release step:
- name: Cache ML Models
  uses: actions/cache@v4
  with:
    path: Resources/Models
    key: ml-models-parakeet-v3-sortformer-v2
    restore-keys: |
      ml-models-
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Runtime model download | Bundle in app | This phase | Zero network dependency after install |
| `AsrModels.downloadAndLoad()` | `AsrModels.load(from:)` | FluidAudio 0.12.x | Explicit local loading, no HF dependency |
| 5-min download timeout | N/A (local I/O) | This phase | Sub-second model loading |

## Open Questions

1. **Sortformer model compilation time on first load**
   - What we know: `SortformerModels.load(config:mainModelPath:)` calls `MLModel.compileModel(at:)` for `.mlpackage` files, but `.mlmodelc` bundles are pre-compiled and skip this step
   - What's unclear: Whether `loadFromHuggingFace` with `.mlmodelc` bundles still triggers compilation or loads directly
   - Recommendation: The `.mlmodelc` format is already compiled, so loading should be fast (validated by `DownloadUtils.loadModels()` using `MLModel(contentsOf:configuration:)` directly on `.mlmodelc` paths). Test to confirm sub-second loading.

2. **analytics/ directory necessity**
   - What we know: The HuggingFace repos contain `analytics/` subdirectories inside `.mlmodelc` bundles
   - What's unclear: Whether CoreML requires these directories to be present, even if empty
   - Recommendation: Create them as empty directories in the download script to be safe. Low cost, prevents potential issues.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | XCTest (Swift 6.0) |
| Config file | project.yml (CaddieTests target) |
| Quick run command | `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -configuration Debug -destination 'platform=macOS'` |
| Full suite command | Same as quick run |

### Phase Requirements to Test Map
| Behavior | Test Type | Automated Command | File Exists? |
|----------|-----------|-------------------|-------------|
| ModelManager.loadModelsFromBundle() handles missing bundle dir | unit | `xcodebuild test -only-testing:CaddieTests/ModelManagerTests` | Needs update |
| ModelManager.loadModelsFromBundle() sets modelsReady on success | unit (mock) | `xcodebuild test -only-testing:CaddieTests/ModelManagerTests` | Needs update |
| ModelLoadError has proper descriptions | unit | `xcodebuild test -only-testing:CaddieTests/ModelManagerTests` | Needs update |
| OnboardingView shows "Loading" not "Downloading" | manual | N/A | N/A |
| Download script is idempotent | integration | `bash scripts/download-models.sh && bash scripts/download-models.sh` | Wave 0 |
| CI release builds with models | e2e | GitHub Actions release workflow | Existing |

### Wave 0 Gaps
- [ ] Update `Tests/ModelManagerTests.swift` -- existing tests reference download/timeout behavior that changes to load-from-bundle behavior
- [ ] Add test for `ModelLoadError` error descriptions

## Sources

### Primary (HIGH confidence)
- FluidAudio v0.12.4 source code: `AsrModels.swift` -- `load(from:)` API, directory structure, vocabulary loading
- FluidAudio v0.12.4 source code: `SortformerModelInference.swift` -- `loadFromHuggingFace(cacheDirectory:)` API
- FluidAudio v0.12.4 source code: `DownloadUtils.swift` -- `loadModels()` local-first check, cache structure
- FluidAudio v0.12.4 source code: `ModelNames.swift` -- repo folder names, required model file sets
- FluidAudio v0.12.4 source code: `SortformerDiarizerPipeline.swift` -- `initialize(models:)` API
- HuggingFace API -- [FluidInference/parakeet-tdt-0.6b-v3-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml) file sizes
- HuggingFace API -- [FluidInference/diar-streaming-sortformer-coreml](https://huggingface.co/FluidInference/diar-streaming-sortformer-coreml) file sizes
- FluidAudio [ManualModelLoading.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/ManualModelLoading.md) -- official guide for local loading

### Secondary (MEDIUM confidence)
- [XcodeGen ProjectSpec.md](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md) -- preBuildScripts YAML syntax
- [GitHub Actions cache changelog](https://github.blog/changelog/2025-11-20-github-actions-cache-size-can-now-exceed-10-gb-per-repository/) -- 10GB cache limit

### Tertiary (LOW confidence)
- None -- all findings verified against source code or official documentation

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - verified against FluidAudio source code directly
- Architecture: HIGH - load(from:) API confirmed in source, directory structure verified from HuggingFace
- Pitfalls: HIGH - identified from source code analysis of DownloadUtils retry behavior and Xcode CoreML handling
- Model sizes: HIGH - verified individual file sizes from HuggingFace API

**Research date:** 2026-03-23
**Valid until:** 2026-04-23 (stable -- FluidAudio API unlikely to change within patch versions)
