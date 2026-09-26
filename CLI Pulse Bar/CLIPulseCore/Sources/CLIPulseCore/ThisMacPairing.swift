import Foundation

/// Whether THIS Mac has to be paired while the ACCOUNT already counts as paired.
///
/// `AuthState.isPaired` is `profiles.paired`: it turns true when any device of
/// the account registers a helper, and `unregister_desktop_helper` keeps it true
/// while one device remains. Settings offered "Set Up Cloud Sync" only while it
/// was false, which left two kinds of Mac with no way to pair:
///
/// - A Mac whose own device row is gone, or whose secret no longer matches. Its
///   helper's syncs fail with P0001 "Device not found or unauthorized", and
///   Settings › Advanced told the user to set up cloud sync again in Settings —
///   where nothing offered it.
/// - A second Mac signed in to an account another device already paired, or a
///   Mac whose helper is still paired to a different account. It never showed a
///   pairing screen, and its sessions and alerts never left it: only the helper
///   uploads them, and the helper has no credentials for this account.
///
/// Pairing again works while the account is already paired: `pairing_codes` RLS
/// is `auth.uid() = user_id` only, and `register_helper` inserts a new device
/// row and sets `paired = true` without reading it.
///
/// Pure so every state is unit-tested; `AppState.refreshThisMacPairing()` feeds
/// it from the app group and the Keychain.
public enum ThisMacPairing {
    public enum State: Equatable, Sendable {
        /// Nothing for Settings to add: signed out, the account itself is not
        /// paired (Settings already shows the pairing flow), this build or
        /// runtime cannot pair a Mac, or this Mac syncs as its own device.
        case notNeeded
        /// The account is paired, but this Mac holds no helper credentials for
        /// it: never paired here, paired to another account, or the Keychain
        /// secret is gone. The helper uploads nothing for this account.
        case notSetUp
        /// This Mac's helper credentials are for the signed-in account, and the
        /// server said the device is gone or its secret no longer matches.
        /// Retrying never succeeds; only pairing again does.
        case deviceRemoved
    }

    /// - Parameters:
    ///   - canPairThisMac: the runtime allows helper registration and this is
    ///     not Demo mode. False in the QA runtime, where the pairing button is
    ///     a no-op and the app group belongs to production.
    ///   - pairedDeviceId: the device of this Mac's helper credentials when they
    ///     belong to the signed-in account (`HelperConfig.loadIfMatches`), else nil.
    ///   - helperStatus: the helper's last written status (`HelperIPC.readStatus()`).
    public static func state(
        isAuthenticated: Bool,
        isPaired: Bool,
        canPairThisMac: Bool,
        pairedDeviceId: String?,
        helperStatus: HelperIPC.Status?
    ) -> State {
        guard isAuthenticated, isPaired, canPairThisMac else { return .notNeeded }
        guard let pairedDeviceId, !pairedDeviceId.isEmpty else { return .notSetUp }
        return helperReportsDeviceGone(helperStatus, pairedDeviceId: pairedDeviceId)
            ? .deviceRemoved
            : .notNeeded
    }

    /// Only the server's "Device not found or unauthorized" counts. A network
    /// failure, a timeout or any other HTTP error says nothing about pairing and
    /// clears itself on the next good sync, so it must not offer to pair again —
    /// that would leave a second device row behind. A helper from before
    /// `Status.errorCode` wrote English text only; it is not parsed, so such a
    /// helper simply shows no repair until it is relaunched with this build.
    private static func helperReportsDeviceGone(
        _ status: HelperIPC.Status?,
        pairedDeviceId: String
    ) -> Bool {
        guard
            let status,
            status.state == .error,
            let code = status.errorCode,
            let (_, reason) = HelperSyncFailure.httpParts(of: code),
            reason == .deviceNotPaired
        else {
            return false
        }
        // A status about a device this Mac has since replaced is stale: the
        // helper can still write one for the old credentials if it read them
        // just before the app re-paired. A status without a device (a helper
        // from before `Status.deviceId`) cannot say, so it is believed; the app
        // clears it when it pairs (`HelperIPC.clearStatus()`).
        if let statusDevice = status.deviceId, statusDevice != pairedDeviceId {
            return false
        }
        return true
    }
}
