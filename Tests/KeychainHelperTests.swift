import XCTest
@testable import Caddie

final class KeychainHelperTests: XCTestCase {
    // Use a unique prefix to avoid colliding with real app keys
    private let testPrefix = "test_kh_"

    override func tearDown() {
        // Clean up all test keys from Keychain
        for suffix in ["key", "key1", "key2", "nonexistent", "access_token", "refresh_token", "token_expiry"] {
            KeychainHelper.delete(key: "\(testPrefix)\(suffix)")
        }
        // Also clean the standard OAuth keys used by deleteAll test
        KeychainHelper.delete(key: "access_token")
        KeychainHelper.delete(key: "refresh_token")
        KeychainHelper.delete(key: "token_expiry")
        KeychainHelper.delete(key: "user_email")
        super.tearDown()
    }

    func testSaveAndLoad() throws {
        let key = "\(testPrefix)key"
        let data = Data("hello".utf8)
        try KeychainHelper.save(key: key, data: data)
        let loaded = KeychainHelper.load(key: key)
        XCTAssertEqual(loaded, data)
        XCTAssertEqual(String(data: loaded!, encoding: .utf8), "hello")
    }

    func testLoadMissingReturnsNil() {
        let result = KeychainHelper.load(key: "\(testPrefix)nonexistent")
        XCTAssertNil(result)
    }

    func testSaveOverwritesExisting() throws {
        let key = "\(testPrefix)key"
        try KeychainHelper.save(key: key, data: Data("value1".utf8))
        try KeychainHelper.save(key: key, data: Data("value2".utf8))
        let loaded = KeychainHelper.load(key: key)
        XCTAssertEqual(String(data: loaded!, encoding: .utf8), "value2")
    }

    func testDeleteRemovesItem() throws {
        let key = "\(testPrefix)key"
        try KeychainHelper.save(key: key, data: Data("to_delete".utf8))
        KeychainHelper.delete(key: key)
        XCTAssertNil(KeychainHelper.load(key: key))
    }

    func testDeleteNonexistentDoesNotThrow() {
        // Should complete without error
        KeychainHelper.delete(key: "\(testPrefix)nonexistent")
    }

    func testDeleteAllClearsOAuthKeys() throws {
        try KeychainHelper.save(key: "access_token", data: Data("at".utf8))
        try KeychainHelper.save(key: "refresh_token", data: Data("rt".utf8))
        try KeychainHelper.save(key: "token_expiry", data: Data("exp".utf8))
        try KeychainHelper.save(key: "user_email", data: Data("test@test.com".utf8))

        KeychainHelper.deleteAll()

        XCTAssertNil(KeychainHelper.load(key: "access_token"))
        XCTAssertNil(KeychainHelper.load(key: "refresh_token"))
        XCTAssertNil(KeychainHelper.load(key: "token_expiry"))
        XCTAssertNil(KeychainHelper.load(key: "user_email"))
    }
}
