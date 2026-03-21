import Foundation
import os
import Observation
import FluidAudio

@MainActor
@Observable
final class ModelManager {
    var isDownloading = false
    var downloadProgress: Double = 0
    var downloadError: String?
    var modelsReady = false

    private(set) var asrModels: AsrModels?
    private(set) var diarizer: SortformerDiarizer?

    private let logger = Logger(subsystem: "com.caddie.app", category: "ModelManager")

    /// Downloads and loads ASR + diarization models via FluidAudio.
    /// Models are cached by FluidAudio after first download.
    /// Safe to call multiple times — returns immediately if already downloaded.
    func downloadModelsIfNeeded() async {
        guard !modelsReady else {
            logger.info("Models already loaded")
            return
        }

        isDownloading = true
        downloadProgress = 0
        downloadError = nil

        do {
            // Step 1: Download ASR models (~60% of total)
            logger.info("Downloading ASR models...")
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            asrModels = models
            downloadProgress = 0.6
            logger.info("ASR models downloaded and loaded")

            // Step 2: Download and initialize Sortformer diarizer (~40% of total)
            logger.info("Initializing diarizer...")
            let sortformerModels = try await SortformerModels.loadFromHuggingFace(
                config: .default
            )
            let sortformer = SortformerDiarizer(config: .default)
            sortformer.initialize(models: sortformerModels)
            diarizer = sortformer
            downloadProgress = 1.0
            logger.info("Diarizer initialized")

            modelsReady = true
        } catch {
            downloadError = error.localizedDescription
            logger.error("Model download failed: \(error.localizedDescription)")
        }

        isDownloading = false
    }
}
