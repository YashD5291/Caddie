import AVFoundation
import AppKit
import CoreGraphics

enum PermissionStatus {
    case granted
    case denied
    case undetermined
}

enum Permissions {

    // MARK: - Microphone

    static var microphone: PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .undetermined
        @unknown default:
            return .undetermined
        }
    }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    // MARK: - Screen Recording

    static var screenRecording: PermissionStatus {
        // There is no direct API for screen recording permission.
        // We infer it by checking if CGWindowListCopyWindowInfo returns
        // window names for windows owned by other processes.
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return .undetermined
        }

        let currentPID = ProcessInfo.processInfo.processIdentifier

        for window in windowList {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int32,
                  ownerPID != currentPID else { continue }

            // If we can read another process's window name, we have permission
            if let name = window[kCGWindowName as String] as? String, !name.isEmpty {
                return .granted
            }
        }

        // Could not read any foreign window names — likely denied or undetermined
        return .denied
    }

    // MARK: - Accessibility

    static var accessibility: PermissionStatus {
        AXIsProcessTrusted() ? .granted : .denied
    }

    static func requestAccessibility() {
        // Use string literal instead of kAXTrustedCheckOptionPrompt C global
        // to avoid Swift 6 concurrency-safety error (SR-17471).
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: kCFBooleanTrue!] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
