import Foundation
import os
import Observation
import FluidAudio

// MARK: - ModelDownloadError

enum ModelDownloadError: Error, LocalizedError, Sendable {
    case timedOut(seconds: UInt64)

    var errorDescription: String? {
        switch self {
        case .timedOut(let seconds):
            return "Model download timed out after \(seconds / 60) minutes. Check your internet connection and tap Retry."
        }
    }
}

// MARK: - ModelManager

@MainActor
@Observable
final class ModelManager {
    static let downloadTimeoutSeconds: UInt64 = 300  // 5 minutes

    var isDownloading = false
    var downloadProgress: Double = 0
    var downloadError: String?
    var modelsReady = false

    private(set) var asrModels: AsrModels?
    private(set) var diarizer: SortformerDiarizer?

    private let logger = Logger(subsystem: "com.caddie.app", category: "ModelManager")

    // MARK: - Timeout Helper

    func withTimeout<T: Sendable>(
        seconds: UInt64,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                throw ModelDownloadError.timedOut(seconds: seconds)
            }
            // First to finish wins -- the other is cancelled
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - Download

    /// Downloads and loads ASR + diarization models via FluidAudio.
    /// Models are cached by FluidAudio after first download.
    /// Safe to call multiple times — returns immediately if already downloaded.
    /// Times out after 5 minutes with a user-visible error and retry option.
    func downloadModelsIfNeeded() async {
        guard !modelsReady else {
            logger.info("Models already loaded")
            return
        }

        isDownloading = true
        downloadProgress = 0
        downloadError = nil

        do {
            try await withTimeout(seconds: Self.downloadTimeoutSeconds) { [self] in
                // Step 1: Download ASR models (~60% of total)
                logger.info("Downloading ASR models...")
                let models = try await AsrModels.downloadAndLoad(version: .v3)
                await MainActor.run {
                    self.asrModels = models
                    self.downloadProgress = 0.6
                }
                logger.info("ASR models downloaded and loaded")

                // Step 2: Download and initialize Sortformer diarizer (~40% of total)
                logger.info("Initializing diarizer...")
                let sortformerModels = try await SortformerModels.loadFromHuggingFace(
                    config: .default
                )
                let sortformer = SortformerDiarizer(config: .default)
                sortformer.initialize(models: sortformerModels)
                await MainActor.run {
                    self.diarizer = sortformer
                    self.downloadProgress = 1.0
                }
                logger.info("Diarizer initialized")
            }
            modelsReady = true
        } catch {
            downloadError = error.localizedDescription
            logger.error("Model download failed: \(error.localizedDescription)")
        }

        isDownloading = false
    }
}
