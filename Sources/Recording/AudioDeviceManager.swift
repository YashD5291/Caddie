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

    /// Name of the macOS system default input device, cached as observable state so
    /// the toolbar can label "System Default" with the actual device (e.g.
    /// "Default · MacBook Pro Microphone") without a live CoreAudio query on every
    /// render. Refreshed on device-list and default-input changes.
    private(set) var systemDefaultInputName: String?

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
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []
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
        systemDefaultInputName = coreAudio.defaultInputDevice?.name
        logger.info("Refreshed input devices: \(self.availableInputDevices.count) available")
    }

    /// Resolve selected UID to current AudioObjectID. Returns nil if using system default.
    func resolvedDeviceID() -> AudioObjectID? {
        guard let uid = selectedDeviceUID else { return nil }
        return AudioDevice.lookup(by: uid)?.id
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
        // Device list changing (plug/unplug) affects the available device set and
        // possibly the resolved system default.
        let listObserver = NotificationCenter.default.addObserver(
            forName: .deviceListChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.refresh()
            self.validateSelection()
        }

        // The user switching the system default input (without the device list
        // changing) must update the cached `systemDefaultInputName` so the toolbar
        // label doesn't go stale.
        let defaultObserver = NotificationCenter.default.addObserver(
            forName: .defaultInputDeviceChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.refresh()
        }

        observers = [listObserver, defaultObserver]
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
