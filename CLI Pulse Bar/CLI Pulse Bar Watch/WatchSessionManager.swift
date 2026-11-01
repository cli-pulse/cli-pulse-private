import Foundation
import WatchConnectivity
import CLIPulseCore

/// Manages WatchConnectivity to receive data from the paired iPhone app.
/// Stores received dashboard data as a fallback when the API is unreachable.
final class WatchSessionManager: NSObject, ObservableObject {
    static let shared = WatchSessionManager()

    @Published var lastReceivedDashboard: DashboardSummary?
    @Published var lastReceivedProviders: [ProviderUsage] = []
    @Published var lastReceivedSessions: [SessionRecord] = []
    @Published var lastReceivedAlerts: [AlertRecord] = []
    @Published var lastReceivedDevices: [WatchDeviceSummary] = []   // v1.41 Mobile Machine
    /// 1.61 (B4): every device's status and last-seen time, for the Devices
    /// chip. Nil when the iPhone (before 1.61) sent none.
    @Published var lastReceivedDevicePresence: [WatchDevicePresence]?
    @Published var isPhoneReachable = false
    @Published var lastSyncDate: Date?
    @Published private(set) var lastReceivedIdentity:
        WatchSessionIdentity?

    // Auth token received from iPhone. 1.61 (B1): the access token only; the
    // iPhone renews a session it gave the Watch, and keeps its refresh token.
    @Published var pendingAuthToken: String?
    @Published var pendingAuthEmail: String?
    @Published var pendingAuthName: String?

    private let dashboardKey = "cli_pulse_watch_dashboard"
    private let providersKey = "cli_pulse_watch_providers"
    private let sessionsKey = "cli_pulse_watch_sessions"
    private let alertsKey = "cli_pulse_watch_alerts"
    private let devicesKey = "cli_pulse_watch_devices"
    private let devicePresenceKey = "cli_pulse_watch_device_presence"
    private let ownerKey = "cli_pulse_watch_context_owner"
    private let epochKey = "cli_pulse_watch_context_epoch"
    private static let highestEpochKey =
        "cli_pulse_watch_highest_session_epoch"
    private static let highestOwnerKey =
        "cli_pulse_watch_highest_session_owner"
    private static let lastLogoutEpochKey =
        "cli_pulse_watch_last_logout_epoch"
    private static let lastLogoutOwnerKey =
        "cli_pulse_watch_last_logout_owner"
    private var orderingGate: WatchSessionOrderingGate
    private var logoutDeduplicationGate:
        WatchLogoutDeduplicationGate

    private override init() {
        let defaults = UserDefaults.standard
        let storedEpoch = UInt64(
            defaults.string(
                forKey: Self.highestEpochKey
            ) ?? ""
        ) ?? 0
        orderingGate = WatchSessionOrderingGate(
            highestAcceptedEpoch: storedEpoch,
            highestAcceptedUserID:
                defaults.string(
                    forKey: Self.highestOwnerKey
                )
        )
        let lastLogoutEpoch = UInt64(
            defaults.string(
                forKey: Self.lastLogoutEpochKey
            ) ?? ""
        )
        let lastLogoutIdentity = lastLogoutEpoch.flatMap {
            WatchSessionIdentity(
                userID: defaults.string(
                    forKey: Self.lastLogoutOwnerKey
                ) ?? "",
                epoch: $0
            )
        }
        logoutDeduplicationGate =
            WatchLogoutDeduplicationGate(
                lastAcceptedIdentity: lastLogoutIdentity
            )
        super.init()
    }

    /// 1.61 (B1): the account whose data the iPhone last sent and this Watch
    /// kept (the persisted snapshot's owner; a sign-out from the iPhone clears
    /// it). Read at launch, before WatchConnectivity activates, to tell a
    /// session stored before 1.61 that came from the iPhone.
    var lastPhoneUserID: String? {
        UserDefaults.standard.string(forKey: ownerKey).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Activate the WCSession if supported.
    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: - Persistence

    @MainActor
    private func persistData() {
        guard let identity = lastReceivedIdentity else {
            clearPersistedData()
            return
        }
        let encoder = JSONEncoder()
        if let dash = lastReceivedDashboard,
           let data = try? encoder.encode(dash) {
            UserDefaults.standard.set(data, forKey: dashboardKey)
        } else {
            UserDefaults.standard.removeObject(forKey: dashboardKey)
        }
        if let data = try? encoder.encode(lastReceivedProviders) {
            UserDefaults.standard.set(data, forKey: providersKey)
        }
        if let data = try? encoder.encode(lastReceivedSessions) {
            UserDefaults.standard.set(data, forKey: sessionsKey)
        }
        if let data = try? encoder.encode(lastReceivedAlerts) {
            UserDefaults.standard.set(data, forKey: alertsKey)
        }
        if let data = try? encoder.encode(lastReceivedDevices) {
            UserDefaults.standard.set(data, forKey: devicesKey)
        }
        if let presence = lastReceivedDevicePresence, let data = try? encoder.encode(presence) {
            UserDefaults.standard.set(data, forKey: devicePresenceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: devicePresenceKey)
        }
        UserDefaults.standard.set(
            identity.userID,
            forKey: ownerKey
        )
        UserDefaults.standard.set(
            String(identity.epoch),
            forKey: epochKey
        )
    }

    @MainActor
    func loadPersistedData() {
        guard
            let owner = UserDefaults.standard.string(
                forKey: ownerKey
            ),
            let epoch = UInt64(
                UserDefaults.standard.string(
                    forKey: epochKey
                ) ?? ""
            ),
            let identity = WatchSessionIdentity(
                userID: owner,
                epoch: epoch
            ),
            accept(identity)
        else {
            clearCachedData()
            return
        }
        let decoder = JSONDecoder()
        lastReceivedIdentity = identity
        if let data = UserDefaults.standard.data(forKey: dashboardKey),
           let dash = try? decoder.decode(DashboardSummary.self, from: data) {
            lastReceivedDashboard = dash
        } else {
            lastReceivedDashboard = nil
        }
        if let data = UserDefaults.standard.data(forKey: providersKey),
           let providers = try? decoder.decode([ProviderUsage].self, from: data) {
            lastReceivedProviders = providers
        } else {
            lastReceivedProviders = []
        }
        if let data = UserDefaults.standard.data(forKey: sessionsKey),
           let sessions = try? decoder.decode([SessionRecord].self, from: data) {
            lastReceivedSessions = sessions
        } else {
            lastReceivedSessions = []
        }
        if let data = UserDefaults.standard.data(forKey: alertsKey),
           let alerts = try? decoder.decode([AlertRecord].self, from: data) {
            lastReceivedAlerts = alerts
        } else {
            lastReceivedAlerts = []
        }
        if let data = UserDefaults.standard.data(forKey: devicesKey),
           let devices = try? decoder.decode([WatchDeviceSummary].self, from: data) {
            lastReceivedDevices = devices
        } else {
            lastReceivedDevices = []
        }
        lastReceivedDevicePresence = UserDefaults.standard.data(forKey: devicePresenceKey)
            .flatMap { try? decoder.decode([WatchDevicePresence].self, from: $0) }
    }

    @MainActor
    func clearCachedData() {
        lastReceivedDashboard = nil
        lastReceivedProviders = []
        lastReceivedSessions = []
        lastReceivedAlerts = []
        lastReceivedDevices = []
        lastReceivedDevicePresence = nil
        lastSyncDate = nil
        lastReceivedIdentity = nil
        pendingAuthToken = nil
        pendingAuthEmail = nil
        pendingAuthName = nil
        clearPersistedData()
    }

    @MainActor
    private func clearPersistedData() {
        for key in [
            dashboardKey,
            providersKey,
            sessionsKey,
            alertsKey,
            devicesKey,
            devicePresenceKey,
            ownerKey,
            epochKey,
        ] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    @MainActor
    private func accept(
        _ identity: WatchSessionIdentity
    ) -> Bool {
        guard orderingGate.accept(identity) else { return false }
        UserDefaults.standard.set(
            String(orderingGate.highestAcceptedEpoch),
            forKey: Self.highestEpochKey
        )
        UserDefaults.standard.set(
            orderingGate.highestAcceptedUserID,
            forKey: Self.highestOwnerKey
        )
        return true
    }

    @MainActor
    private func acceptLogout(
        _ identity: WatchSessionIdentity
    ) -> Bool {
        guard
            accept(identity),
            logoutDeduplicationGate.accept(identity)
        else {
            return false
        }
        UserDefaults.standard.set(
            identity.userID,
            forKey: Self.lastLogoutOwnerKey
        )
        UserDefaults.standard.set(
            String(identity.epoch),
            forKey: Self.lastLogoutEpochKey
        )
        return true
    }

    private static func identity(
        from payload: [String: Any]
    ) -> WatchSessionIdentity? {
        guard
            let userID = payload["user_id"] as? String,
            let epoch = sessionEpoch(
                from: payload["session_epoch"]
            )
        else {
            return nil
        }
        return WatchSessionIdentity(
            userID: userID,
            epoch: epoch
        )
    }

    private static func sessionEpoch(
        from value: Any?
    ) -> UInt64? {
        if let value = value as? UInt64 {
            return value > 0 ? value : nil
        }
        if let value = value as? Int,
           value > 0 {
            return UInt64(value)
        }
        if let value = value as? NSNumber,
           value.int64Value > 0 {
            return UInt64(value.int64Value)
        }
        if let value = value as? String,
           let epoch = UInt64(value),
           epoch > 0 {
            return epoch
        }
        return nil
    }

    // MARK: - Process application context

    private func processContext(_ context: [String: Any]) {
        guard
            context["cli_pulse_context"] as? Bool == true,
            let identity = Self.identity(from: context)
        else {
            // Old contexts have no owner and are unsafe after an account
            // switch. Direct API refresh remains available as the fallback.
            return
        }
        let isLogout =
            context["cli_pulse_logged_out"] as? Bool == true
        if isLogout {
            DispatchQueue.main.async {
                guard self.acceptLogout(identity) else { return }
                self.clearCachedData()
                NotificationCenter.default.post(
                    name: .watchDidReceiveLogout,
                    object: nil,
                    userInfo: [
                        "user_id": identity.userID,
                        "session_epoch": identity.epoch,
                    ]
                )
            }
            return
        }

        let decoder = JSONDecoder()
        let dashboardPresent =
            context["dashboard_present"] as? Bool == true
        let dash = dashboardPresent
            ? (context["dashboard"] as? Data).flatMap {
                try? decoder.decode(
                    DashboardSummary.self,
                    from: $0
                )
            }
            : nil
        guard
            !dashboardPresent || dash != nil,
            let providerData = context["providers"] as? Data,
            let providers = try? decoder.decode(
                [ProviderUsage].self,
                from: providerData
            ),
            let sessionData = context["sessions"] as? Data,
            let sessions = try? decoder.decode(
                [SessionRecord].self,
                from: sessionData
            ),
            let alertData = context["alerts"] as? Data,
            let alerts = try? decoder.decode(
                [AlertRecord].self,
                from: alertData
            ),
            let deviceData = context["devices"] as? Data,
            let devices = try? decoder.decode(
                [WatchDeviceSummary].self,
                from: deviceData
            )
        else {
            return
        }
        // Optional: an iPhone before 1.61 sends none.
        let devicePresence = (context[WatchDevicePresence.contextKey] as? Data)
            .flatMap { try? decoder.decode([WatchDevicePresence].self, from: $0) }
        // Read out here: the context dictionary is not Sendable.
        let currencyCode = context[CurrencyConverter.contextCurrencyKey] as? String
        let fxRate = context[CurrencyConverter.contextRateKey] as? Double
        let hidePersonalInfo = PersonalInfoMask.phoneChoice(inWatchContext: context)

        DispatchQueue.main.async {
            guard self.accept(identity) else { return }
            // Before the views re-render below. An iPhone app too old to send
            // the currency leaves dollars. It is also kept for the next launch
            // (`CLIPulseWatchApp.init`): WatchConnectivity hands this context
            // back only once the session activates, after the persisted costs
            // have already been shown.
            CurrencyConverter.shared.adoptAndRemember(currencyCode: currencyCode, rate: fxRate)
            // The iPhone's "Hide personal information", kept in this Watch's
            // defaults, where the views that name accounts read it.
            PersonalInfoMask.adoptPhoneChoice(hidePersonalInfo)
            if self.lastReceivedIdentity != identity {
                self.clearCachedData()
            }
            self.lastReceivedIdentity = identity
            self.lastReceivedDashboard = dash
            self.lastReceivedProviders = providers
            self.lastReceivedSessions = sessions
            self.lastReceivedAlerts = alerts
            self.lastReceivedDevices = devices
            self.lastReceivedDevicePresence = devicePresence
            self.lastSyncDate = Date()
            self.persistData()
            // Let WatchAppState re-apply fallback data into its @Published
            // properties — without this, an in-flight iPhone push only updates
            // the cache and views stay empty until the next app launch.
            NotificationCenter.default.post(
                name: .watchDidReceiveContext,
                object: nil,
                userInfo: [
                    "user_id": identity.userID,
                    "session_epoch": identity.epoch,
                ]
            )
        }
    }
}

// MARK: - WCSessionDelegate

extension WatchSessionManager: WCSessionDelegate {
    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        DispatchQueue.main.async {
            self.isPhoneReachable = session.isReachable
            // 1.61 (B1): a launch's restore asks the iPhone before this session
            // is active, and gets no answer; it asks again now. Reachable or
            // not: an iPhone out of reach gets the question queued, instead of
            // nothing until the next refresh tick.
            NotificationCenter.default.post(name: .watchPhoneBecameReachable, object: nil)
        }
        // Load any previously persisted data on activation
        DispatchQueue.main.async {
            self.loadPersistedData()
            if let identity = self.lastReceivedIdentity {
                // Tell WatchAppState to re-apply only an owned persisted
                // fallback. Legacy unowned caches were purged above.
                NotificationCenter.default.post(
                    name: .watchDidReceiveContext,
                    object: nil,
                    userInfo: [
                        "user_id": identity.userID,
                        "session_epoch": identity.epoch,
                    ]
                )
            }
        }
        // Process any existing application context
        if !session.receivedApplicationContext.isEmpty {
            processContext(session.receivedApplicationContext)
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            let wasReachable = self.isPhoneReachable
            self.isPhoneReachable = session.isReachable
            if session.isReachable, !wasReachable {
                // A session waiting for the iPhone's renewal asks again now.
                NotificationCenter.default.post(name: .watchPhoneBecameReachable, object: nil)
            }
        }
    }

    func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        processContext(applicationContext)
    }

    /// Receive queued user info from iPhone (auth tokens or logout signal).
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let identity = Self.identity(from: userInfo) else {
            // Fail closed for legacy messages without an owner/epoch.
            return
        }
        if userInfo["cli_pulse_logout"] as? Bool == true {
            DispatchQueue.main.async {
                guard self.acceptLogout(identity) else { return }
                self.pendingAuthToken = nil
                self.pendingAuthEmail = nil
                self.pendingAuthName = nil
                self.clearCachedData()
                // Clear stored tokens
                UserDefaults.standard.removeObject(forKey: "cli_pulse_watch_auth_token")
                UserDefaults.standard.removeObject(forKey: "cli_pulse_watch_refresh_token")
                NotificationCenter.default.post(
                    name: .watchDidReceiveLogout,
                    object: nil,
                    userInfo: [
                        "user_id": identity.userID,
                        "session_epoch": identity.epoch,
                    ]
                )
            }
            return
        }

        if userInfo["cli_pulse_auth"] as? Bool == true {
            let token = userInfo["access_token"] as? String
            let email = userInfo["email"] as? String
            let name = userInfo["name"] as? String

            guard let token, !token.isEmpty else { return }

            // Token persistence is handled by WatchAppState writing to
            // Keychain in applyWatchAuth(). Pre-v0.2.14 also wrote here
            // to UserDefaults; removed because UserDefaults on watchOS
            // is unencrypted at rest. WatchAppState.migrateLegacyUserDefaultsTokens
            // cleans up any stranded entries on launch.

            DispatchQueue.main.async {
                guard self.accept(identity) else { return }
                if self.lastReceivedIdentity != identity {
                    self.clearCachedData()
                }
                self.lastReceivedIdentity = identity
                self.pendingAuthToken = token
                self.pendingAuthEmail = email
                self.pendingAuthName = name
                NotificationCenter.default.post(name: .watchDidReceiveAuth, object: nil, userInfo: [
                    "access_token": token,
                    "user_id": identity.userID,
                    "session_epoch": identity.epoch,
                    "email": email ?? "",
                    "name": name ?? "",
                ])
            }
            return
        }

        // 1.61 (B1): a new access token for the session this iPhone gave the
        // Watch: one its refresh produced, or its answer to a queued request.
        if userInfo[WatchCredentialRelay.answerKey] as? Bool == true,
           case let .accessToken(token, _) = WatchCredentialRelay.answer(from: userInfo) {
            DispatchQueue.main.async {
                guard self.accept(identity) else { return }
                NotificationCenter.default.post(name: .watchDidReceiveCredentials, object: nil, userInfo: [
                    "access_token": token,
                    "user_id": identity.userID,
                    "session_epoch": identity.epoch,
                ])
            }
        }
    }
}

// MARK: - 1.61 (B1): asking the iPhone for the current access token

extension WatchSessionManager {
    /// How long the Watch waits for the iPhone's reply before it queues the
    /// question instead.
    static let credentialsReplyTimeout: TimeInterval = 20

    /// Asks the iPhone for the current access token of `userID`'s session and
    /// waits for its answer while the iPhone can be reached. Otherwise (or
    /// with no reply in time) the question is queued for the iPhone, whose
    /// answer arrives later as a transfer (`.watchDidReceiveCredentials`), and
    /// this returns `.unavailable`.
    ///
    /// `heldToken` (1.61): the token the Watch holds now; only its fingerprint
    /// is sent (`WatchCredentialRelay.request`).
    func requestCurrentCredentials(userID: String, heldToken: String? = nil) async -> WatchCredentialRelay.Answer {
        guard WCSession.isSupported() else { return .unavailable }
        let session = WCSession.default
        guard session.activationState == .activated else { return .unavailable }
        let request = WatchCredentialRelay.request(userID: userID, heldToken: heldToken)
        if session.isReachable {
            let reply: WatchCredentialRelay.Answer? = await withCheckedContinuation { continuation in
                let once = ResumeOnce(continuation)
                session.sendMessage(
                    request,
                    replyHandler: { once.resume(WatchCredentialRelay.answer(from: $0)) },
                    errorHandler: { _ in once.resume(nil) }
                )
                DispatchQueue.global().asyncAfter(deadline: .now() + Self.credentialsReplyTimeout) {
                    once.resume(nil)
                }
            }
            // 1.61: "no answer now" (an iPhone still restoring, or locked)
            // also leaves the question queued, so the answer comes when it can.
            if let reply, reply != .unavailable { return reply }
        }
        queueCredentialsRequest(request, on: session)
        return .unavailable
    }

    /// 1.61: cancels the questions still queued for the iPhone. Called on every
    /// auth transition: an answer to a question about the session it ended
    /// must not reach the next one.
    func cancelQueuedCredentialRequests() {
        guard WCSession.isSupported() else { return }
        for transfer in WCSession.default.outstandingUserInfoTransfers
        where WatchCredentialRelay.requestedUserID(in: transfer.userInfo) != nil {
            transfer.cancel()
        }
    }

    /// One queued question per account at a time: the iPhone's answer is the
    /// same however often it was asked.
    private func queueCredentialsRequest(_ request: [String: Any], on session: WCSession) {
        let asked = WatchCredentialRelay.requestedUserID(in: request) ?? ""
        let alreadyQueued = session.outstandingUserInfoTransfers.contains {
            $0.isTransferring && WatchCredentialRelay.requestedUserID(in: $0.userInfo) == asked
        }
        if !alreadyQueued {
            session.transferUserInfo(request)
        }
    }
}

/// Resumes a continuation once, whichever of the reply, the error and the
/// timeout comes first. WatchConnectivity calls its handlers from any thread.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<WatchCredentialRelay.Answer?, Never>?

    init(_ continuation: CheckedContinuation<WatchCredentialRelay.Answer?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: WatchCredentialRelay.Answer?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let watchDidReceiveAuth = Notification.Name("watchDidReceiveAuth")
    static let watchDidReceiveLogout = Notification.Name("watchDidReceiveLogout")
    static let watchDidReceiveContext = Notification.Name("watchDidReceiveContext")
    /// 1.61 (B1): a new access token from the iPhone for its session.
    static let watchDidReceiveCredentials = Notification.Name("watchDidReceiveCredentials")
    /// 1.61 (B1): the iPhone can be reached again.
    static let watchPhoneBecameReachable = Notification.Name("watchPhoneBecameReachable")
}
