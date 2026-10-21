// Modified by Jon Hammant, 2026, as part of Porthole (see NOTICE).
import Foundation

/// The TEST ONLY variables that bear on who gets in or what pairing needs
/// (docs/home-pairing-plan.md §4.3). Each is read where it acts, and honoured only on a test host
/// (DoorPolicy.isTestHost: one that does not advertise and is not a .app's executable): any process
/// of this user can start Porthole.app's own executable with an environment, and it then runs with
/// Porthole's Screen Recording and Accessibility grants. Anywhere else each one set is ignored with one
/// line, here. The encoder's variables let nobody in and are not among them;
/// PORTHOLE_TEST_REMOTE_DIR is read, and refused, where the identity store is chosen (the CLI and the
/// app).
enum TestHooks {
    static let doorAndPairing = [
        "PORTHOLE_TEST_SERVICE_TYPE", "PORTHOLE_TEST_SWAP_FAIL", "PORTHOLE_TEST_PEER_TO_PEER_INTERFACE", "PORTHOLE_TEST_ORIGIN",
        "PORTHOLE_TEST_REMOTE_ORIGIN",
        "PORTHOLE_TEST_LOOPBACK", "PORTHOLE_TEST_BACKOFF_SECONDS", "PORTHOLE_TEST_PAIRING_TTL", "PORTHOLE_TEST_NO_ROUTER",
        "PORTHOLE_TEST_CABLE_INTERFACE", "PORTHOLE_TEST_LOCKED", "PORTHOLE_TEST_ASK_FROM_THIS_MAC", "PORTHOLE_TEST_ASK_QUIET",
        // The device gate's (DeviceGate): a floor above "0" refuses devices.
        "PORTHOLE_TEST_MIN_DEVICE_VERSION", "PORTHOLE_TEST_GOODBYE",
    ]

    /// One line for each such variable set on a host that does not honour them; nothing on a test
    /// host, and nothing when none is set (so every existing output stays as it was).
    static func reportIgnored(testHost: Bool, environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard !testHost else { return }
        for name in doorAndPairing where !(environment[name] ?? "").isEmpty {
            print("\(name) ignored: only a test host takes it (one that does not advertise and is not Porthole.app itself).")
        }
    }
}
