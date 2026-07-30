import Foundation

/// Shared persistence contract for the screen-recording feature gate, so the
/// Phase 21 Settings toggle (writer) and `AppState` (reader) can never drift.
///
/// Co-located with the engine it gates (`ScreenRecorder`): the value decides
/// whether a capture is ever attempted, not how one behaves.
enum ScreenRecordingSettings {
    /// UserDefaults key for whether meetings are also captured as video.
    static let enabledKey = "screenRecordingEnabled"

    /// VID-01: OFF by default — video is opt-in.
    static let defaultEnabled = false

    /// Whether screen recording is enabled for new meetings.
    ///
    /// Reads via `object(forKey:)` rather than `bool(forKey:)` deliberately: `bool`
    /// collapses "never set" and "explicitly false" into the same `false`, which
    /// would make the default un-overridable if it ever changed. Keeping the two
    /// distinguishable is what lets "absent key" mean "opt-in never happened".
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }
}
