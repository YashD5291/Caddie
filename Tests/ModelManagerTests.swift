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
}
