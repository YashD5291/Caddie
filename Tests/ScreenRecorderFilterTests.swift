import XCTest
import CoreGraphics
@testable import Caddie

/// Filter-input selection tests (VID-05: exclude Caddie's own windows; select display).
/// The pure selection logic is unit-testable; the real SCContentFilter construction
/// needs the framework and lands in Plan 18-02.
final class ScreenRecorderFilterTests: XCTestCase {

    // MARK: - Caddie exclusion (VID-05)

    func testExcludedBundleIdentifiersReturnsOwnBundle() {
        XCTAssertEqual(ScreenRecorder.excludedBundleIdentifiers(ownBundleID: "com.caddie.app"), ["com.caddie.app"])
    }

    // MARK: - Display selection

    func testSelectDisplayReturnsTargetWhenAvailable() {
        let available: [CGDirectDisplayID] = [1, 2, 3]
        XCTAssertEqual(ScreenRecorder.selectDisplayID(available: available, target: 2), 2)
    }

    func testSelectDisplayDefaultsToFirstWhenNoTarget() {
        let available: [CGDirectDisplayID] = [1, 2, 3]
        XCTAssertEqual(ScreenRecorder.selectDisplayID(available: available, target: nil), 1)
    }

    func testSelectDisplayReturnsNilWhenNoDisplays() {
        let available: [CGDirectDisplayID] = []
        XCTAssertNil(ScreenRecorder.selectDisplayID(available: available, target: nil))
    }

    func testSelectDisplayDefaultsToFirstWhenTargetMissing() {
        let available: [CGDirectDisplayID] = [1, 2, 3]
        XCTAssertEqual(ScreenRecorder.selectDisplayID(available: available, target: 9), 1)
    }
}
