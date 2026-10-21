// Modified by Jon Hammant, 2026, as part of Porthole (see NOTICE).
import SwiftUI

@main
struct PortholeApp: App {
    /// Only `buildMenu(with:)`: the Mac's menus in the iPad's menu bar on iPadOS 26 (PortholeAppDelegate).
    @UIApplicationDelegateAdaptor(PortholeAppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            // iOS 27.1 on the iPhone Duo: the hinge for the layouts (DuoPostureReader); nothing
            // before iOS 27.1 or on a device without a hinge.
            ContentView()
                .readsDuoPosture()
        }
    }
}
