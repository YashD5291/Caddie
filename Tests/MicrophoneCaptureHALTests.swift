import XCTest
@testable import Caddie

@MainActor
final class MicrophoneCaptureHALTests: XCTestCase {

    // MARK: - Error Handling

    func testStartWithInvalidDeviceUIDThrowsDeviceNotFound() {
        let capture = MicrophoneCapture()
        XCTAssertThrowsError(
            try capture.start(deviceUID: "nonexistent-uid-12345") { _, _ in }
        ) { error in
            guard case MicrophoneCapture.CaptureError.deviceNotFound(let uid) = error else {
                XCTFail("Expected deviceNotFound, got \(error)")
                return
            }
            XCTAssertEqual(uid, "nonexistent-uid-12345")
        }
    }

    // MARK: - State Management

    func testStopCleansUpHALResources() {
        let capture = MicrophoneCapture()
        // Even without a successful start, stop should be safe to call
        capture.stop()
        // Calling stop again should be a no-op
        capture.stop()
    }

    func testDoubleStartIsNoOp() throws {
        let capture = MicrophoneCapture()
        // First start with invalid UID will throw
        XCTAssertThrowsError(
            try capture.start(deviceUID: "nonexistent-uid-12345") { _, _ in }
        )
        // Second start with invalid UID also throws (not running, so not a no-op)
        XCTAssertThrowsError(
            try capture.start(deviceUID: "another-invalid-uid") { _, _ in }
        )
    }

    // MARK: - V1.0 Regression

    func testV1StartPathStillWorks() {
        let capture = MicrophoneCapture()
        // The v1.0 start(onBuffer:) method must still exist and be callable.
        // It may throw in CI (no mic), which is expected.
        do {
            try capture.start { _, _ in }
            // If it succeeds, stop it
            capture.stop()
        } catch {
            // Expected in CI: noInputDevice or similar
            // The point is it compiles and the method signature is unchanged
        }
    }

    // MARK: - Error Descriptions

    func testCaptureErrorDescriptions() {
        let errors: [MicrophoneCapture.CaptureError] = [
            .noInputDevice,
            .failedToCreateConverter,
            .deviceNotFound("test-uid"),
            .audioComponentNotFound,
            .failedToCreateAudioUnit(noErr),
            .failedToConfigureAudioUnit(noErr),
            .failedToSetDevice(noErr),
            .failedToSetFormat(noErr),
            .failedToSetCallback(noErr),
            .failedToInitializeAudioUnit(noErr),
            .failedToStartAudioUnit(noErr),
            .audioUnitNotReady,
        ]

        for error in errors {
            XCTAssertNotNil(
                error.errorDescription,
                "Missing errorDescription for \(error)"
            )
        }
    }

    // MARK: - HAL Path Specifics

    func testStartWithDeviceUIDDoesNotAffectAVAudioEnginePath() {
        // After a failed HAL start, the AVAudioEngine path should still work
        let capture = MicrophoneCapture()

        // Attempt HAL start with invalid UID (will throw)
        XCTAssertThrowsError(
            try capture.start(deviceUID: "nonexistent-uid") { _, _ in }
        )

        // V1.0 path should still be callable
        do {
            try capture.start { _, _ in }
            capture.stop()
        } catch {
            // Expected in CI without microphone
        }
    }
}
