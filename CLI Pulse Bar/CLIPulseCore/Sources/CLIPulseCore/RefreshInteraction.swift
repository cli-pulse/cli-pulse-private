import Foundation

/// Who started the refresh that is running: a person (the refresh button, the
/// menu bar's refresh, ⌘R) or the app on its own (the timer, the helper's sync
/// notice, launch, a settings change).
///
/// 1.60 (N2): a read that may put a macOS dialog in front of the user — the
/// Keychain prompt for a browser's "Safe Storage" item — happens only on a
/// refresh a person started. Everything else uses the no-dialog read and, when
/// that is not enough, waits for the next manual refresh.
///
/// Bound per task (`DataRefreshManager.requestRefresh(_:using:)`), so it
/// reaches the collectors that refresh runs, through task groups and actor
/// calls, and nothing else. Unbound means `.background`: the LoginItem helper
/// and every other caller get the safe answer without having to say so.
public enum RefreshInteraction: Sendable, Equatable {
    case background
    case userInitiated

    @TaskLocal public static var current: RefreshInteraction = .background
}
