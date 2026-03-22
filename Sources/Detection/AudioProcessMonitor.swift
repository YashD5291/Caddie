import AppKit
import CoreAudio
import Foundation
import os

final class AudioProcessMonitor: DetectionMonitor {

    var onSignal: ((DetectionSignal) -> Void)?

    private let logger = Logger(subsystem: "com.caddie.app", category: "AudioProcessMonitor")
    private var timer: Timer?
    private var lastKnownPIDs: Set<pid_t> = []

    func start() {
        logger.info("Starting audio process monitor")
        poll()
        let t = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self else {
                CaddieLogger.detection.warning("AudioProcessMonitor deallocated -- poll timer orphaned")
                return
            }
            self.poll()
        }
        t.tolerance = 1.0
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        logger.info("Stopping audio process monitor")
        timer?.invalidate()
        timer = nil
        lastKnownPIDs = []
    }

    // MARK: - Private

    private func poll() {
        let currentPIDs = getAudioProcessPIDs()
        var activeMeetingPIDs: Set<pid_t> = []

        for pid in currentPIDs {
            guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
            let processName = app.localizedName ?? ""
            guard let appName = MeetingPatterns.appForProcess(processName) else { continue }

            activeMeetingPIDs.insert(pid)

            if !lastKnownPIDs.contains(pid) {
                logger.info("Meeting app started using audio: \(appName) (PID \(pid))")
                onSignal?(DetectionSignal(
                    source: .audioProcess,
                    appName: appName,
                    processId: pid,
                    windowTitle: nil,
                    calendarEvent: nil,
                    isActive: true
                ))
            }
        }

        // Detect apps that stopped using audio
        for pid in lastKnownPIDs {
            if !activeMeetingPIDs.contains(pid) {
                let processName = NSRunningApplication(processIdentifier: pid)?.localizedName
                let appName = processName.flatMap { MeetingPatterns.appForProcess($0) } ?? "Unknown"
                logger.info("Meeting app stopped using audio: \(appName) (PID \(pid))")
                onSignal?(DetectionSignal(
                    source: .audioProcess,
                    appName: appName,
                    processId: pid,
                    windowTitle: nil,
                    calendarEvent: nil,
                    isActive: false
                ))
            }
        }

        lastKnownPIDs = activeMeetingPIDs
    }

    private func getAudioProcessPIDs() -> [pid_t] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )

        guard status == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var objectIDs = [AudioObjectID](repeating: 0, count: count)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &objectIDs
        )

        guard status == noErr else { return [] }

        var pids: [pid_t] = []
        for objectID in objectIDs {
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)

            let pidStatus = AudioObjectGetPropertyData(
                objectID,
                &pidAddress,
                0,
                nil,
                &pidSize,
                &pid
            )

            if pidStatus == noErr, pid > 0 {
                pids.append(pid)
            }
        }

        return pids
    }
}
