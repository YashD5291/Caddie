import XCTest
@testable import Caddie

@MainActor
final class AudioDeviceManagerTests: XCTestCase {

    private var manager: AudioDeviceManager!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: AudioDeviceManager.userDefaultsKey)
        manager = AudioDeviceManager()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AudioDeviceManager.userDefaultsKey)
        manager = nil
        super.tearDown()
    }

    // MARK: - Device Enumeration

    func testRefreshPopulatesInputDevices() {
        manager.refresh()

        // Any Mac with a built-in mic should have at least 1 input device
        XCTAssertFalse(manager.availableInputDevices.isEmpty, "Expected at least one input device")

        // Each device should have a non-empty id (UID) and name
        for device in manager.availableInputDevices {
            XCTAssertFalse(device.id.isEmpty, "Device UID should not be empty")
            XCTAssertFalse(device.name.isEmpty, "Device name should not be empty")
        }
    }

    // MARK: - Persistence

    func testSelectionPersistsToUserDefaults() {
        // Setting a UID should write to UserDefaults
        manager.selectedDeviceUID = "test-device-uid"
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: AudioDeviceManager.userDefaultsKey),
            "test-device-uid"
        )

        // Setting to nil should remove the key
        manager.selectedDeviceUID = nil
        XCTAssertNil(UserDefaults.standard.string(forKey: AudioDeviceManager.userDefaultsKey))
    }

    func testInitializeLoadsPersistedSelection() {
        // First, populate the device list to find a real device UID
        manager.refresh()
        guard let realDevice = manager.availableInputDevices.first else {
            XCTFail("No input devices available for test")
            return
        }

        // Persist a known UID
        UserDefaults.standard.set(realDevice.id, forKey: AudioDeviceManager.userDefaultsKey)

        // Create a fresh manager and initialize
        let freshManager = AudioDeviceManager()
        freshManager.initialize()

        XCTAssertEqual(freshManager.selectedDeviceUID, realDevice.id)
        XCTAssertFalse(freshManager.isUsingFallback)
    }

    // MARK: - Fallback

    func testMissingDeviceFallsBackToDefault() {
        // Store a UID that doesn't match any real device
        UserDefaults.standard.set("nonexistent-device-uid", forKey: AudioDeviceManager.userDefaultsKey)

        let freshManager = AudioDeviceManager()
        freshManager.initialize()

        XCTAssertTrue(freshManager.isUsingFallback, "Should flag fallback when stored device is missing")
        XCTAssertNil(freshManager.selectedDeviceUID, "Should clear selection when device is missing")
        XCTAssertNil(
            UserDefaults.standard.string(forKey: AudioDeviceManager.userDefaultsKey),
            "Should remove invalid UID from UserDefaults"
        )
    }

    // MARK: - Filtering

    func testFiltersCaddieAggregateDevices() {
        manager.refresh()

        // Verify no device in the list has a UID starting with "com.caddie.systemTap."
        for device in manager.availableInputDevices {
            XCTAssertFalse(
                device.id.hasPrefix("com.caddie.systemTap."),
                "Caddie aggregate device should be filtered: \(device.id)"
            )
        }
    }

    // MARK: - Resolution

    func testResolvedDeviceIDReturnsNilWhenNoSelection() {
        XCTAssertNil(manager.selectedDeviceUID)
        XCTAssertNil(manager.resolvedDeviceID())
    }
}
