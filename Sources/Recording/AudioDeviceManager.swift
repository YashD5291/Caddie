import SimplyCoreAudio
import CoreAudio
import Observation
import os

@MainActor
@Observable
final class AudioDeviceManager {

    struct InputDevice: Identifiable, Hashable, Sendable {
        let id: String              // UID (persistent across restarts)
        let name: String
        let manufacturer: String
        let audioDeviceID: AudioObjectID  // Transient runtime ID
    }

    // MARK: - Public State

    private(set) var availableInputDevices: [InputDevice] = []
    private(set) var isUsingFallback: Bool = false

    var selectedDeviceUID: String? {
        didSet { persistSelection() }
    }

    // MARK: - Constants

    static let userDefaultsKey = "selectedInputDeviceUID"

    // MARK: - Private

    private let coreAudio = SimplyCoreAudio()
    // Set in MainActor methods, read from nonisolated deinit. Plain `nonisolated` is
    // rejected on a mutable stored property, so `(unsafe)` is required despite Xcode's
    // misleading "has no effect" warning.
    private nonisolated(unsafe) var observer: NSObjectProtocol?
    private let logger = Logger(subsystem: "com.caddie.app", category: "AudioDeviceManager")

    // MARK: - Lifecycle

    func initialize() {
        refresh()
        loadPersistedSelection()
        validateSelection()
        subscribeToChanges()
    }

    func refresh() {
        availableInputDevices = coreAudio.allInputDevices
            .filter { !($0.uid?.hasPrefix("com.caddie.systemTap.") ?? false) }
            .compactMap { device -> InputDevice? in
                guard let uid = device.uid else { return nil }
                return InputDevice(
                    id: uid,
                    name: device.name,
                    manufacturer: device.manufacturer ?? "Unknown",
                    audioDeviceID: device.id
                )
            }
        logger.info("Refreshed input devices: \(self.availableInputDevices.count) available")
    }

    /// Resolve selected UID to current AudioObjectID. Returns nil if using system default.
    func resolvedDeviceID() -> AudioObjectID? {
        guard let uid = selectedDeviceUID else { return nil }
        return AudioDevice.lookup(by: uid)?.id
    }

    /// Name of the macOS system default input device, used to label the picker
    /// when the user has selected "System Default" so they see what's actually
    /// being recorded from (e.g. "Default · MacBook Pro Microphone").
    var systemDefaultInputName: String? {
        coreAudio.defaultInputDevice?.name
    }

    // MARK: - Private

    private func loadPersistedSelection() {
        selectedDeviceUID = UserDefaults.standard.string(forKey: Self.userDefaultsKey)
    }

    private func validateSelection() {
        guard let uid = selectedDeviceUID else {
            isUsingFallback = false
            return
        }
        if !availableInputDevices.contains(where: { $0.id == uid }) {
            logger.warning("Saved device UID '\(uid)' not found -- falling back to default")
            isUsingFallback = true
            selectedDeviceUID = nil
        } else {
            isUsingFallback = false
        }
    }

    private func persistSelection() {
        if let uid = selectedDeviceUID {
            UserDefaults.standard.set(uid, forKey: Self.userDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.userDefaultsKey)
        }
    }

    private func subscribeToChanges() {
        observer = NotificationCenter.default.addObserver(
            forName: .deviceListChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.refresh()
            self.validateSelection()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
