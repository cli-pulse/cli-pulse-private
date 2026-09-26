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
/// it from the app group. It never reads the Keychain (`HelperConfig.pairedDeviceId`).
public enum ThisMacPairing {
    public enum State: Equatable, Sendable {
        /// Nothing for Settings to add: signed out, the account itself is not
        /// paired (Settings already shows the pairing flow), this build or
        /// runtime cannot pair a Mac, or this Mac syncs as its own device.
        case notNeeded
        /// The account is paired, but this Mac holds no pairing record for it:
        /// never paired here, or its helper is paired to another account. The
        /// helper uploads nothing for this account.
        ///
        /// A record whose Keychain secret cannot be read does not count: that
        /// read also fails while the login keychain is locked, and offering to
        /// pair for that would add a second device row for this Mac. A secret
        /// that is really gone is rare, and shows as the helper running
        /// without a sync.
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
    ///   - pairedDeviceId: the device this Mac's helper is paired as when that
    ///     pairing belongs to the signed-in account (`HelperConfig.pairedDeviceId`),
    ///     else nil.
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
    /// that would leave a second device row behind.
    ///
    /// A helper from before `Status.errorCode` — every helper released so far,
    /// and one that keeps running after the app updates in place — stored only
    /// text. That text carries the server's body verbatim, and the body is
    /// judged by the same rule the token comes from
    /// (`HelperSyncFailure.legacyTextReportsDeviceGone`), so the Macs broken
    /// today are offered the repair without waiting for their helper to restart.
    private static func helperReportsDeviceGone(
        _ status: HelperIPC.Status?,
        pairedDeviceId: String
    ) -> Bool {
        guard let status, status.state == .error else { return false }
        let deviceGone: Bool
        if let code = status.errorCode {
            deviceGone = HelperSyncFailure.httpParts(of: code)?.1 == .deviceNotPaired
        } else {
            deviceGone = HelperSyncFailure.legacyTextReportsDeviceGone(status.error)
        }
        guard deviceGone else { return false }
        return !isAboutAReplacedDevice(status, pairedDeviceId: pairedDeviceId)
    }

    /// Whether `status` was written for a device other than the one this Mac is
    /// paired as for the signed-in account: the helper can still write one for
    /// the old credentials if it read them just before the app re-paired. Such
    /// a status says nothing about the current pairing.
    ///
    /// A status without a device (a helper from before `Status.deviceId`), or a
    /// Mac without a pairing for this account, cannot say, so it counts; the
    /// app clears the status when it pairs (`HelperIPC.clearStatus()`).
    public static func isAboutAReplacedDevice(
        _ status: HelperIPC.Status,
        pairedDeviceId: String?
    ) -> Bool {
        guard let statusDevice = status.deviceId,
              let pairedDeviceId, !pairedDeviceId.isEmpty
        else { return false }
        return statusDevice != pairedDeviceId
    }
}
