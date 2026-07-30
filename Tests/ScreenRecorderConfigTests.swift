import XCTest
import AVFoundation
import CoreMedia
import Darwin
@testable import Caddie

/// Pure-function unit tests for ScreenRecorder preset/config/dimension/anchor math.
/// Mirrors the SystemAudioCapture pure-seam test style (exact numeric assertions).
final class ScreenRecorderConfigTests: XCTestCase {

    // MARK: - QualityPreset values (VID-06)

    func testPresetFPS() {
        XCTAssertEqual(ScreenRecorder.QualityPreset.compact.fps, 10)
        XCTAssertEqual(ScreenRecorder.QualityPreset.balanced.fps, 15)
        XCTAssertEqual(ScreenRecorder.QualityPreset.high.fps, 30)
    }

    func testPresetBitrate() {
        XCTAssertEqual(ScreenRecorder.QualityPreset.compact.bitrate, 1_500_000)
        XCTAssertEqual(ScreenRecorder.QualityPreset.balanced.bitrate, 2_500_000)
        XCTAssertEqual(ScreenRecorder.QualityPreset.high.bitrate, 4_000_000)
    }

    func testPresetMinimumFrameInterval() {
        XCTAssertEqual(ScreenRecorder.QualityPreset.balanced.minimumFrameInterval, CMTime(value: 1, timescale: 15))
        XCTAssertEqual(ScreenRecorder.QualityPreset.compact.minimumFrameInterval, CMTime(value: 1, timescale: 10))
        XCTAssertEqual(ScreenRecorder.QualityPreset.high.minimumFrameInterval, CMTime(value: 1, timescale: 30))
    }

    func testDefaultPresetIsBalanced() {
        XCTAssertEqual(ScreenRecorder.QualityPreset.default, .balanced)
    }

    // MARK: - videoSettings builder (VID-06, kills Pitfall 3 uncapped bitrate)

    func testVideoSettingsUsesHEVCCodec() {
        let settings = ScreenRecorder.videoSettings(for: .balanced, dimensions: (width: 1920, height: 1080))
        XCTAssertEqual(settings[AVVideoCodecKey] as? AVVideoCodecType, AVVideoCodecType.hevc)
    }

    func testVideoSettingsCapsBitrateToPresetValue() {
        let settings = ScreenRecorder.videoSettings(for: .balanced, dimensions: (width: 1920, height: 1080))
        let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any]
        XCTAssertNotNil(compression)
        XCTAssertEqual(compression?[AVVideoAverageBitRateKey] as? Int, 2_500_000)
    }

    func testVideoSettingsCapsBitratePerPreset() {
        let compact = ScreenRecorder.videoSettings(for: .compact, dimensions: (width: 1280, height: 720))
        let compactBitrate = (compact[AVVideoCompressionPropertiesKey] as? [String: Any])?[AVVideoAverageBitRateKey] as? Int
        XCTAssertEqual(compactBitrate, 1_500_000)

        let high = ScreenRecorder.videoSettings(for: .high, dimensions: (width: 1920, height: 1080))
        let highBitrate = (high[AVVideoCompressionPropertiesKey] as? [String: Any])?[AVVideoAverageBitRateKey] as? Int
        XCTAssertEqual(highBitrate, 4_000_000)
    }

    func testVideoSettingsDimensionsMatchStream() {
        let settings = ScreenRecorder.videoSettings(for: .balanced, dimensions: (width: 1920, height: 1080))
        XCTAssertEqual(settings[AVVideoWidthKey] as? Int, 1920)
        XCTAssertEqual(settings[AVVideoHeightKey] as? Int, 1080)
    }

    // MARK: - targetDimensions (VID-06, kills Pitfall 4 dimension mismatch)

    func testTargetDimensions_2xRetinaDownscale() {
        let dims = ScreenRecorder.targetDimensions(sourceWidthPx: 3840, sourceHeightPx: 2160, maxLongEdge: 1920)
        XCTAssertEqual(dims.width, 1920)
        XCTAssertEqual(dims.height, 1080)
    }

    func testTargetDimensions_returnsEvenNumbers() {
        let dims = ScreenRecorder.targetDimensions(sourceWidthPx: 2880, sourceHeightPx: 1800, maxLongEdge: 1920)
        XCTAssertEqual(dims.width % 2, 0, "HEVC requires even width")
        XCTAssertEqual(dims.height % 2, 0, "HEVC requires even height")
    }

    func testTargetDimensions_noUpscaleWhenUnderClamp() {
        let dims = ScreenRecorder.targetDimensions(sourceWidthPx: 1280, sourceHeightPx: 720, maxLongEdge: 1920)
        XCTAssertEqual(dims.width, 1280)
        XCTAssertEqual(dims.height, 720)
    }

    // MARK: - hostTicksToSeconds (STOR-04 anchor math)

    func testHostTicksToSeconds_identityTimebase() {
        let seconds = ScreenRecorder.hostTicksToSeconds(1_000_000_000, timebase: mach_timebase_info_data_t(numer: 1, denom: 1))
        XCTAssertEqual(seconds, 1.0, accuracy: 1e-9)
    }

    func testHostTicksToSeconds_appleSiliconTimebase() {
        // numer:125, denom:3 is a typical Apple Silicon timebase.
        // 24_000_000 ticks * 125 / 3 / 1e9 == 1.0 second.
        let seconds = ScreenRecorder.hostTicksToSeconds(24_000_000, timebase: mach_timebase_info_data_t(numer: 125, denom: 3))
        XCTAssertEqual(seconds, 1.0, accuracy: 1e-9)
    }
}
