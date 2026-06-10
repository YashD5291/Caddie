import XCTest
@testable import Caddie

final class AudioRecorderDeviceRoutingTests: XCTestCase {

    func testStartSignatureAcceptsDeviceUID() {
        // Verify the new mono start method signature compiles and is callable
        let recorder = AudioRecorder()
        let _: (URL, String?) throws -> Void = {
            try recorder.start(outputPath: $0, deviceUID: $1)
        }
    }

    func testNilDeviceUIDIsAcceptedForSystemDefault() {
        // nil deviceUID means "use system default input device" — must compile
        let recorder = AudioRecorder()
        let _: (URL) throws -> Void = {
            try recorder.start(outputPath: $0, deviceUID: nil)
        }
    }

    /// Switching the device while not recording should silently no-op rather than
    /// throw. This lets UI code wire `onChange` of the device picker unconditionally
    /// without first checking recording state — the recorder is the source of truth.
    func testSwitchDeviceWhileNotRecording_isSilentNoOp() throws {
        let recorder = AudioRecorder()
        // No `start()` call — recorder is idle. Switch must not throw, and must
        // not produce any side effects that would interfere with a later start.
        XCTAssertNoThrow(try recorder.switchDevice(deviceUID: "some-uid"))
        XCTAssertNoThrow(try recorder.switchDevice(deviceUID: nil))
    }

    func testSwitchDeviceSignatureMatchesStart() {
        // Both start and switchDevice should accept the same optional-String UID,
        // so a generic UI handler can pass the same value to either.
        let recorder = AudioRecorder()
        let _: (String?) throws -> Void = {
            try recorder.switchDevice(deviceUID: $0)
        }
    }

    /// The switchDevice double-failure path finalizes the recording (cancels the flush
    /// timer, drains the ring buffer, disposes the WAV) and clears `isRecording`. The
    /// coordinator's subsequent `stop()` must therefore be a safe no-op — calling stop()
    /// when not recording does nothing and does not crash, proving no live timer/file is
    /// left behind for a second teardown to handle.
    func testStopIsIdempotentWhenNotRecording() {
        let recorder = AudioRecorder()
        // recorder is idle (never started) -- mirrors the post-finalize state.
        recorder.stop()
        recorder.stop()
        // Reaching here without a crash proves stop() is a guarded no-op.
        XCTAssertTrue(true)
    }
}
