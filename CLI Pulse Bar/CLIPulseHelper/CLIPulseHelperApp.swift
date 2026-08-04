import SwiftUI
import CLIPulseCore
import Darwin

/// Headless Login Item that runs the helper daemon.
/// Registered via SMAppService.loginItem(identifier:) from the main app.
/// Runs outside the app sandbox — can access keychain, browser cookies, run ps, etc.
@main
struct CLIPulseHelperApp: App {
    @NSApplicationDelegateAdaptor(HelperAppDelegate.self) var delegate

    init() {
        guard CLIPulseRuntimeEnvironment.current
            .allowsLoginItemHelperStartup
        else {
            Darwin._exit(78)
        }
    }

    var body: some Scene {
        // No UI — headless background process
        Settings { EmptyView() }
    }
}
