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

        // v1.55: say what this helper does with Claude Code's keychain item
        // now, and again whenever the app changes a switch or asks at its
        // launch (after removing the last report), so Settings › Privacy does
        // not wait a whole sync interval for a cycle to say it, and never
        // takes a report an earlier helper left for this one's.
        daemon.reportClaudeKeychainAccess(announce: true)
        for name in [HelperInputs.didChangeNotificationName, HelperPrivacyInputs.reportRequestNotificationName] {
            DistributedNotificationCenter.default().addObserver(
                self, selector: #selector(reportClaudeKeychainAccess(_:)), name: name, object: nil
            )
        }
    }

    @objc private func reportClaudeKeychainAccess(_ notification: Notification) {
        daemon?.reportClaudeKeychainAccess(announce: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard let daemon else { return }
        logger.info("CLIPulseHelper terminating")
        daemon.stop()
        HelperIPC.writeStatus(HelperIPC.Status(state: .idle, helperVersion: "1.0.0"))
    }
}
