import Foundation

enum GoogleAuthError: Error, LocalizedError {
    case notSignedIn
    case noAuthCode
    case tokenExchangeFailed
    case refreshFailed
    case userInfoFailed
    case keychainError(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Not signed into Google. Please sign in from Settings."
        case .noAuthCode:
            return "Failed to receive authorization code from Google."
        case .tokenExchangeFailed:
            return "Failed to exchange authorization code for tokens."
        case .refreshFailed:
            return "Failed to refresh access token. Please sign in again."
        case .userInfoFailed:
            return "Failed to fetch Google account email."
        case .keychainError(let detail):
            return "Keychain error: \(detail)"
        }
    }
}
