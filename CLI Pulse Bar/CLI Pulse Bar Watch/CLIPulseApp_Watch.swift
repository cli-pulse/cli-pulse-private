import SwiftUI
import CLIPulseCore

@main
struct CLIPulseWatchApp: App {
    @StateObject private var appState = WatchAppState()
    @StateObject private var sessionManager = WatchSessionManager.shared

    init() {
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
                    sessionManager.activate()
                    appState.applyFallbackData(from: sessionManager)
                }
        }
    }
}
