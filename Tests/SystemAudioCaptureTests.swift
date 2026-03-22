import XCTest
@testable import Caddie

@MainActor
final class SystemAudioCaptureTests: XCTestCase {

    func testCleanupStaleAggregateDevicesDoesNotCrash() {
        // On a clean system with no stale Caddie devices, cleanup should complete silently
        SystemAudioCapture.cleanupStaleAggregateDevices()
    }

    func testCleanupStaleAggregateDevicesIsStaticMethod() {
        // Verify the method is callable as a static method without an instance
        let cleanup: () -> Void = SystemAudioCapture.cleanupStaleAggregateDevices
        cleanup()
    }
}
