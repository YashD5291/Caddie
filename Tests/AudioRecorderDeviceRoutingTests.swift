import XCTest
@testable import Caddie

final class AudioRecorderDeviceRoutingTests: XCTestCase {

    func testStartSignatureAcceptsDeviceUIDs() {
        // Verify the new start method signature compiles and is callable
        let recorder = AudioRecorder()
        let _: (URL, pid_t?, String?, String?) throws -> Void = {
            try recorder.start(outputPath: $0, processID: $1, systemDeviceUID: $2, micDeviceUID: $3)
        }
    }

    func testDefaultParametersPreserveV1Behavior() {
        // Verify existing callers (without device UIDs) still compile
        let recorder = AudioRecorder()
        let _: (URL, pid_t?) throws -> Void = {
            try recorder.start(outputPath: $0, processID: $1)
        }
    }

    func testConflictingProcessIDAndSystemDeviceUIDThrows() throws {
        let recorder = AudioRecorder()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-conflict.wav")
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(
            try recorder.start(
                outputPath: url,
                processID: 12345,
                systemDeviceUID: "some-device-uid"
            )
        ) { error in
            guard case AudioRecorder.RecorderError.conflictingAudioSources = error else {
                XCTFail("Expected conflictingAudioSources, got \(error)")
                return
            }
        }
    }
}
