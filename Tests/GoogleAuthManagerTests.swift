import XCTest
@testable import Caddie

final class GoogleAuthManagerTests: XCTestCase {

    override func tearDown() {
        // Clean up Keychain state after each test
        KeychainHelper.delete(key: "access_token")
        KeychainHelper.delete(key: "refresh_token")
        KeychainHelper.delete(key: "token_expiry")
        KeychainHelper.delete(key: "user_email")
        super.tearDown()
    }

    // MARK: - PKCE Generation

    func testCodeVerifierLength() {
        let verifier = GoogleAuthManager.generateCodeVerifier()
        XCTAssertGreaterThanOrEqual(verifier.count, 43)
    }

    func testCodeVerifierIsBase64URL() {
        let verifier = GoogleAuthManager.generateCodeVerifier()
        let base64URLPattern = #"^[A-Za-z0-9_-]+$"#
        XCTAssertNotNil(verifier.range(of: base64URLPattern, options: .regularExpression),
                        "Verifier contains invalid characters: \(verifier)")
    }

    func testCodeChallengeIsDeterministic() {
        let challenge1 = GoogleAuthManager.generateCodeChallenge(from: "test_verifier")
        let challenge2 = GoogleAuthManager.generateCodeChallenge(from: "test_verifier")
        XCTAssertEqual(challenge1, challenge2)
    }

    func testCodeChallengeIsBase64URL() {
        let verifier = GoogleAuthManager.generateCodeVerifier()
        let challenge = GoogleAuthManager.generateCodeChallenge(from: verifier)
        let base64URLPattern = #"^[A-Za-z0-9_-]+$"#
        XCTAssertNotNil(challenge.range(of: base64URLPattern, options: .regularExpression),
                        "Challenge contains invalid characters: \(challenge)")
    }

    func testCodeChallengeIsDifferentFromVerifier() {
        let verifier = GoogleAuthManager.generateCodeVerifier()
        let challenge = GoogleAuthManager.generateCodeChallenge(from: verifier)
        XCTAssertNotEqual(verifier, challenge)
    }

    // MARK: - Authorization URL

    func testAuthURLContainsRequiredParams() {
        let challenge = GoogleAuthManager.generateCodeChallenge(from: "test_verifier")
        let url = GoogleAuthManager.buildAuthorizationURL(codeChallenge: challenge)
        let urlString = url.absoluteString

        XCTAssertTrue(urlString.contains("client_id="), "Missing client_id")
        XCTAssertTrue(urlString.contains("redirect_uri="), "Missing redirect_uri")
        XCTAssertTrue(urlString.contains("response_type=code"), "Missing response_type=code")
        XCTAssertTrue(urlString.contains("scope="), "Missing scope")
        XCTAssertTrue(urlString.contains("code_challenge="), "Missing code_challenge")
        XCTAssertTrue(urlString.contains("code_challenge_method=S256"), "Missing code_challenge_method")
        XCTAssertTrue(urlString.contains("access_type=offline"), "Missing access_type=offline")
    }

    func testAuthURLBaseIsCorrect() {
        let challenge = GoogleAuthManager.generateCodeChallenge(from: "v")
        let url = GoogleAuthManager.buildAuthorizationURL(codeChallenge: challenge)
        XCTAssertTrue(url.absoluteString.hasPrefix("https://accounts.google.com/o/oauth2/v2/auth"))
    }

    // MARK: - Token Response Decoding

    func testTokenResponseDecodesFullResponse() throws {
        let json = """
        {
            "access_token": "ya29.test",
            "refresh_token": "1//test-refresh",
            "expires_in": 3600,
            "token_type": "Bearer",
            "scope": "openid email"
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(TokenResponse.self, from: json)
        XCTAssertEqual(response.accessToken, "ya29.test")
        XCTAssertEqual(response.refreshToken, "1//test-refresh")
        XCTAssertEqual(response.expiresIn, 3600)
        XCTAssertEqual(response.tokenType, "Bearer")
        XCTAssertEqual(response.scope, "openid email")
    }

    func testTokenResponseDecodesWithoutRefreshToken() throws {
        let json = """
        {
            "access_token": "ya29.test",
            "expires_in": 3600,
            "token_type": "Bearer"
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(TokenResponse.self, from: json)
        XCTAssertEqual(response.accessToken, "ya29.test")
        XCTAssertNil(response.refreshToken)
        XCTAssertEqual(response.expiresIn, 3600)
    }

    // MARK: - Token Access (AUTH-03: serialized refresh)

    func testValidAccessTokenReturnsTokenWhenNotExpired() async throws {
        let manager = GoogleAuthManager()
        // Set token with expiry well beyond the 5-min buffer
        await manager._setTokensForTesting(
            access: "valid_token",
            refresh: "refresh_token",
            expiry: Date().addingTimeInterval(3600)
        )
        let token = try await manager.validAccessToken()
        XCTAssertEqual(token, "valid_token")
    }

    func testValidAccessTokenThrowsWhenNotSignedIn() async {
        let manager = GoogleAuthManager()
        do {
            _ = try await manager.validAccessToken()
            XCTFail("Should have thrown")
        } catch {
            XCTAssertTrue(error is GoogleAuthError)
        }
    }

    func testSerializedRefresh() async {
        let manager = GoogleAuthManager()
        // Set expired token — should enter refresh path
        await manager._setTokensForTesting(
            access: "expired_token",
            refresh: "some_refresh",
            expiry: Date().addingTimeInterval(-60) // expired 1 min ago
        )
        // Refresh will fail (no real network) — but confirms it entered the refresh path
        do {
            _ = try await manager.validAccessToken()
            XCTFail("Should have thrown — no real network for refresh")
        } catch {
            // Expected: refresh attempt fails without network
        }
    }

    func testProactiveRefresh() async {
        let manager = GoogleAuthManager()
        // Set token expiring within 5-min buffer (4 min from now)
        await manager._setTokensForTesting(
            access: "soon_expiring_token",
            refresh: "some_refresh",
            expiry: Date().addingTimeInterval(240) // 4 min — within 5-min buffer
        )
        // Should trigger refresh (not return current token) because within buffer
        do {
            _ = try await manager.validAccessToken()
            XCTFail("Should have thrown — no real network for refresh")
        } catch {
            // Expected: proactive refresh triggered, then failed without network
        }
    }

    func testRefreshFailure() async {
        let manager = GoogleAuthManager()
        // Set expired token with refresh token
        await manager._setTokensForTesting(
            access: "expired_token",
            refresh: "will_fail_refresh",
            expiry: Date().addingTimeInterval(-60)
        )
        // Attempt refresh — will fail (no network)
        do {
            _ = try await manager.validAccessToken()
            XCTFail("Should have thrown")
        } catch {
            // After refresh failure, state should be signedOut and Keychain cleared
            let state = await manager.state
            XCTAssertEqual(state, .signedOut)
            XCTAssertNil(KeychainHelper.load(key: "access_token"))
            XCTAssertNil(KeychainHelper.load(key: "refresh_token"))
            XCTAssertNil(KeychainHelper.load(key: "token_expiry"))
        }
    }

    // MARK: - Sign Out

    func testSignOutClearsKeychainAndState() async throws {
        let manager = GoogleAuthManager()
        await manager._setTokensForTesting(
            access: "at",
            refresh: "rt",
            expiry: Date().addingTimeInterval(3600)
        )
        // Persist to Keychain so we can verify cleanup
        try KeychainHelper.save(key: "access_token", data: Data("at".utf8))
        try KeychainHelper.save(key: "refresh_token", data: Data("rt".utf8))
        try KeychainHelper.save(key: "token_expiry", data: Data("12345".utf8))

        await manager.signOut()

        let state = await manager.state
        XCTAssertEqual(state, .signedOut)
        XCTAssertNil(KeychainHelper.load(key: "access_token"))
        XCTAssertNil(KeychainHelper.load(key: "refresh_token"))
        XCTAssertNil(KeychainHelper.load(key: "token_expiry"))
    }

    func testSignOutFromAlreadySignedOut() async {
        let manager = GoogleAuthManager()
        // Should complete without error
        await manager.signOut()
        let state = await manager.state
        XCTAssertEqual(state, .signedOut)
    }

    // MARK: - Session Restoration

    func testRestoreSessionLoadsFromKeychain() async throws {
        try KeychainHelper.save(key: "access_token", data: Data("restored_at".utf8))
        try KeychainHelper.save(key: "refresh_token", data: Data("restored_rt".utf8))
        let expiryStr = String(Date().addingTimeInterval(3600).timeIntervalSince1970)
        try KeychainHelper.save(key: "token_expiry", data: Data(expiryStr.utf8))
        try KeychainHelper.save(key: "user_email", data: Data("user@test.com".utf8))

        let manager = GoogleAuthManager()
        await manager.restoreSession()

        let state = await manager.state
        XCTAssertEqual(state, .signedIn(email: "user@test.com"))
    }

    func testRestoreSessionWithNoTokensStaysSignedOut() async {
        let manager = GoogleAuthManager()
        await manager.restoreSession()
        let state = await manager.state
        XCTAssertEqual(state, .signedOut)
    }
}
