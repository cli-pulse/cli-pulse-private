import Foundation

/// The line under Settings › Advanced › Background Sync: a dot and a few words
/// from the helper's last status (`HelperIPC.readStatus()`).
///
/// In CLIPulseCore so it is tested; the app target has no unit tests.
///
/// The helper cannot tell whether it syncs the signed-in account. With no
/// pairing it only collects locally, and a helper paired to another account
/// syncs that one; both write `.running` with a `lastSync`. On a Mac that
/// `ThisMacPairing` found not set up, that read "Synced just now" in green right
/// below "This Mac isn't paired with your account yet". Helpers already
/// installed keep writing it, so the app is where it has to be decided.
public struct HelperStatusLine: Equatable, Sendable {
    public enum Tone: Equatable, Sendable {
        /// Running (green).
        case good
        /// Running, but not syncing this account (orange).
        case attention
        /// The last sync failed (red).
        case failure
        /// Stopped, or nothing to report (gray).
        case inactive
    }

    /// The dot.
    public let tone: Tone
    public let text: String
    /// Whether `text` describes a failure (drawn in red).
    public let isError: Bool

    public init(tone: Tone, text: String, isError: Bool) {
        self.tone = tone
        self.text = text
        self.isError = isError
    }

    public static func make(
        status: HelperIPC.Status,
        thisMacPairing: ThisMacPairing.State,
        now: Date = Date()
    ) -> HelperStatusLine {
        if thisMacPairing == .notSetUp {
            // The words the account card's badge uses for the same fact.
            return HelperStatusLine(tone: .attention, text: L10n.settings.notPaired, isError: false)
        }
        let tone: Tone
        switch status.state {
        case .running: tone = .good
        case .error: tone = .failure
        case .idle: tone = .inactive
        }
        if let lastSync = status.lastSync {
            let ago = Int(now.timeIntervalSince(lastSync))
            return HelperStatusLine(
                tone: tone,
                text: ago < 60 ? L10n.advanced.syncJustNow : L10n.advanced.syncMinutesAgo(ago / 60),
                isError: false
            )
        }
        if let error = HelperSyncFailure.displayText(code: status.errorCode, storedText: status.error) {
            return HelperStatusLine(tone: tone, text: error, isError: true)
        }
        return HelperStatusLine(
            tone: tone,
            text: status.state == .running ? L10n.advanced.helperRunning : L10n.advanced.helperNotRunning,
            isError: false
        )
    }
}
