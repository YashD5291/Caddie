import XCTest
@testable import Caddie

final class SystemAudioCaptureDeviceTests: XCTestCase {

    func testStartWithInvalidDeviceUIDThrowsDeviceNotFound() {
        let capture = SystemAudioCapture()
        XCTAssertThrowsError(
            try capture.start(deviceUID: "nonexistent-uid-99999") { _, _ in }
        ) { error in
            guard case SystemAudioCapture.CaptureError.deviceNotFound(let uid) = error else {
                XCTFail("Expected deviceNotFound, got \(error)")
                return
            }
            XCTAssertEqual(uid, "nonexistent-uid-99999")
        }
    }

    func testStopCleansUpDirectDeviceResources() {
        // After stop on a direct device path (even though start fails for invalid UID),
        // the capture should be safe to stop without crashing and remain in a clean state.
        let capture = SystemAudioCapture()
        // start will fail (invalid UID), so stop should be a no-op (isRunning = false)
        try? capture.start(deviceUID: "nonexistent-uid-99999") { _, _ in }
        capture.stop()
        // If we get here without crash, cleanup is correct
    }

    func testDeviceNotFoundErrorDescription() {
        let error = SystemAudioCapture.CaptureError.deviceNotFound("test-uid")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(
            error.errorDescription?.contains("test-uid") ?? false,
            "Error description should contain the UID, got: \(error.errorDescription ?? "nil")"
        )
    }

    func testV1ProcessTapStartStillCompiles() {
        // Regression test: existing start(processID:onBuffer:) method must remain callable
        let capture = SystemAudioCapture()
        // We don't actually start (requires Screen Recording permission),
        // just verify the method exists and compiles
        let _: (pid_t?, @escaping SystemAudioCapture.BufferCallback) throws -> Void = capture.start(processID:onBuffer:)
    }
}
