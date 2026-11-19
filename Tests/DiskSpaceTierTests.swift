import XCTest
@testable import Caddie

/// Pure-function tests for the two-tier disk guard (STOR-03 as reinterpreted by D-01):
/// block below the 500 MB audio floor, record audio only below the preset-derived
/// video threshold (D-02), and apply only the floor when screen recording is off (D-03).
final class DiskSpaceTierTests: XCTestCase {

    // MARK: - Constants and thresholds (D-02)

    func testFloorAndHeadroomConstants() {
        XCTAssertEqual(RecordingCoordinator.minimumDiskSpaceBytes, 524_288_000)
        XCTAssertEqual(RecordingCoordinator.videoHeadroomSeconds, 7200)
    }

    func testThresholdPerPreset() {
        XCTAssertEqual(RecordingCoordinator.videoDiskThreshold(for: .compact), 1_874_288_000)
        XCTAssertEqual(RecordingCoordinator.videoDiskThreshold(for: .balanced), 2_774_288_000)
        XCTAssertEqual(RecordingCoordinator.videoDiskThreshold(for: .high), 4_124_288_000)
    }

    func testThresholdExceedsFloorForEveryPreset() {
        for preset in ScreenRecorder.QualityPreset.allCases {
            XCTAssertGreaterThan(
                RecordingCoordinator.videoDiskThreshold(for: preset),
                RecordingCoordinator.minimumDiskSpaceBytes,
                "Threshold for \(preset) must sit above the audio floor"
            )
        }
    }

    // MARK: - Tier boundaries (D-01)

    func testBelowFloorBlocksRegardlessOfPreset() {
        XCTAssertEqual(RecordingCoordinator.diskSpaceTier(available: 524_287_999, videoPreset: nil), .belowAudioFloor)
        XCTAssertEqual(RecordingCoordinator.diskSpaceTier(available: 524_287_999, videoPreset: .balanced), .belowAudioFloor)
    }

    func testFloorBoundaryIsInclusive() {
        XCTAssertEqual(RecordingCoordinator.diskSpaceTier(available: 524_288_000, videoPreset: nil), .sufficient)
        XCTAssertEqual(RecordingCoordinator.diskSpaceTier(available: 524_288_000, videoPreset: .balanced), .belowVideoThreshold)
    }

    func testVideoThresholdBoundaryIsInclusive() {
        XCTAssertEqual(RecordingCoordinator.diskSpaceTier(available: 2_774_287_999, videoPreset: .balanced), .belowVideoThreshold)
        XCTAssertEqual(RecordingCoordinator.diskSpaceTier(available: 2_774_288_000, videoPreset: .balanced), .sufficient)
    }

    func testNonPositiveCapacityIsBelowFloor() {
        XCTAssertEqual(RecordingCoordinator.diskSpaceTier(available: 0, videoPreset: nil), .belowAudioFloor)
        XCTAssertEqual(RecordingCoordinator.diskSpaceTier(available: -1, videoPreset: .balanced), .belowAudioFloor)
        XCTAssertEqual(RecordingCoordinator.diskSpaceTier(available: Int64.max, videoPreset: .high), .sufficient)
    }

    func testFeatureOffUsesFloorOnly() {
        // 600 MiB is below every video threshold, but with screen recording off (D-03)
        // only the audio floor applies.
        XCTAssertEqual(RecordingCoordinator.diskSpaceTier(available: 629_145_600, videoPreset: nil), .sufficient)
    }

    // MARK: - Low-disk copy

    func testLowDiskMessageNamesBothSizes() {
        let message = RecordingCoordinator.lowDiskVideoMessage(
            availableBytes: 1_000_000_000,
            requiredBytes: 2_774_288_000
        )
        XCTAssertTrue(message.contains("disk space"), message)
        XCTAssertTrue(message.contains("audio only"), message)
        XCTAssertTrue(message.contains(ByteCountFormatter.string(fromByteCount: 1_000_000_000, countStyle: .file)), message)
        XCTAssertTrue(message.contains(ByteCountFormatter.string(fromByteCount: 2_774_288_000, countStyle: .file)), message)
    }
}
