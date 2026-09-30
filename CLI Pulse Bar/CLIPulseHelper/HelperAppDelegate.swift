import AppKit
import CLIPulseCore
import Darwin
import os

final class HelperAppDelegate: NSObject, NSApplicationDelegate {
    private var daemon: HelperDaemon?
    private let logger = Logger(subsystem: "yyh.CLI-Pulse.helper", category: "lifecycle")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let runtimeEnvironment = CLIPulseRuntimeEnvironment.current
        guard runtimeEnvironment.allowsLoginItemHelperStartup else {
            logger.fault(
                "Blocked helper startup outside the exact production helper runtime"
            )
            Darwin._exit(78)
        }

        // v1.55: Settings › Privacy's Claude keychain switches live in the
        // app's defaults, which this process cannot read; `PrivacySettings`
        // here read this process's own, which nothing writes, so the switches
        // never reached the collectors this helper runs. Follow the app's copy
        // in the app group instead, before any collector runs.
        PrivacySettings.shared.followAppCopy(in: UserDefaults(suiteName: HelperIPC.suiteName))

        let daemon = HelperDaemon(
            runtimeEnvironment: runtimeEnvironment
        )
        self.daemon = daemon
        logger.info("CLIPulseHelper launched")
        HelperIPC.writeStatus(HelperIPC.Status(state: .running, helperVersion: "1.0.0"))
        HelperIPC.postStartNotification()
        daemon.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard let daemon else { return }
        logger.info("CLIPulseHelper terminating")
        daemon.stop()
        HelperIPC.writeStatus(HelperIPC.Status(state: .idle, helperVersion: "1.0.0"))
    }
}
