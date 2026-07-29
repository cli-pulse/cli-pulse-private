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
