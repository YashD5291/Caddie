import XCTest
@testable import Caddie

@MainActor
final class ModelManagerTests: XCTestCase {

    // MARK: - Timeout Mechanism

    func testDownloadTimesOutAfterDeadline() async throws {
        // Test the timeout mechanism directly: a slow operation should be cancelled
        let manager = ModelManager()

        do {
            try await manager.withTimeout(seconds: 1) {
                // Simulate a download that takes way too long
                try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                return ()
            }
            XCTFail("Expected timeout error to be thrown")
        } catch let error as ModelDownloadError {
            guard case .timedOut(let seconds) = error else {
                XCTFail("Expected .timedOut error, got \(error)")
                return
            }
            XCTAssertEqual(seconds, 1)
        }
    }

    func testTimeoutErrorMessageContainsRetryGuidance() {
        let error = ModelDownloadError.timedOut(seconds: 300)
        let description = error.errorDescription ?? ""

        XCTAssertTrue(
            description.contains("timed out"),
            "Error should mention 'timed out', got: \(description)"
        )
        XCTAssertTrue(
            description.contains("Retry"),
            "Error should mention 'Retry', got: \(description)"
        )
        XCTAssertTrue(
            description.contains("5 minutes"),
            "Error should mention '5 minutes', got: \(description)"
        )
    }

    func testTimeoutConstantIsFiveMinutes() {
        XCTAssertEqual(ModelManager.downloadTimeoutSeconds, 300, "Download timeout should be 5 minutes (300 seconds)")
    }
}
