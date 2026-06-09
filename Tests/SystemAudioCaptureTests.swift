import XCTest
import AVFoundation
import CoreAudio
@testable import Caddie

@MainActor
final class SystemAudioCaptureTests: XCTestCase {

    func testCleanupStaleAggregateDevicesDoesNotCrash() {
        // On a clean system with no stale Caddie devices, cleanup should complete silently
        SystemAudioCapture.cleanupStaleAggregateDevices()
    }

    func testCleanupStaleAggregateDevicesIsStaticMethod() {
        // Verify the method is callable as a static method without an instance
        let cleanup: () -> Void = SystemAudioCapture.cleanupStaleAggregateDevices
        cleanup()
    }

    // MARK: - makeDownsamplingConverter

    func testMakeConverter_48kFloat32_to16kInt16_succeeds() {
        var native = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let result = SystemAudioCapture.makeDownsamplingConverter(from: native, toSampleRate: 16000)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.nativeFormat.sampleRate, 48000)
        XCTAssertEqual(result?.targetFormat.sampleRate, 16000)
        XCTAssertEqual(result?.targetFormat.channelCount, 1)
    }

    func testMakeConverter_passesThroughWhenAlreadyTargetRate() {
        var native = AudioStreamBasicDescription(
            mSampleRate: 16000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        let result = SystemAudioCapture.makeDownsamplingConverter(from: native, toSampleRate: 16000)
        XCTAssertNotNil(result)
        // Even when rates match, the converter is built — caller decides whether to bypass.
        XCTAssertEqual(result?.nativeFormat.sampleRate, 16000)
    }

    func testMakeConverter_44100Hz_to16k_buildsValidConverter() {
        var native = AudioStreamBasicDescription(
            mSampleRate: 44100,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let result = SystemAudioCapture.makeDownsamplingConverter(from: native, toSampleRate: 16000)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.nativeFormat.sampleRate, 44100)
    }

    /// Multi-channel devices like Jump Audio's 8ch driver previously failed to
    /// initialize because `AVAudioFormat(streamDescription:)` returns nil for
    /// >2 channels without an explicit channel layout. The helper now supplies
    /// a Discrete-In-Order layout so the converter builds successfully.
    func testMakeConverter_8ChannelDevice_buildsValidConverter() {
        let channels: UInt32 = 8
        var native = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let result = SystemAudioCapture.makeDownsamplingConverter(from: native, toSampleRate: 16000)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.nativeFormat.channelCount, 8)
        XCTAssertEqual(result?.targetFormat.channelCount, 1)
    }

    // MARK: - outputCapacity sizing (Finding 6)

    func testOutputCapacity_downsample48kTo16k() {
        // 4096 input frames at 48k -> ~1365.33 output frames at 16k, +1 guard.
        let cap = SystemAudioCapture.outputCapacity(
            forInputFrames: 4096, inputSampleRate: 48000, outputSampleRate: 16000
        )
        XCTAssertEqual(cap, 1366)
    }

    func testOutputCapacity_sameRateAddsGuardFrame() {
        // No resampling: output capacity equals input frames plus the +1 guard.
        let cap = SystemAudioCapture.outputCapacity(
            forInputFrames: 4096, inputSampleRate: 16000, outputSampleRate: 16000
        )
        XCTAssertEqual(cap, 4097)
    }

    func testOutputCapacity_44100To16kRoundsDownThenGuards() {
        // 512 * (16000/44100) = 185.76 -> truncates to 185, +1 = 186.
        let cap = SystemAudioCapture.outputCapacity(
            forInputFrames: 512, inputSampleRate: 44100, outputSampleRate: 16000
        )
        XCTAssertEqual(cap, 186)
    }
}
