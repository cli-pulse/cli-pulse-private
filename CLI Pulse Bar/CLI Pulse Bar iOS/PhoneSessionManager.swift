import Foundation
import UIKit
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
    /// 1.61 (B1): the newest access token a refresh here produced, not yet
    /// sent because the session was still activating.
    private var pendingCredentialsPayload: [String: Any]?
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
        NotificationCenter.default.addObserver(self, selector: #selector(handleDisplayCurrencyDidChange(_:)),
                                                name: .displayCurrencyDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleHidePersonalInfoDidChange(_:)),
                                                name: .hidePersonalInfoDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleDidRotateAccessToken(_:)),
                                                name: .cliPulseDidRotateAccessToken, object: nil)
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
            self.forwardSnapshot(of: state)
        }
    }

    /// A new display currency, or a fetched rate, reaches the Watch now rather
    /// than at the next refresh. Posted from any thread (the rate fetch is
    /// async), and at launch before any data has loaded: resending then would
    /// replace the Watch's cached numbers with an empty snapshot, so it waits
    /// for a first refresh.
    @objc private func handleDisplayCurrencyDidChange(_ notification: Notification) {
        Task { @MainActor in
            guard let state = self.appState, state.lastRefresh != nil else { return }
            self.forwardSnapshot(of: state)
        }
    }

    /// The Watch has no "Hide personal information" switch; it follows this
    /// one, so a change reaches it now rather than at the next refresh. The
    /// same wait for a first refresh as the currency above.
    @objc private func handleHidePersonalInfoDidChange(_ notification: Notification) {
        Task { @MainActor in
            guard let state = self.appState, state.lastRefresh != nil else { return }
            self.forwardSnapshot(of: state)
        }
    }

    /// 1.61 (B1): each refresh here rotates the session's tokens. The Watch
    /// renews a session it got from this iPhone only through this iPhone, so
    /// it gets every new access token (never the refresh token, which only
    /// this iPhone spends). Posted from the API client's actor.
    @objc private func handleDidRotateAccessToken(_ notification: Notification) {
        guard let token = notification.userInfo?["access_token"] as? String, !token.isEmpty else { return }
        sendCredentialsToWatch(.accessToken(token, userID: ""))
    }

    @MainActor
    private func forwardSnapshot(of state: AppState) {
        sendDashboardToWatch(
            userID: state.userId,
            dashboard: state.dashboard,
            providers: state.providers,
            sessions: state.sessions,
            alerts: state.alerts,
            devices: state.devices,
            hidePersonalInfo: state.hidePersonalInfo
        )
    }

    // MARK: - Send Auth to Watch

    /// Transfer the access token to the watch after successful login.
    /// Uses `transferUserInfo` for guaranteed delivery (queued, survives app exit).
    ///
    /// 1.61 (B1): never the refresh token. This iPhone is the only side that
    /// refreshes the session; the Watch asks it for each new access token. A
    /// Watch from before 1.61 refreshed with the refresh token sent here and
    /// spent this iPhone's, which signed one of them out.
    func sendAuthToWatch(
        accessToken: String,
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
        let payload: [String: Any] = [
            "cli_pulse_auth": true,
            "access_token": accessToken,
            "user_id": identity.userID,
            "session_epoch": String(identity.epoch),
            "email": email,
            "name": name,
        ]
        let canSend =
            WCSession.default.activationState == .activated
            && WCSession.default.isPaired
        if canSend {
            pendingAuthPayload = nil
            pendingLogoutPayload = nil
            pendingContext = nil
            pendingCredentialsPayload = nil
            pendingLock.unlock()
            WCSession.default.transferUserInfo(payload)
        } else {
            // Queue until activation completes so we don't drop the first
            // auth event on cold launch.
            pendingAuthPayload = payload
            pendingLogoutPayload = nil
            pendingContext = nil
            pendingCredentialsPayload = nil
            pendingLock.unlock()
        }
    }

    /// 1.61 (B1): an answer about this iPhone's session, queued for the Watch
    /// (`WatchCredentialRelay`). An access token goes only under the identity
    /// the Watch got with this iPhone's sign-in, and only if it is that
    /// account's; with no identity (no sign-in was sent), nothing goes.
    func sendCredentialsToWatch(_ answer: WatchCredentialRelay.Answer) {
        guard WCSession.isSupported() else { return }
        pendingLock.lock()
        guard let identity = activeIdentity else {
            pendingLock.unlock()
            return
        }
        let resolved: WatchCredentialRelay.Answer
        if case let .accessToken(token, _) = answer {
            // A rotation is posted for any session this iPhone's client holds;
            // one that is not the Watch's account (a sign-in still finishing)
            // stays here.
            guard WatchCredentialRelay.tokenBelongs(token, to: identity.userID) else {
                pendingLock.unlock()
                return
            }
            resolved = .accessToken(token, userID: identity.userID)
        } else {
            resolved = answer
        }
        let payload = WatchCredentialRelay.message(for: resolved, identity: identity)
        let canSend =
            WCSession.default.activationState == .activated
            && WCSession.default.isPaired
        if canSend {
            pendingCredentialsPayload = nil
            pendingLock.unlock()
            // Only the newest token matters: older ones still queued (the
            // Watch app has not run since) go.
            for transfer in WCSession.default.outstandingUserInfoTransfers
            where transfer.userInfo[WatchCredentialRelay.answerKey] as? Bool == true {
                transfer.cancel()
            }
            WCSession.default.transferUserInfo(payload)
        } else {
            pendingCredentialsPayload = payload
            pendingLock.unlock()
        }
    }

    /// 1.61 (B1): what this iPhone answers a Watch asking for the current
    /// access token of `requestedUserID`'s session. Refreshes first when its
    /// own token has expired or is about to: this iPhone is the only side that
    /// refreshes a session it gave the Watch.
    @MainActor
    ///
    /// `heldFingerprint` (1.61): the fingerprint of the token the Watch holds.
    /// When it is this iPhone's current token, handing it back would only send
    /// the Watch round again: it is refreshed first.
    func credentialAnswer(requestedUserID: String, heldFingerprint: String? = nil) async -> WatchCredentialRelay.Answer {
        guard let state = appState else { return .unavailable }
        let phoneState: WatchCredentialRelay.PhoneState
        let userID = state.userId
        if !state.isDemoMode, state.isAuthenticated, !userID.isEmpty,
           let token = await state.api.getToken(), !token.isEmpty {
            var current = token
            switch WatchCredentialRelay.phoneRenewal(
                accessToken: token,
                canPersist: UIApplication.shared.isProtectedDataAvailable,
                watchHoldsIt: heldFingerprint == WatchCredentialRelay.fingerprint(token)
            ) {
            case .sendAsIs:
                break
            case .noAnswer:
                return .unavailable
            case .renewFirst:
                // A failed refresh is no answer: the Watch keeps its session
                // and asks again. A refusal signs this iPhone out at once
                // (1.61, `refreshSessionForWatch`), and its sign-out then
                // reaches the Watch.
                guard let renewed = await state.refreshSessionForWatch() else {
                    return .unavailable
                }
                current = renewed
            }
            // The account may have changed while the refresh was out.
            guard state.isAuthenticated, state.userId == userID else { return .unavailable }
            phoneState = .signedIn(userID: userID, accessToken: current)
        } else if UIApplication.shared.isProtectedDataAvailable,
                  state.storedSessionIsAbsent {
            // Signed out only when the Keychain answers that it holds no
            // session (`errSecItemNotFound`): a locked iPhone reads every item
            // as missing. 1.61: and a session the Keychain could not take yet
            // (`SessionTokenStore`) counts as held.
            phoneState = .signedOut
        } else {
            // Demo with a session kept for later, a restore still out, or a
            // locked iPhone whose Keychain cannot be read.
            phoneState = .restoring
            // 1.61: and if no restore is out (one that found the Keychain
            // locked, say), one starts now, so the Watch's next question finds
            // this iPhone signed in.
            state.restoreSessionIfIdle()
        }
        return WatchCredentialRelay.answer(for: phoneState, requestedUserID: requestedUserID)
    }

    private func currentIdentity() -> WatchSessionIdentity? {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return activeIdentity
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
        pendingCredentialsPayload = nil
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
                               devices: [DeviceRecord] = [],
                               hidePersonalInfo: Bool) {
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
        // 1.61 (B4): every device's status and last-seen time, so the Watch
        // counts the online ones itself (its Devices chip) rather than showing
        // the server's figure. A few bytes a device.
        if let data = try? encoder.encode(WatchDevicePresence.list(from: devices)) {
            context[WatchDevicePresence.contextKey] = data
        }
        // The Watch cannot read this app's defaults or fetch rates, and without
        // these showed every cost in dollars whatever the user chose.
        let currency = CurrencyConverter.shared.handoff()
        context[CurrencyConverter.contextCurrencyKey] = currency.currencyCode
        context[CurrencyConverter.contextRateKey] = currency.rate
        // The Watch masks account labels the way this iPhone does; it has no
        // switch of its own.
        PersonalInfoMask.addPhoneChoice(hidePersonalInfo, to: &context)

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
        let credentials = pendingCredentialsPayload
        pendingAuthPayload = nil
        pendingContext = nil
        pendingLogoutPayload = nil
        pendingCredentialsPayload = nil
        pendingLock.unlock()

        guard WCSession.default.activationState == .activated,
              WCSession.default.isPaired else { return }

        if let logout {
            WCSession.default.transferUserInfo(logout)
        } else {
            if let auth {
                WCSession.default.transferUserInfo(auth)
            }
            // After the sign-in it renews: queued transfers arrive in order.
            if let credentials {
                WCSession.default.transferUserInfo(credentials)
            }
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

    /// 1.61 (B1): the Watch asks for the current access token while this
    /// iPhone can be reached, and waits for the reply.
    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard let requested = WatchCredentialRelay.requestedUserID(in: message) else {
            replyHandler([:])
            return
        }
        let held = WatchCredentialRelay.heldTokenFingerprint(in: message)
        let reply = SendableReply(replyHandler)
        Task { @MainActor in
            // 1.61: the Watch's question can wake or launch this app in the
            // background; a refresh it makes must be written and answered
            // before iOS suspends the app.
            let backgroundTime = BackgroundTime("Watch credentials")
            defer { backgroundTime.end() }
            let answer = await self.credentialAnswer(requestedUserID: requested, heldFingerprint: held)
            reply.send(WatchCredentialRelay.message(for: answer, identity: self.currentIdentity()))
        }
    }

    /// 1.61 (B1): the same question queued while this iPhone could not be
    /// reached. The answer goes back the same way. A signed-out iPhone sends
    /// its sign-out, which ends the Watch's session from it.
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let requested = WatchCredentialRelay.requestedUserID(in: userInfo) else { return }
        let held = WatchCredentialRelay.heldTokenFingerprint(in: userInfo)
        Task { @MainActor in
            let backgroundTime = BackgroundTime("Watch credentials")
            defer { backgroundTime.end() }
            let answer = await self.credentialAnswer(requestedUserID: requested, heldFingerprint: held)
            switch answer {
            case .accessToken:
                self.sendCredentialsToWatch(answer)
            case .signedOut:
                self.sendLogoutToWatch(userID: requested.isEmpty ? nil : requested)
            case .unavailable:
                break   // the Watch asks again; this iPhone's next refresh also sends one
            }
        }
    }
}

/// WatchConnectivity's reply handler, carried into the Task that computes the
/// answer. WatchConnectivity calls it once, from any thread.
private struct SendableReply: @unchecked Sendable {
    let handler: ([String: Any]) -> Void
    init(_ handler: @escaping ([String: Any]) -> Void) { self.handler = handler }
    func send(_ message: [String: Any]) { handler(message) }
}
