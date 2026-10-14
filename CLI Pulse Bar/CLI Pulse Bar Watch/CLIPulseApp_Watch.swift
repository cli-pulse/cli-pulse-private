import SwiftUI
import CLIPulseCore

@main
struct CLIPulseWatchApp: App {
    @StateObject private var appState = WatchAppState()
    @StateObject private var sessionManager = WatchSessionManager.shared

    init() {
        #if DEBUG
        // An App Store screenshot launch (WatchScreenshotLaunch): wrong
        // arguments stop here with a marked error rather than photograph a
        // normal launch under a page's name.
        _ = WatchScreenshotLaunch.screenOrExit()
        #endif
        // 1.57: up to 1.56 the URL cache could keep the account's requests with
        // its token in Cache.db. Empty it and the cookie jar once, before
        // `WatchAppState` (made with the first body) sends anything; `APIClient`
        // now uses a configuration that keeps nothing (`CredentialedURLSession`).
        CredentialedURLSession.purgeLegacyStorageIfNeeded()
        SentryLogger.start(platform: .watchOS)
        // The iPhone's display currency as the last context delivered it, so
        // the costs this Watch persisted do not show in dollars until
        // WatchConnectivity activates and hands that context back.
        CurrencyConverter.shared.restoreAdopted()
    }

    var body: some Scene {
        WindowGroup {
            WatchMainView()
                .environmentObject(appState)
                .environmentObject(sessionManager)
                // Dynamic Type: the glance text (mostly `.caption`/`.headline`
                // styles) scales with the user's watch text-size setting, but
                // is bounded to the largest *standard* size — the accessibility
                // sizes would shatter the dense ring/card layouts. Tune further
                // on-device if needed.
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .onAppear {
                    #if DEBUG
                    // A screenshot capture shows Demo and talks to no one:
                    // no WatchConnectivity, so no phone's data either.
                    if WatchScreenshotLaunch.activeScreen != nil { return }
                    #endif
                    sessionManager.activate()
                    appState.applyFallbackData(from: sessionManager)
                }
        }
    }
}
