import XCTest
@testable import Caddie

/// Verifies the built app bundle carries the Sparkle configuration keys required
/// for auto-updates. CaddieTests links against the Caddie app target, so
/// `Bundle.main` here resolves to Caddie.app and reads its built Info.plist.
final class SparkleConfigTests: XCTestCase {
    private static let expectedFeedURL =
        "https://github.com/YashD5291/Caddie/releases/latest/download/appcast.xml"

    func testSUFeedURLIsConfigured() {
        let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        XCTAssertNotNil(feedURL, "SUFeedURL missing from Info.plist")
        XCTAssertFalse(feedURL?.isEmpty ?? true, "SUFeedURL is empty")
        XCTAssertEqual(feedURL, Self.expectedFeedURL,
                       "SUFeedURL must point at the version-independent GitHub latest-asset appcast")
    }

    func testSUPublicEDKeyIsBase64Shaped() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        XCTAssertNotNil(key, "SUPublicEDKey missing from Info.plist")
        guard let key else { return }
        XCTAssertFalse(key.isEmpty, "SUPublicEDKey is empty")
        XCTAssertGreaterThanOrEqual(key.count, 40, "SUPublicEDKey shorter than a valid EdDSA public key")

        let base64Shaped = key.range(of: "^[A-Za-z0-9+/=]+$", options: .regularExpression) != nil
        XCTAssertTrue(base64Shaped, "SUPublicEDKey is not base64-shaped: \(key)")
    }
}
