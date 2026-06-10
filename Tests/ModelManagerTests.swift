import XCTest
@testable import Caddie

@MainActor
final class ModelManagerTests: XCTestCase {

    // MARK: - ModelLoadError Descriptions

    func testBundleNotFoundErrorDescription() {
        let error = ModelLoadError.bundleNotFound
        let description = error.errorDescription ?? ""
        XCTAssertTrue(
            description.contains("Model bundle directory not found"),
            "Expected 'Model bundle directory not found' in: \(description)"
        )
    }

    func testModelsNotFoundErrorDescription() {
        let error = ModelLoadError.modelsNotFound("ASR models missing at /path")
        let description = error.errorDescription ?? ""
        XCTAssertTrue(
            description.contains("Model files missing from app bundle"),
            "Expected 'Model files missing from app bundle' in: \(description)"
        )
        XCTAssertTrue(
            description.contains("ASR"),
            "Expected error detail in description: \(description)"
        )
    }

    func testLoadFailedErrorDescription() {
        let error = ModelLoadError.loadFailed("corrupt file")
        let description = error.errorDescription ?? ""
        XCTAssertTrue(
            description.contains("Failed to load models"),
            "Expected 'Failed to load models' in: \(description)"
        )
        XCTAssertTrue(
            description.contains("corrupt file"),
            "Expected error detail in description: \(description)"
        )
    }

    // MARK: - ModelManager Initial State

    func testInitialState() {
        let manager = ModelManager()
        XCTAssertFalse(manager.isLoading)
        XCTAssertEqual(manager.loadProgress, 0)
        XCTAssertNil(manager.loadError)
        XCTAssertFalse(manager.modelsReady)
    }

    // MARK: - Sortformer No-Runtime-Download Guard

    func testSortformerModelsExistReturnsFalseWhenMissing() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelManagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        XCTAssertFalse(ModelManager.sortformerModelsExist(in: tempDir))
    }

    func testSortformerModelsExistReturnsTrueWhenPresent() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelManagerTests-\(UUID().uuidString)")
        let modelPath = tempDir
            .appendingPathComponent("sortformer")
            .appendingPathComponent("SortformerV2.mlmodelc")
        try FileManager.default.createDirectory(at: modelPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        XCTAssertTrue(ModelManager.sortformerModelsExist(in: tempDir))
    }
}
