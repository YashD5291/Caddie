import XCTest
@testable import Caddie

/// Pins the screen-recording feature gate's persistence contract (VID-01: off by
/// default) and the canonical video file layout.
final class ScreenRecordingSettingsTests: XCTestCase {

    // Deliberately a raw literal, NOT ScreenRecordingSettings.enabledKey: this pins the
    // persisted key name as a wire-format contract. If production ever renames the key,
    // these tests write the old name while the reader reads the new one and falls back
    // to the default — the resulting failures flag the silent drift. Do not replace with
    // the shared constant.
    private static let enabledKeyLiteral = "screenRecordingEnabled"

    /// The developer's real setting, saved so the suite never mutates it permanently.
    private var savedValue: Any?

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedValue = UserDefaults.standard.object(forKey: Self.enabledKeyLiteral)
        UserDefaults.standard.removeObject(forKey: Self.enabledKeyLiteral)
    }

    override func tearDownWithError() throws {
        if let savedValue {
            UserDefaults.standard.set(savedValue, forKey: Self.enabledKeyLiteral)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.enabledKeyLiteral)
        }
        savedValue = nil
        try super.tearDownWithError()
    }

    // MARK: - Feature gate contract

    func testEnabledKeyIsStableLiteral() {
        XCTAssertEqual(ScreenRecordingSettings.enabledKey, Self.enabledKeyLiteral)
    }

    func testDefaultEnabledIsOff() {
        XCTAssertFalse(ScreenRecordingSettings.defaultEnabled)
    }

    func testIsEnabledIsFalseWhenKeyAbsent() {
        UserDefaults.standard.removeObject(forKey: Self.enabledKeyLiteral)
        XCTAssertFalse(ScreenRecordingSettings.isEnabled)
    }

    func testIsEnabledReadsExplicitTrue() {
        UserDefaults.standard.set(true, forKey: Self.enabledKeyLiteral)
        XCTAssertTrue(ScreenRecordingSettings.isEnabled)
    }

    func testIsEnabledReadsExplicitFalse() {
        UserDefaults.standard.set(false, forKey: Self.enabledKeyLiteral)
        XCTAssertFalse(ScreenRecordingSettings.isEnabled)
    }

    // MARK: - Canonical video path layout

    func testVideoPathIsMovBesideAudio() {
        let url = AudioFileManager.videoPath(for: "abc123")
        XCTAssertEqual(url.lastPathComponent, "abc123.mov")
        XCTAssertEqual(url.pathExtension, "mov")
    }

    func testVideoPathSharesDirectoryWithAlacPath() {
        let video = AudioFileManager.videoPath(for: "abc123")
        let alac = AudioFileManager.alacPath(for: "abc123")
        XCTAssertEqual(
            video.deletingLastPathComponent().standardizedFileURL,
            alac.deletingLastPathComponent().standardizedFileURL
        )
    }
}
