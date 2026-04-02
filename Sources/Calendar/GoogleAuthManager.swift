import Foundation
import AppKit
import CryptoKit
import os

actor GoogleAuthManager {
    enum AuthState: Sendable, Equatable {
        case signedOut
        case signingIn
        case signedIn(email: String)
        case error(String)
    }

    // MARK: - Public State

    private(set) var state: AuthState = .signedOut

    // MARK: - Token State (private, persisted to Keychain)

    private var accessToken: String?
    private var refreshToken: String?
    private var tokenExpiry: Date?

    // MARK: - Refresh Gate (AUTH-03: serialized refresh)

    private var refreshTask: Task<String, Error>?

    private let logger = Logger(subsystem: CaddieLogger.subsystem, category: "Auth")

    // MARK: - PKCE (AUTH-01)

    static func generateCodeVerifier() -> String {
        var buffer = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        return Data(buffer).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Authorization URL

    static func buildAuthorizationURL(codeChallenge: String) -> URL {
        var components = URLComponents(string: GoogleOAuthConfig.authorizationURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: GoogleOAuthConfig.clientID),
            URLQueryItem(name: "redirect_uri", value: GoogleOAuthConfig.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: GoogleOAuthConfig.scopes),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
        ]
        return components.url!
    }

    // MARK: - Browser Redirect Callback

    /// Pending continuation for the browser-based OAuth redirect.
    /// Set by signIn(), resumed by handleRedirectURL().
    private var authContinuation: CheckedContinuation<String, Error>?
    private var pendingVerifier: String?

    /// Called by AppDelegate when macOS delivers the OAuth redirect URL.
    func handleRedirectURL(_ url: URL) {
        guard let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "code" })?.value else {
            authContinuation?.resume(throwing: GoogleAuthError.noAuthCode)
            authContinuation = nil
            return
        }
        authContinuation?.resume(returning: code)
        authContinuation = nil
    }

    // MARK: - Sign In (AUTH-01)

    func signIn() async throws {
        state = .signingIn

        let verifier = Self.generateCodeVerifier()
        let challenge = Self.generateCodeChallenge(from: verifier)
        let authURL = Self.buildAuthorizationURL(codeChallenge: challenge)
        pendingVerifier = verifier

        // Open in user's default browser — uses existing Google session
        let code = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            self.authContinuation = continuation
            Task { @MainActor in
                NSWorkspace.shared.open(authURL)
            }
        }

        // Exchange code for tokens
        let tokens = try await exchangeCodeForTokens(code: code, verifier: verifier)
        try persistTokens(tokens)
        pendingVerifier = nil

        // Fetch user email
        let email = try await fetchUserEmail(accessToken: tokens.accessToken)
        try KeychainHelper.save(key: "user_email", data: Data(email.utf8))
        state = .signedIn(email: email)
        logger.info("Signed in as \(email)")
    }

    // MARK: - Token Access (AUTH-03: serialized refresh)

    func validAccessToken() async throws -> String {
        // 1. If refresh is already in-flight, await it
        if let existing = refreshTask {
            return try await existing.value
        }

        // 2. If token is still valid (5-min buffer), return it
        if let token = accessToken,
           let expiry = tokenExpiry,
           Date() < expiry.addingTimeInterval(-300) {
            return token
        }

        // 3. Start a new refresh task
        let task = Task<String, Error> {
            defer { refreshTask = nil }
            guard let refresh = refreshToken else {
                throw GoogleAuthError.notSignedIn
            }
            let newTokens = try await exchangeRefreshToken(refresh)
            self.accessToken = newTokens.accessToken
            let newExpiry = Date().addingTimeInterval(Double(newTokens.expiresIn))
            self.tokenExpiry = newExpiry
            try KeychainHelper.save(key: "access_token", data: Data(newTokens.accessToken.utf8))
            try KeychainHelper.save(key: "token_expiry", data: Data(String(newExpiry.timeIntervalSince1970).utf8))
            logger.info("Token refreshed successfully")
            return newTokens.accessToken
        }
        refreshTask = task
        return try await task.value
    }

    // MARK: - Sign Out (AUTH-04)

    func signOut() async {
        // Best-effort server-side revocation
        if let token = accessToken ?? refreshToken,
           var components = URLComponents(string: GoogleOAuthConfig.revocationURL) {
            components.queryItems = [URLQueryItem(name: "token", value: token)]
            if let url = components.url {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                _ = try? await URLSession.shared.data(for: request)
            }
        }

        accessToken = nil
        refreshToken = nil
        tokenExpiry = nil
        KeychainHelper.deleteAll()
        KeychainHelper.delete(key: "user_email")
        state = .signedOut
        logger.info("Signed out and cleared tokens")
    }

    // MARK: - Session Restoration

    func restoreSession() {
        guard let accessData = KeychainHelper.load(key: "access_token"),
              let refreshData = KeychainHelper.load(key: "refresh_token"),
              let expiryData = KeychainHelper.load(key: "token_expiry"),
              let accessStr = String(data: accessData, encoding: .utf8),
              let refreshStr = String(data: refreshData, encoding: .utf8),
              let expiryStr = String(data: expiryData, encoding: .utf8),
              let expiryInterval = Double(expiryStr) else {
            state = .signedOut
            return
        }

        accessToken = accessStr
        refreshToken = refreshStr
        tokenExpiry = Date(timeIntervalSince1970: expiryInterval)

        if let emailData = KeychainHelper.load(key: "user_email"),
           let email = String(data: emailData, encoding: .utf8) {
            state = .signedIn(email: email)
        } else {
            state = .signedIn(email: "Google Account")
        }

        logger.info("Session restored from Keychain")
    }

    // MARK: - Testing Support

    #if DEBUG
    func _setTokensForTesting(access: String, refresh: String, expiry: Date) {
        self.accessToken = access
        self.refreshToken = refresh
        self.tokenExpiry = expiry
    }
    #endif

    // MARK: - Private Helpers

    private func exchangeCodeForTokens(code: String, verifier: String) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: GoogleOAuthConfig.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "client_id": GoogleOAuthConfig.clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": GoogleOAuthConfig.redirectURI,
        ]
        request.httpBody = body.map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw GoogleAuthError.tokenExchangeFailed
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func exchangeRefreshToken(_ refreshToken: String) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: GoogleOAuthConfig.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "client_id": GoogleOAuthConfig.clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]
        request.httpBody = body.map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            // Refresh failed — assume token revoked, force re-auth
            accessToken = nil
            self.refreshToken = nil
            tokenExpiry = nil
            KeychainHelper.deleteAll()
            state = .signedOut
            throw GoogleAuthError.refreshFailed
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func fetchUserEmail(accessToken: String) async throws -> String {
        var request = URLRequest(url: URL(string: GoogleOAuthConfig.userinfoURL)!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw GoogleAuthError.userInfoFailed
        }

        struct UserInfo: Decodable {
            let email: String
        }
        return try JSONDecoder().decode(UserInfo.self, from: data).email
    }

    private func persistTokens(_ tokens: TokenResponse) throws {
        try KeychainHelper.save(key: "access_token", data: Data(tokens.accessToken.utf8))
        if let refresh = tokens.refreshToken {
            try KeychainHelper.save(key: "refresh_token", data: Data(refresh.utf8))
        }
        let expiry = Date().addingTimeInterval(Double(tokens.expiresIn))
        try KeychainHelper.save(key: "token_expiry", data: Data(String(expiry.timeIntervalSince1970).utf8))

        accessToken = tokens.accessToken
        refreshToken = tokens.refreshToken ?? refreshToken
        tokenExpiry = expiry
    }
}

// MARK: - Token Response

struct TokenResponse: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
    let tokenType: String
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
        case scope
    }
}

