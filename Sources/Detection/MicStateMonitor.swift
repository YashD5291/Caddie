import Foundation
import SimplyCoreAudio
import os

final class MicStateMonitor: DetectionMonitor {

    var onSignal: ((DetectionSignal) -> Void)?

    private let logger = Logger(subsystem: "com.caddie.app", category: "MicStateMonitor")
    private let coreAudio = SimplyCoreAudio()
    private var lastState: Bool?
    private var observer: NSObjectProtocol?

    func start() {
        logger.info("Starting mic state monitor")

        // Check initial state
        let initialState = isDefaultInputRunning()
        lastState = initialState
        emitSignal(isActive: initialState)

        // Subscribe to changes
        observer = NotificationCenter.default.addObserver(
            forName: .deviceIsRunningSomewhereDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleStateChange()
        }
    }

    func stop() {
        logger.info("Stopping mic state monitor")
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        lastState = nil
    }

    // MARK: - Private

    private func handleStateChange() {
        let currentState = isDefaultInputRunning()
        guard currentState != lastState else { return }
        lastState = currentState
        logger.info("Mic state changed: \(currentState ? "active" : "inactive")")
        emitSignal(isActive: currentState)
    }

    private func isDefaultInputRunning() -> Bool {
        coreAudio.defaultInputDevice?.isRunningSomewhere ?? false
    }

    private func emitSignal(isActive: Bool) {
        onSignal?(DetectionSignal(
            source: .micState,
            appName: nil,
            processId: nil,
            windowTitle: nil,
            calendarEvent: nil,
            isActive: isActive
        ))
    }
}
