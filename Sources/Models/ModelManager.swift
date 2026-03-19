import Foundation
import os
import Observation

@Observable
final class ModelManager {
    var isDownloading = false
    var downloadProgress: Double = 0
    var downloadError: String?

    var modelsReady: Bool {
        let fm = FileManager.default
        let dir = Self.modelsDirectory
        let parakeetExists = fm.fileExists(atPath: dir.appendingPathComponent("parakeet").path)
        let diarizationExists = fm.fileExists(atPath: dir.appendingPathComponent("diarization").path)
        return parakeetExists && diarizationExists
    }

    static var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Caddie/models", isDirectory: true)
    }

    /// Check if models exist on disk; download them if not.
    func downloadModelsIfNeeded() async {
        guard !modelsReady else {
            CaddieLogger.app.info("Models already present on disk")
            return
        }

        let dir = Self.modelsDirectory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            downloadError = "Failed to create models directory: \(error.localizedDescription)"
            CaddieLogger.app.error("Failed to create models directory: \(error.localizedDescription)")
            return
        }

        isDownloading = true
        downloadProgress = 0
        downloadError = nil

        // TODO: FluidAudio likely handles its own model download.
        // Wire up actual HuggingFace download here when ready.
        CaddieLogger.app.info("Model download would start here")

        downloadProgress = 1.0
        isDownloading = false
    }

    /// Verify that model files on disk are valid.
    func verifyModels() async -> Bool {
        guard modelsReady else { return false }

        let fm = FileManager.default
        let dir = Self.modelsDirectory

        let parakeetDir = dir.appendingPathComponent("parakeet")
        let diarizationDir = dir.appendingPathComponent("diarization")

        do {
            let parakeetContents = try fm.contentsOfDirectory(atPath: parakeetDir.path)
            let diarizationContents = try fm.contentsOfDirectory(atPath: diarizationDir.path)

            if parakeetContents.isEmpty || diarizationContents.isEmpty {
                CaddieLogger.app.warning("Model directories exist but are empty")
                return false
            }

            CaddieLogger.app.info("Model verification passed")
            return true
        } catch {
            CaddieLogger.app.error("Model verification failed: \(error.localizedDescription)")
            return false
        }
    }
}
