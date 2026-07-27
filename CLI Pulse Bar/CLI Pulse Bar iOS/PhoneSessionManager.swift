import Foundation
import WatchConnectivity
import CLIPulseCore

/// Manages WatchConnectivity on the iPhone side.
/// Sends auth tokens and dashboard data to the paired Apple Watch.
final class PhoneSessionManager: NSObject, ObservableObject {
    static let shared = PhoneSessionManager()

    @Published var isWatchReachable = false

    /// The AppState whose refreshes we forward to the watch. Set once from
    /// the SwiftUI scene; we hold a weak reference so we never extend its
    /// lifetime.
    weak var appState: AppState?

    /// Auth payload / dashboard snapshot we tried to send before WCSession
    /// activation completed. Replayed in `activationDidCompleteWith`. Without
    /// this, the very first auth event on a cold launch is silently dropped
    /// and the watch never receives credentials until the user re-triggers
    /// auth somehow.
    private var pendingAuthPayload: [String: Any]?
    private var pendingContext: [String: Any]?
    private var pendingLogoutPayload: [String: Any]?
    private var activeIdentity: WatchSessionIdentity?
    private let pendingLock = NSLock()
    private static let epochKey =
        "cli_pulse_phone_watch_session_epoch"

    private override init() {
        super.init()
        // Observe CLIPulseCore notifications eagerly — the observers must be
        // registered BEFORE AppState.init posts `cliPulseDidAuthenticate`
        // during its Task-launched restoreSession. Registering in `activate()`
        // (previously called from `.onAppear`) was losing the very first auth
        // event on cold launch.
        NotificationCenter.default.addObserver(self, selector: #selector(handleDidAuthenticate(_:)),
                                                name: .cliPulseDidAuthenticate, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleDidSignOut(_:)),
                                                name: .cliPulseDidSignOut, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleDidRefresh(_:)),
                                                name: .cliPulseDidRefresh, object: nil)
    }

    /// Activate the WCSession if supported (iPhone only).
    func activate(appState: AppState? = nil) {
        if let appState { self.appState = appState }
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    @objc private func handleDidAuthenticate(_ notification: Notification) {
        guard let info = notification.userInfo,
              let token = info["access_token"] as? String,
              !token.isEmpty,
              let userID = info["user_id"] as? String,
              !userID.isEmpty
        else {
            return
        }
        sendAuthToWatch(
            accessToken: token,
            refreshToken: info["refresh_token"] as? String,
            userID: userID,
            email: info["email"] as? String ?? "",
            name: info["name"] as? String ?? ""
        )
    }

    @objc private func handleDidSignOut(_ notification: Notification) {
        sendLogoutToWatch(
            userID: notification.userInfo?["user_id"] as? String
        )
    }

    @objc private func handleDidRefresh(_ notification: Notification) {
        // Forward the most recent snapshot to the paired watch. Without this,
        // the watch's `updateApplicationContext` fallback cache stays empty
        // and if the watch's own direct API call fails (token, network) the
        // user sees "Pull to refresh" forever.
        guard let state = (notification.object as? AppState) ?? appState else { return }
        Task { @MainActor in
            self.sendDashboardToWatch(
                userID: state.userId,
                dashboard: state.dashboard,
                providers: state.providers,
                sessions: state.sessions,
                alerts: state.alerts,
                devices: state.devices
            )
        }
    }

    // MARK: - Send Auth to Watch

    /// Transfer auth tokens to the watch after successful login.
    /// Uses `transferUserInfo` for guaranteed delivery (queued, survives app exit).
    func sendAuthToWatch(
        accessToken: String,
        refreshToken: String?,
        userID: String,
        email: String,
        name: String
    ) {
        guard WCSession.isSupported() else { return }
        pendingLock.lock()
        guard let identity = nextIdentityLocked(
            userID: userID
        ) else {
            pendingLock.unlock()
            return
        }
        activeIdentity = identity
        var payload: [String: Any] = [
            "cli_pulse_auth": true,
            "access_token": accessToken,
            "user_id": identity.userID,
            "session_epoch": String(identity.epoch),
            "email": email,
            "name": name,
        ]
        if let rt = refreshToken {
            payload["refresh_token"] = rt
        }
        let canSend =
            WCSession.default.activationState == .activated
            && WCSession.default.isPaired
        if canSend {
            pendingAuthPayload = nil
            pendingLogoutPayload = nil
            pendingContext = nil
            pendingLock.unlock()
            WCSession.default.transferUserInfo(payload)
        } else {
            // Queue until activation completes so we don't drop the first
            // auth event on cold launch.
            pendingAuthPayload = payload
            pendingLogoutPayload = nil
            pendingContext = nil
            pendingLock.unlock()
        }
    }

    /// Send logout signal to watch.
    func sendLogoutToWatch(userID: String? = nil) {
        guard WCSession.isSupported() else { return }
        pendingLock.lock()
        let requestedUserID =
            userID?.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        if let current = activeIdentity,
           let requestedUserID,
           !current.matches(
               authenticatedUserID: requestedUserID,
               remoteEpoch: current.epoch
           ) {
            // A delayed logout for a prior phone account must not clear a
            // newer active bridge identity.
            pendingLock.unlock()
            return
        }
        let owner = activeIdentity?.userID ?? requestedUserID ?? ""
        guard let logoutIdentity = nextIdentityLocked(
            userID: owner
        ) else {
            pendingAuthPayload = nil
            pendingContext = nil
            pendingLogoutPayload = nil
            activeIdentity = nil
            pendingLock.unlock()
            return
        }
        activeIdentity = nil
        let payload: [String: Any] = [
            "cli_pulse_logout": true,
            "user_id": logoutIdentity.userID,
            "session_epoch": String(logoutIdentity.epoch),
        ]
        let tombstone: [String: Any] = [
            "cli_pulse_context": true,
            "cli_pulse_logged_out": true,
            "user_id": logoutIdentity.userID,
            "session_epoch": String(logoutIdentity.epoch),
        ]
        pendingAuthPayload = nil
        pendingContext = nil
        let canSend =
            WCSession.default.activationState == .activated
            && WCSession.default.isPaired
        if canSend {
            pendingLogoutPayload = nil
            pendingLock.unlock()
            WCSession.default.transferUserInfo(payload)
            try? WCSession.default.updateApplicationContext(
                tombstone
            )
        } else {
            pendingLogoutPayload = payload
            pendingContext = tombstone
            pendingLock.unlock()
        }
    }

    // MARK: - Send Dashboard Data

    /// Update application context with fresh dashboard data.
    func sendDashboardToWatch(userID: String,
                               dashboard: DashboardSummary?, providers: [ProviderUsage],
                               sessions: [SessionRecord], alerts: [AlertRecord],
                               devices: [DeviceRecord] = []) {
        pendingLock.lock()
        guard
            let identity = activeIdentity,
            identity.matches(
                authenticatedUserID: userID,
                remoteEpoch: identity.epoch
            )
        else {
            pendingLock.unlock()
            return
        }
        pendingLock.unlock()

        let encoder = JSONEncoder()
        var context: [String: Any] = [
            "cli_pulse_context": true,
            "user_id": identity.userID,
            "session_epoch": String(identity.epoch),
            "dashboard_present": dashboard != nil,
        ]

        if let dash = dashboard, let data = try? encoder.encode(dash) {
            context["dashboard"] = data
        }
        if let data = try? encoder.encode(providers) {
            context["providers"] = data
        }
        if let data = try? encoder.encode(sessions) {
            context["sessions"] = data
        }
        if let data = try? encoder.encode(alerts) {
            context["alerts"] = data
        }
        // v1.41 Mobile Machine: trimmed, ≤4 device-health summaries (keeps the
        // WC context small; no control-plane fields cross to the read-only watch).
        let deviceSummaries = WatchDeviceTrim.summaries(from: devices)
        if let data = try? encoder.encode(deviceSummaries) {
            context["devices"] = data
        }

        guard WCSession.isSupported() else { return }
        pendingLock.lock()
        guard activeIdentity == identity else {
            pendingLock.unlock()
            return
        }
        if WCSession.default.activationState == .activated,
           WCSession.default.isPaired {
            pendingLock.unlock()
            try? WCSession.default.updateApplicationContext(context)
        } else {
            // Hold the most recent snapshot and replay on activation.
            pendingContext = context
            pendingLock.unlock()
        }
    }

    /// Flush anything we couldn't send while the WCSession was still
    /// activating. Called from `session(_:activationDidCompleteWith:error:)`.
    fileprivate func flushPending() {
        pendingLock.lock()
        let auth = pendingAuthPayload
        let ctx = pendingContext
        let logout = pendingLogoutPayload
        pendingAuthPayload = nil
        pendingContext = nil
        pendingLogoutPayload = nil
        pendingLock.unlock()

        guard WCSession.default.activationState == .activated,
              WCSession.default.isPaired else { return }

        if let logout {
            WCSession.default.transferUserInfo(logout)
        } else if let auth {
            WCSession.default.transferUserInfo(auth)
        }
        if let ctx {
            try? WCSession.default.updateApplicationContext(ctx)
        }
    }

    /// Returns a process- and relaunch-monotonic epoch while `pendingLock` is
    /// held. Wall-clock milliseconds keep the value moving forward after a
    /// reinstall/restore; the persisted increment handles repeated events in
    /// the same millisecond and local clock rollback.
    private func nextIdentityLocked(
        userID: String
    ) -> WatchSessionIdentity? {
        let normalized = userID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalized.isEmpty else { return nil }

        let defaults = UserDefaults.standard
        let previous = UInt64(
            defaults.string(forKey: Self.epochKey) ?? ""
        ) ?? 0
        guard previous < UInt64.max else { return nil }

        let milliseconds = Date().timeIntervalSince1970 * 1_000
        let clockEpoch: UInt64
        if milliseconds.isFinite,
           milliseconds > 0,
           milliseconds < Double(UInt64.max) {
            clockEpoch = UInt64(milliseconds)
        } else {
            clockEpoch = 1
        }
        let epoch = max(previous + 1, clockEpoch)
        defaults.set(String(epoch), forKey: Self.epochKey)
        return WatchSessionIdentity(
            userID: normalized,
            epoch: epoch
        )
    }
}

// MARK: - WCSessionDelegate

extension PhoneSessionManager: WCSessionDelegate {
    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        DispatchQueue.main.async {
            self.isWatchReachable = session.isReachable
        }
        // Any auth/snapshot that was queued while activation was in flight
        // goes out now. Without this, a cold-launch auth event fires before
        // WCSession is `.activated` and is silently lost.
        flushPending()
    }

    func sessionDidBecomeInactive(_ session: WCSession) { }
    func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate for multi-watch support
        session.activate()
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isWatchReachable = session.isReachable
        }
    }
}
