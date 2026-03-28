import Foundation

enum GoogleOAuthConfig {
    /// Desktop app client ID from Google Cloud Console.
    /// Replace with actual client ID after creating OAuth credentials.
    static let clientID = "736932798207-9j5uipki4somq90inf7ich0dvei5dvul.apps.googleusercontent.com"

    /// Reversed client ID as custom URI scheme for OAuth redirect.
    static let callbackScheme = "com.googleusercontent.apps.736932798207-9j5uipki4somq90inf7ich0dvei5dvul"

    /// Full redirect URI registered in Google Cloud Console.
    static let redirectURI = "\(callbackScheme):/oauth2redirect/google"

    /// OpenID + email for user identity, calendar read-only for event access.
    static let scopes = "openid email https://www.googleapis.com/auth/calendar.events.readonly"

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
