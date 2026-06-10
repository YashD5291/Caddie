import Foundation

enum GoogleOAuthConfig {
    /// Desktop app client ID from Google Cloud Console.
    /// Real value lives in the gitignored GoogleOAuthSecrets.swift.
    static let clientID = GoogleOAuthSecrets.clientID

    /// Desktop app client secret from Google Cloud Console.
    /// Real value lives in the gitignored GoogleOAuthSecrets.swift.
    static let clientSecret = GoogleOAuthSecrets.clientSecret

    /// Reversed client ID as custom URI scheme for OAuth redirect.
    /// Derived from `clientID` so there is a single source of truth: strip the
    /// `.apps.googleusercontent.com` suffix and prefix with `com.googleusercontent.apps.`.
    static let callbackScheme: String = "com.googleusercontent.apps."
        + GoogleOAuthSecrets.clientID.replacingOccurrences(
            of: ".apps.googleusercontent.com", with: "")

    /// Full redirect URI registered in Google Cloud Console.
    static let redirectURI = "\(callbackScheme):/oauth2redirect/google"

    /// OpenID + email for user identity, calendar read-only for listing calendars + events.
    static let scopes = "openid email https://www.googleapis.com/auth/calendar.readonly"

    // MARK: - Endpoints

    /// Browser-based authorization (PKCE flow).
    static let authorizationURL = "https://accounts.google.com/o/oauth2/v2/auth"

    /// Token exchange and refresh.
    static let tokenURL = "https://oauth2.googleapis.com/token"

    /// Token revocation on sign-out.
    static let revocationURL = "https://oauth2.googleapis.com/revoke"

    /// Fetch signed-in user's email address.
    static let userinfoURL = "https://openidconnect.googleapis.com/v1/userinfo"
}
