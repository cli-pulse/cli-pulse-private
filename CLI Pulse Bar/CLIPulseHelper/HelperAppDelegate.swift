import AppKit
import CLIPulseCore
import Darwin
import os

final class HelperAppDelegate: NSObject, NSApplicationDelegate {
    private var daemon: HelperDaemon?
    /// Held, shared, for as long as this helper runs (`HelperCachePurge`).
    private var cacheLock: HelperCachePurge.HeldLock?
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

        // 1.58: the app may be emptying this helper's cache folder for it right
        // now (`HelperCachePurge`, for a helper that background sync never
        // starts). Wait until it is done before anything opens the URL cache,
        // then keep the lock for as long as this helper runs, so an app that
        // launches meanwhile leaves the folder alone.
        cacheLock = HelperCachePurge.waitForTheAppThenHoldTheLock()
        if cacheLock == nil {
            logger.error(
                "Helper cache lock not taken: the app held it past the limit, or its file could not be opened"
            )
        }

        // 1.57: this helper's own URL cache kept the collectors' requests with
        // their tokens up to 1.56 (its Cache.db is not the app's). Empty it and
        // the cookie jar once, before the first collector runs; the collectors
        // now use a session that keeps nothing (`CredentialedURLSession`).
        CredentialedURLSession.purgeLegacyStorageIfNeeded()

        let daemon = HelperDaemon(
            runtimeEnvironment: runtimeEnvironment
        )
        self.daemon = daemon
        logger.info("CLIPulseHelper launched")
        HelperIPC.writeStatus(HelperDaemon.status(state: .running))
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
        HelperIPC.writeStatus(HelperDaemon.status(state: .idle))
    }
}
