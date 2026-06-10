import Foundation
import os
import Observation
import FluidAudio

// MARK: - ModelLoadError

enum ModelLoadError: Error, LocalizedError, Sendable {
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

// MARK: - ModelManager

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

    // MARK: - Model Existence Checks

    /// Returns true when the bundled sortformer CoreML model is present under
    /// `<modelsDir>/sortformer/SortformerV2.mlmodelc`. Side-effect-free; used to
    /// gate loading so no runtime HuggingFace download is ever attempted.
    nonisolated static func sortformerModelsExist(in modelsDir: URL) -> Bool {
        let sortformerModelPath = modelsDir
            .appendingPathComponent("sortformer")
            .appendingPathComponent("SortformerV2.mlmodelc")
        return FileManager.default.fileExists(atPath: sortformerModelPath.path)
    }

    // MARK: - Bundle Loading

    /// Loads ASR and diarization models from the app bundle.
    /// Models must be present at Bundle.main.resourceURL/Models/.
    /// Safe to call multiple times -- returns immediately if already loaded.
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

            // Step 1: Load ASR models (~60% of work)
            let asrDir = modelsDir.appendingPathComponent("parakeet-tdt-0.6b-v3-coreml")

            // CRITICAL: Pre-check that ASR model files exist before calling load().
            // Without this guard, a missing-models condition triggers FluidAudio's
            // DownloadUtils auto-recovery (Pitfall 1 from RESEARCH.md): it attempts
            // to delete the bundle directory and re-download from HuggingFace, which
            // fails silently in a read-only app bundle context.
            guard AsrModels.modelsExist(at: asrDir, version: .v3) else {
                throw ModelLoadError.modelsNotFound("ASR models missing at \(asrDir.path)")
            }

            logger.info("Loading ASR models from bundle...")
            let models = try await AsrModels.load(from: asrDir, version: .v3)
            asrModels = models
            loadProgress = 0.6
            logger.info("ASR models loaded")

            // Step 2: Load Sortformer models (~40% of work)
            // CRITICAL: Pre-check that the bundled sortformer model exists before
            // calling loadFromHuggingFace(). FluidAudio has no `modelsExist` equivalent
            // for sortformer, so we check the known bundled path directly. Without this
            // guard, a missing-models condition would let FluidAudio attempt a runtime
            // HuggingFace download, which must never happen in a read-only/offline app
            // bundle (mirrors the ASR guard above). When present, loadFromHuggingFace
            // loads from cacheDirectory with no network round-trip.
            guard Self.sortformerModelsExist(in: modelsDir) else {
                let sortformerPath = modelsDir
                    .appendingPathComponent("sortformer")
                    .appendingPathComponent("SortformerV2.mlmodelc")
                throw ModelLoadError.modelsNotFound("Sortformer models missing at \(sortformerPath.path)")
            }

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
