# Phase 14: Google Authentication - Research

**Researched:** 2026-03-24
**Domain:** OAuth2 authentication for macOS desktop app (Google provider)
**Confidence:** HIGH

## Summary

Phase 14 implements Google OAuth2 authentication using zero new SPM dependencies. The stack is ASWebAuthenticationSession (AuthenticationServices framework) for browser-based login, Security framework for Keychain token storage, and URLSession for token exchange/refresh/revocation. The app is unsandboxed, so no entitlement changes are needed for network access.

The critical design constraint is serialized token refresh through a Swift actor (`GoogleAuthManager`). When multiple callers discover an expired token simultaneously, only one refresh request fires. This prevents the `invalid_grant` race condition that would silently break calendar access. PKCE (Proof Key for Code Exchange) is required for all native app OAuth flows.

**Primary recommendation:** Build GoogleAuthManager as a Swift actor with three Keychain items (access_token, refresh_token, expiry_timestamp), ASWebAuthenticationSession for sign-in, and a continuation-based refresh gate that serializes concurrent refresh attempts into exactly one network call.

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| AUTH-01 | User can sign into Google via ASWebAuthenticationSession + PKCE during onboarding | ASWebAuthenticationSession API verified for macOS 14.2+. PKCE code_verifier/challenge generation pattern documented. Google token exchange endpoint confirmed. Custom URI scheme redirect supported for desktop apps. |
| AUTH-02 | OAuth tokens stored securely in macOS Keychain | Security framework SecItemAdd/CopyMatching/Update/Delete patterns documented. kSecClassGenericPassword with kSecAttrService + kSecAttrAccount. Three items: access_token, refresh_token, token_expiry. |
| AUTH-03 | Token refresh is serialized through a single actor (no race conditions) | Swift actor pattern with optional `Task<String, Error>` as in-flight refresh gate. Concurrent callers await the same task. Proactive refresh 5 minutes before expiry. |
| AUTH-04 | User can sign out and re-authenticate from Settings | Google revocation endpoint `https://oauth2.googleapis.com/revoke?token={token}`. Keychain delete on sign out. Settings UI section with connected email display. |
</phase_requirements>

## Standard Stack

### Core

| Framework | Version | Purpose | Why Standard |
|-----------|---------|---------|--------------|
| AuthenticationServices | System (macOS 14.2+) | ASWebAuthenticationSession for OAuth2 browser flow | Apple's first-party API for browser-based auth. Handles browser lifecycle, session isolation, redirect capture. No third-party dependency needed. |
| Security | System | Keychain CRUD for OAuth tokens | Native macOS Keychain via SecItemAdd/CopyMatching/Update/Delete. The correct place for credentials -- encrypted at rest, access-controlled. |
| Foundation (URLSession) | System | Token exchange, refresh, revocation HTTP calls | Standard HTTP client. Three POST endpoints total. No API client library warranted. |
| CryptoKit | System | SHA256 for PKCE code_challenge | Generates S256 code challenge from code verifier. Already available on macOS 14.2+. |

### Supporting

| Framework | Version | Purpose | When to Use |
|-----------|---------|---------|-------------|
| os (Logger) | System | CaddieLogger.calendar category | Log auth state changes, token refresh events, errors |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| ASWebAuthenticationSession | AppAuth-iOS v2.0.0 | AppAuth adds Obj-C bridging, OIDC discovery, 3+ transitive deps for ~150 LOC of manual flow |
| Security framework | KeychainAccess / SwiftKeychainWrapper | Wrapper library for 4 function calls (~30 LOC). Not worth the dependency. |
| CryptoKit | CommonCrypto | CryptoKit is the modern API, cleaner Swift interface |

### What NOT to Add

No new SPM packages. Everything uses system frameworks already shipping with macOS 14.2+.

## Architecture Patterns

### File Organization

```
Sources/
  Calendar/                          <-- NEW directory
    GoogleAuthManager.swift          <-- Actor: OAuth2 + PKCE + token lifecycle
    GoogleAuthError.swift            <-- Error enum for auth failures
  Utilities/
    KeychainHelper.swift             <-- NEW: thin Security framework wrapper
  UI/
    Settings/
      SettingsView.swift             <-- MODIFIED: add Google account section
      GoogleAccountSection.swift     <-- NEW: sign-in/out UI + connected email
  App/
    AppState.swift                   <-- MODIFIED: add auth manager + auth state
```

### Pattern 1: Swift Actor for Serialized Token Refresh (AUTH-03)

**What:** GoogleAuthManager as a Swift `actor` that owns all mutable token state and serializes refresh attempts.

**When to use:** Any time multiple concurrent callers might discover an expired token simultaneously.

**Why:** Swift actors guarantee serialized access to mutable state. A stored `Task<String, Error>?` property ensures that when a refresh is in-flight, subsequent callers await the same task instead of firing a second refresh request.

```swift
// Pattern: Actor-based serialized token refresh
actor GoogleAuthManager {
    enum AuthState: Sendable {
        case signedOut
        case signingIn
        case signedIn(email: String)
        case error(String)
    }

    private(set) var state: AuthState = .signedOut

    // In-flight refresh gate -- concurrent callers await the same task
    private var refreshTask: Task<String, Error>?

    // Cached token state (loaded from Keychain on init)
    private var accessToken: String?
    private var refreshToken: String?
    private var tokenExpiry: Date?

    /// Returns a valid access token. Refreshes transparently if expired.
    /// Concurrent calls during refresh await the same single refresh request.
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
            let newToken = try await exchangeRefreshToken(refresh)
            self.accessToken = newToken.accessToken
            self.tokenExpiry = newToken.expiry
            try KeychainHelper.save(key: "access_token", data: newToken.accessToken.data(using: .utf8)!)
            try KeychainHelper.save(key: "token_expiry", data: String(newToken.expiry.timeIntervalSince1970).data(using: .utf8)!)
            return newToken.accessToken
        }
        refreshTask = task
        return try await task.value
    }
}
```

**Source:** Pattern derived from [Google OAuth2 token refresh race condition](https://github.com/thephpleague/oauth2-client/issues/593) and Swift actor documentation.

### Pattern 2: KeychainHelper as Utility Enum

**What:** Stateless enum with static CRUD methods wrapping Security framework.

**When to use:** Follow existing Caddie convention (Formatters, Permissions are enums with static methods).

```swift
enum KeychainHelper {
    private static let service = "com.caddie.app.oauth"

    static func save(key: String, data: Data) throws {
        let query: [String: AnyObject] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service as AnyObject,
            kSecAttrAccount as String: key as AnyObject,
            kSecValueData as String: data as AnyObject,
        ]
        SecItemDelete(query as CFDictionary) // Remove existing before add
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    static func load(key: String) -> Data? {
        let query: [String: AnyObject] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service as AnyObject,
            kSecAttrAccount as String: key as AnyObject,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: kCFBooleanTrue,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(key: String) {
        let query: [String: AnyObject] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service as AnyObject,
            kSecAttrAccount as String: key as AnyObject,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func deleteAll() {
        for key in ["access_token", "refresh_token", "token_expiry"] {
            delete(key: key)
        }
    }
}
```

**Source:** [Keychain Examples in Swift](https://www.advancedswift.com/secure-private-data-keychain-swift/)

### Pattern 3: ASWebAuthenticationSession with PKCE

**What:** Browser-based OAuth login using Apple's first-party auth session API.

**When to use:** AUTH-01 sign-in flow.

```swift
import AuthenticationServices
import CryptoKit

// PKCE generation
func generateCodeVerifier() -> String {
    var buffer = [UInt8](repeating: 0, count: 32)
    _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
    return Data(buffer).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func generateCodeChallenge(from verifier: String) -> String {
    let data = Data(verifier.utf8)
    let hash = SHA256.hash(data: data)
    return Data(hash).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

// ASWebAuthenticationSession usage
func signIn(presenting window: NSWindow) async throws {
    let verifier = generateCodeVerifier()
    let challenge = generateCodeChallenge(from: verifier)

    var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    components.queryItems = [
        URLQueryItem(name: "client_id", value: GoogleOAuthConfig.clientID),
        URLQueryItem(name: "redirect_uri", value: GoogleOAuthConfig.redirectURI),
        URLQueryItem(name: "response_type", value: "code"),
        URLQueryItem(name: "scope", value: "openid email https://www.googleapis.com/auth/calendar.events.readonly"),
        URLQueryItem(name: "code_challenge", value: challenge),
        URLQueryItem(name: "code_challenge_method", value: "S256"),
        URLQueryItem(name: "access_type", value: "offline"), // Request refresh token
    ]

    let authURL = components.url!

    // callbackURLScheme is the scheme portion only (no "://")
    let callbackScheme = GoogleOAuthConfig.callbackScheme

    let code = try await withCheckedThrowingContinuation { continuation in
        let session = ASWebAuthenticationSession(
            url: authURL,
            callbackURLScheme: callbackScheme
        ) { callbackURL, error in
            if let error {
                continuation.resume(throwing: error)
                return
            }
            guard let url = callbackURL,
                  let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "code" })?.value else {
                continuation.resume(throwing: GoogleAuthError.noAuthCode)
                return
            }
            continuation.resume(returning: code)
        }
        // presentationContextProvider on macOS
        session.presentationContextProvider = /* class conforming to ASWebAuthenticationPresentationContextProviding */
        session.prefersEphemeralWebBrowserSession = true
        session.start()
    }

    // Exchange code for tokens
    let tokens = try await exchangeCodeForTokens(code: code, verifier: verifier)
    // Store in Keychain + fetch user email
}
```

**Source:** [ASWebAuthenticationSession docs](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession), [Google OAuth2 for Native Apps](https://developers.google.com/identity/protocols/oauth2/native-app)

### Anti-Patterns to Avoid

- **Storing tokens in UserDefaults:** Plaintext on disk, any process can read. Use Keychain.
- **Multiple concurrent refresh requests:** Causes `invalid_grant` when Google rotates refresh tokens. Serialize through actor.
- **Waiting for 401 to refresh:** Proactively refresh 5 minutes before expiry to avoid failed API calls.
- **Using GoogleSignIn SDK or AppAuth-iOS:** Heavy dependencies for a single-provider flow that is ~150 LOC manually.
- **Using `client_secret` in the app:** Desktop app client IDs on Google Cloud Console do NOT have a client_secret. The token exchange uses only `client_id` + `code_verifier`.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Browser-based OAuth | Custom WKWebView or local HTTP server | ASWebAuthenticationSession | Handles session isolation, browser lifecycle, redirect capture. Apple's blessed approach. |
| Secure credential storage | File-based encryption, UserDefaults | macOS Keychain (Security framework) | OS-level encryption at rest, per-app access control, survives reinstalls |
| PKCE SHA256 challenge | Manual CommonCrypto calls | CryptoKit SHA256 | One-liner, Swift-native, no bridging header |
| HTTP client for token exchange | Custom URLSession wrapper | Direct URLSession.data(for:) | Three endpoints total, standard POST with form body. No abstraction needed. |

## Common Pitfalls

### Pitfall 1: Token Refresh Race Condition

**What goes wrong:** Two concurrent callers discover an expired token, both attempt refresh. Google may rotate the refresh token on first call, causing second call to fail with `invalid_grant`. App loses all tokens silently.
**Why it happens:** Laptop wake from sleep -- token expired hours ago, multiple subsystems discover simultaneously.
**How to avoid:** Actor-based refresh with `Task<String, Error>?` gate. Only one in-flight refresh at a time. Others await.
**Warning signs:** `invalid_grant` in logs, calendar sync silently stops working.

### Pitfall 2: Keychain Stale Tokens After Reinstall

**What goes wrong:** macOS Keychain persists across app delete/reinstall. Old tokens found on fresh install, app skips sign-in, but tokens are revoked.
**Why it happens:** Keychain is designed to persist credentials. This is a feature for passwords but a bug for OAuth tokens.
**How to avoid:** On first launch (UserDefaults flag `hasCompletedOnboarding` already exists), validate stored tokens with a lightweight API call (userinfo endpoint). If invalid, clear Keychain and show sign-in.
**Warning signs:** App shows "Connected" but API calls return 401.

### Pitfall 3: Missing `access_type=offline` Parameter

**What goes wrong:** Google only returns a refresh_token on the FIRST authorization if `access_type=offline` is set. Without it, no refresh_token is returned, and the user must re-authenticate every hour.
**Why it happens:** The `access_type` parameter defaults to `online` which only returns an access_token.
**How to avoid:** Always include `access_type=offline` in the authorization URL. Also include `prompt=consent` if you need to force a refresh_token reissue (e.g., after revocation).
**Warning signs:** Token exchange response has no `refresh_token` field.

### Pitfall 4: PresentationContextProvider on macOS

**What goes wrong:** ASWebAuthenticationSession requires a `presentationContextProvider` that returns an `NSWindow`. In SwiftUI, getting a window reference is non-trivial. If nil or wrong, the auth sheet may not appear.
**Why it happens:** SwiftUI abstracts away NSWindow. The session needs a concrete window to present from.
**How to avoid:** Use `NSApplication.shared.keyWindow` or pass window reference from the SwiftUI view via `NSViewRepresentable`. Alternatively, create a helper class conforming to `ASWebAuthenticationPresentationContextProviding` that returns `NSApplication.shared.keyWindow ?? NSWindow()`.
**Warning signs:** `start()` returns false, no browser opens.

### Pitfall 5: Custom URI Scheme Not Registered in Info.plist

**What goes wrong:** ASWebAuthenticationSession callback never fires. Browser redirects to the custom scheme but macOS does not route it back to the app.
**Why it happens:** The custom URI scheme must be registered in Info.plist under `CFBundleURLTypes`.
**How to avoid:** Add the URL scheme to Info.plist. The scheme is the reversed Google client ID (e.g., `com.googleusercontent.apps.1234567890-abcdef`).
**Warning signs:** Browser shows "Safari can't open the page" after Google redirect.

## Code Examples

### Google OAuth Configuration

```swift
/// Static configuration for Google OAuth2.
/// Client ID comes from Google Cloud Console > Desktop Application type.
enum GoogleOAuthConfig {
    /// From Google Cloud Console. Desktop app type -- no client_secret.
    static let clientID = "YOUR_CLIENT_ID.apps.googleusercontent.com"

    /// Reversed client ID as custom URI scheme
    static let callbackScheme = "com.googleusercontent.apps.YOUR_CLIENT_ID"

    /// Full redirect URI registered in Google Cloud Console
    static let redirectURI = "\(callbackScheme):/oauth2redirect/google"

    /// Scopes: OpenID for email, calendar read-only for events
    static let scopes = "openid email https://www.googleapis.com/auth/calendar.events.readonly"

    // MARK: - Endpoints
    static let authorizationURL = "https://accounts.google.com/o/oauth2/v2/auth"
    static let tokenURL = "https://oauth2.googleapis.com/token"
    static let revocationURL = "https://oauth2.googleapis.com/revoke"
    static let userinfoURL = "https://openidconnect.googleapis.com/v1/userinfo"
}
```

### Token Exchange HTTP POST

```swift
/// Exchange authorization code for access_token + refresh_token.
/// Google desktop app clients do NOT use client_secret.
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

struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?  // Only present on first auth or when prompt=consent
    let expiresIn: Int         // Seconds until expiry (typically 3600)
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
```

### Token Refresh HTTP POST

```swift
/// Refresh expired access token using stored refresh token.
/// No client_secret needed for desktop app client IDs.
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
        // Refresh failed -- token may be revoked
        throw GoogleAuthError.refreshFailed
    }
    return try JSONDecoder().decode(TokenResponse.self, from: data)
}
```

### Token Revocation (Sign Out)

```swift
/// Revoke token server-side, then clear local Keychain.
func signOut() async {
    if let token = accessToken ?? refreshToken {
        var request = URLRequest(url: URL(string: "\(GoogleOAuthConfig.revocationURL)?token=\(token)")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        _ = try? await URLSession.shared.data(for: request) // Best-effort
    }

    // Clear local state regardless of revocation success
    accessToken = nil
    refreshToken = nil
    tokenExpiry = nil
    KeychainHelper.deleteAll()
    state = .signedOut
}
```

### Fetching User Email

```swift
/// Fetch user email from Google userinfo endpoint after sign-in.
/// Requires 'openid email' scopes.
private func fetchUserEmail(accessToken: String) async throws -> String {
    var request = URLRequest(url: URL(string: GoogleOAuthConfig.userinfoURL)!)
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        throw GoogleAuthError.userInfoFailed
    }

    struct UserInfo: Decodable {
        let email: String
        let emailVerified: Bool?

        enum CodingKeys: String, CodingKey {
            case email
            case emailVerified = "email_verified"
        }
    }

    let info = try JSONDecoder().decode(UserInfo.self, from: data)
    return info.email
}
```

### Info.plist URL Scheme Registration

```xml
<!-- Add to Resources/Info.plist inside <dict> -->
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>com.googleusercontent.apps.YOUR_CLIENT_ID</string>
        </array>
        <key>CFBundleURLName</key>
        <string>Google OAuth Redirect</string>
    </dict>
</array>
```

## Google OAuth2 Endpoint Reference

| Endpoint | URL | Method | Purpose |
|----------|-----|--------|---------|
| Authorization | `https://accounts.google.com/o/oauth2/v2/auth` | GET (browser) | Open login page with PKCE params |
| Token Exchange | `https://oauth2.googleapis.com/token` | POST | Exchange auth code for tokens |
| Token Refresh | `https://oauth2.googleapis.com/token` | POST | Refresh expired access token |
| Revocation | `https://oauth2.googleapis.com/revoke` | POST | Revoke token on sign-out |
| User Info | `https://openidconnect.googleapis.com/v1/userinfo` | GET | Fetch signed-in user's email |

**Key parameters:**
- Authorization URL: `client_id`, `redirect_uri`, `response_type=code`, `scope`, `code_challenge`, `code_challenge_method=S256`, `access_type=offline`
- Token exchange: `client_id`, `code`, `code_verifier`, `grant_type=authorization_code`, `redirect_uri`
- Token refresh: `client_id`, `refresh_token`, `grant_type=refresh_token`
- Revocation: `token={access_or_refresh_token}`

**No `client_secret` needed:** Google Desktop Application client types do not have a client_secret. Token exchange uses PKCE code_verifier instead.

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| OOB (manual copy/paste) | No longer supported by Google | 2022 | Must use redirect-based flow |
| Custom URI scheme (iOS/Android) | Platform SDKs (GIS, Sign-In) | 2022-2025 | Desktop apps unaffected -- custom schemes still work |
| Loopback HTTP server | ASWebAuthenticationSession | macOS 10.15+ | ASWebAuthenticationSession is simpler, no local HTTP server needed |
| GoogleSignIn SDK | ASWebAuthenticationSession + URLSession | - | Zero dependency approach for single-provider flow |

**Deprecated/outdated:**
- OOB flow: Fully removed by Google
- Custom URI schemes for Android: Disabled by default, must opt in via Advanced Settings
- Loopback for iOS: Deprecated (but desktop apps still supported)

## Open Questions

1. **Google Cloud Console Setup**
   - What we know: A "Desktop Application" client ID is needed from Google Cloud Console
   - What's unclear: The actual client ID value -- must be created manually by the developer
   - Recommendation: Create a configuration file or environment variable for the client ID. Document the Cloud Console setup steps as a prerequisite.

2. **OAuth Consent Screen Verification**
   - What we know: `calendar.events.readonly` is a "sensitive" scope requiring verification for >100 users
   - What's unclear: Whether Caddie will be distributed to >100 users
   - Recommendation: Use "testing" mode during development (up to 100 test users). Defer verification to distribution phase. This does NOT block Phase 14 implementation.

3. **prefersEphemeralWebBrowserSession**
   - What we know: Setting this to `true` prevents session cookies from persisting, meaning the user must re-enter credentials each time
   - What's unclear: Whether users prefer being remembered (false) or privacy-first (true)
   - Recommendation: Set to `true` for first implementation (privacy-consistent with Caddie's ethos). Can be toggled later if users request "remember me" behavior.

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | XCTest (built into Xcode 26.2) |
| Config file | project.yml (CaddieTests target) |
| Quick run command | `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -destination 'platform=macOS' -only-testing:CaddieTests` |
| Full suite command | `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -destination 'platform=macOS'` |

### Phase Requirements to Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| AUTH-01 | PKCE code_verifier/challenge generation produces valid Base64URL strings of correct length | unit | `-only-testing:CaddieTests/GoogleAuthManagerTests/testPKCEGeneration` | Wave 0 |
| AUTH-01 | Authorization URL contains all required query parameters | unit | `-only-testing:CaddieTests/GoogleAuthManagerTests/testAuthURLConstruction` | Wave 0 |
| AUTH-01 | Token exchange decodes valid Google response into TokenResponse | unit | `-only-testing:CaddieTests/GoogleAuthManagerTests/testTokenResponseDecoding` | Wave 0 |
| AUTH-02 | KeychainHelper save/load/delete round-trips data correctly | unit | `-only-testing:CaddieTests/KeychainHelperTests/testSaveLoadDelete` | Wave 0 |
| AUTH-02 | KeychainHelper handles errSecItemNotFound gracefully (returns nil) | unit | `-only-testing:CaddieTests/KeychainHelperTests/testLoadMissing` | Wave 0 |
| AUTH-02 | KeychainHelper save overwrites existing item | unit | `-only-testing:CaddieTests/KeychainHelperTests/testSaveOverwrite` | Wave 0 |
| AUTH-03 | Concurrent validAccessToken() calls produce exactly one refresh request | unit | `-only-testing:CaddieTests/GoogleAuthManagerTests/testSerializedRefresh` | Wave 0 |
| AUTH-03 | Proactive refresh triggers 5 min before expiry | unit | `-only-testing:CaddieTests/GoogleAuthManagerTests/testProactiveRefresh` | Wave 0 |
| AUTH-03 | Refresh failure with invalid_grant transitions to signedOut | unit | `-only-testing:CaddieTests/GoogleAuthManagerTests/testRefreshFailure` | Wave 0 |
| AUTH-04 | Sign-out clears all Keychain items | unit | `-only-testing:CaddieTests/GoogleAuthManagerTests/testSignOutClearsKeychain` | Wave 0 |
| AUTH-04 | Sign-out transitions state to signedOut | unit | `-only-testing:CaddieTests/GoogleAuthManagerTests/testSignOutState` | Wave 0 |
| AUTH-01 | Full browser sign-in flow with real Google account | manual-only | N/A -- requires browser interaction + Google account | N/A |
| AUTH-04 | Re-authentication after sign-out works | manual-only | N/A -- requires browser interaction | N/A |

### Sampling Rate

- **Per task commit:** Quick run of new test file only
- **Per wave merge:** Full suite (when build issue resolved)
- **Phase gate:** All AUTH test cases green before `/gsd:verify-work`

### Wave 0 Gaps

- [ ] `Tests/KeychainHelperTests.swift` -- covers AUTH-02 (Keychain CRUD)
- [ ] `Tests/GoogleAuthManagerTests.swift` -- covers AUTH-01, AUTH-03, AUTH-04 (PKCE, serialized refresh, sign-out)

Note: The ASWebAuthenticationSession browser flow itself (AUTH-01 full flow) is manual-only -- it requires real browser interaction with Google's consent screen. Unit tests cover everything up to and after the browser step (URL construction, token decoding, token refresh, Keychain operations).

## Project Constraints (from CLAUDE.md)

- **Zero new SPM dependencies** -- use system frameworks only (AuthenticationServices, Security, CryptoKit, Foundation)
- **Swift 6.0** with `SWIFT_STRICT_CONCURRENCY: complete` -- actor for GoogleAuthManager is required, not optional
- **macOS 14.2+** deployment target -- all APIs used are available
- **Privacy-first** -- tokens in Keychain, not UserDefaults. No data leaves device except OAuth flow itself.
- **Naming conventions** -- `*Manager.swift` pattern (GoogleAuthManager), utility enums for helpers (KeychainHelper)
- **Error handling** -- custom error enums conforming to `Error & LocalizedError` (GoogleAuthError)
- **Logging** -- use CaddieLogger categories (add `.calendar` or reuse `.app`)
- **TDD** -- write tests first. KeychainHelperTests and GoogleAuthManagerTests before implementation.
- **Build system** -- XcodeGen (`project.yml`). Info.plist changes go in `Resources/Info.plist`. No entitlement changes needed (app is unsandboxed).
- **Final classes** -- GoogleAuthManager is an actor (implicitly final). KeychainHelper is an enum.
- **No dead code** -- do not add CalendarScheduler, GoogleCalendarService, or any Phase 15+ components. This phase is auth ONLY.

## Sources

### Primary (HIGH confidence)
- [Google OAuth2 for Desktop/Native Apps](https://developers.google.com/identity/protocols/oauth2/native-app) -- Authorization URL, token exchange, refresh, PKCE requirements, redirect methods
- [Google Loopback Migration Guide](https://developers.google.com/identity/protocols/oauth2/resources/loopback-migration) -- Confirms desktop apps NOT affected by deprecations
- [Google OpenID Connect](https://developers.google.com/identity/openid-connect/openid-connect) -- Userinfo endpoint, email scope, response format
- [Google Custom URI Scheme Restrictions Blog](https://developers.googleblog.com/en/improving-user-safety-in-oauth-flows-through-new-oauth-custom-uri-scheme-restrictions/) -- Only Android/Chrome affected, NOT macOS desktop
- [ASWebAuthenticationSession](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession) -- Apple's browser-based auth API
- [Keychain Examples in Swift](https://www.advancedswift.com/secure-private-data-keychain-swift/) -- SecItemAdd/CopyMatching/Update/Delete patterns

### Secondary (MEDIUM confidence)
- [Using ASWebAuthenticationSession with SwiftUI](https://www.andyibanez.com/posts/using-aswebauthenticationaession-swiftui/) -- SwiftUI integration, presentationContextProvider, macOS NSWindow anchor
- [ASWebAuthenticationSession macOS Forum Thread](https://developer.apple.com/forums/thread/704545) -- macOS-specific behavior confirmed
- [OAuth2 PKCE in Swift](https://medium.com/geekculture/implement-oauth2-pkce-in-swift-9bdb58873957) -- PKCE generation patterns

### Tertiary (LOW confidence)
- None -- all findings verified against primary or secondary sources.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- all system frameworks, well-documented APIs, verified against Google and Apple official docs
- Architecture: HIGH -- actor-based serialization is proven Swift concurrency pattern, GoogleAuthManager design from milestone research validated
- Pitfalls: HIGH -- race condition documented in multiple OAuth2 libraries, Keychain persistence is well-known, PKCE requirements verified against Google docs
- Code examples: HIGH -- all endpoint URLs, parameters, and response formats verified against Google official documentation

**Research date:** 2026-03-24
**Valid until:** 2026-04-24 (Google OAuth2 endpoints are stable; ASWebAuthenticationSession API is stable)
