import SwiftUI

struct GoogleAccountSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Section("Google Account") {
            switch appState.googleAuthState {
            case .signedOut:
                signedOutView
            case .signingIn:
                signingInView
            case .signedIn(let email):
                signedInView(email: email)
            case .error(let message):
                errorView(message: message)
            }
        }
    }

    // MARK: - State Views

    private var signedOutView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sign in to sync your Google Calendar and auto-record meetings.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Sign in with Google") {
                appState.signInToGoogle()
            }
        }
    }

    private var signingInView: some View {
        HStack {
            ProgressView()
                .controlSize(.small)
            Text("Signing in...")
                .foregroundStyle(.secondary)
        }
    }

    private func signedInView(email: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Connected as \(email)")
            }

            Button("Sign Out") {
                appState.signOutFromGoogle()
            }
        }
    }

    private func errorView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)

            Button("Try Again") {
                appState.signInToGoogle()
            }
        }
    }
}
