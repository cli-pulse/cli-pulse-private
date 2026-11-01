import Foundation
import SwiftUI
import CLIPulseCore

/// Lightweight app state for watchOS, exposing only the properties watch views need.
/// Full AppState has 40+ published properties; this has ~15, reducing memory and processing overhead.
@MainActor
public final class WatchAppState: ObservableObject {
    // MARK: - Auth
    @Published var isAuthenticated = false
    @Published var isPaired = false
    @Published var userName = ""
    @Published var userEmail = ""

    // MARK: - Data
    @Published var dashboard: DashboardSummary?
    @Published var providers: [ProviderUsage] = []
    /// Credential-free account snapshots read from the v2 cloud summary.
    /// Provider credentials remain on the Mac and are structurally absent.
    @Published var providerAccounts: [ProviderAccountUsage] = []
    @Published var sessions: [SessionRecord] = []
    @Published var alerts: [AlertRecord] = []
    // v1.41 Mobile Machine: trimmed, read-only device-health summaries (≤4).
    @Published var devices: [WatchDeviceSummary] = []
    /// 1.61 (B4): every device's status and last-seen time, from the Watch's
    /// own device fetch or the iPhone's snapshot (`WatchDevicePresence`). Nil
    /// until either has arrived.
    @Published var devicePresence: [WatchDevicePresence]?
    /// When `devicePresence` was obtained (the fetch, or the iPhone's push).
    @Published var devicePresenceAt: Date?

    // MARK: - Cost
    @Published var costSummary = CostSummary()

    // MARK: - UI
    @Published var isLoading = false
    @Published var lastError: String?
    @Published var lastRefresh: Date?
    @Published var serverOnline = false
    @Published var providerDataLoaded = false
    @Published var usesLegacyProviderSummary = true

    // MARK: - Auth Flow
    @Published var otpSent = false
    @Published var otpEmail = ""

    // MARK: - Settings
    @AppStorage("cli_pulse_demo_mode") var isDemoMode = false
    @AppStorage("cli_pulse_show_cost") var showCost = true

    /// Where the dashboard this Watch draws comes from, in the router's terms
    /// (`OverviewFormatters.showsRequestsMetric`). The Watch has no local
    /// refresh: its dashboard is its own `dashboard_summary` fetch
    /// (`refreshAll`) or the iPhone's relay of the same cloud figures, so it
    /// decides as the iPhone does and is never `.localOnly`.
    var refreshRoute: RefreshRoute {
        RefreshRouter.decide(
            isAuthenticated: isAuthenticated,
            isDemoMode: isDemoMode,
            isPaired: isPaired,
            isLocalMode: false,
            isMacOS: false
        )
    }

    // MARK: - Internal
    private let api: APIClient
    private let authManager: AuthManager
    private var refreshTimer: Timer?
    private var refreshGate = WatchRefreshGate()
    private var authTransitionGate =
        WatchAuthTransitionGate()
    private var otpRequestGeneration: UInt64 = 0
    private var currentUserID = ""
    private var remoteSessionEpoch: UInt64?
    /// 1.61 (B1): who renews the current session. `.phone`: the iPhone (this
    /// Watch holds no refresh token for it); `.watch`: this Watch.
    private var sessionSource: WatchSessionSource = .watch
    /// 1.61 (B1): a renewal the iPhone could not give yet. The session and its
    /// tokens stay, the last data shows as stale, and the Watch asks again
    /// when the iPhone can be reached or sends a token.
    private(set) var awaitingPhoneCredentials = false
    /// 1.61: the newest access token the iPhone delivered that no session here
    /// could take yet (it arrived while a restore was out, as queued transfers
    /// do right after launch). Adopted once that account's session from the
    /// iPhone is in, and used before asking the iPhone again.
    private var deliveredPhoneToken: (token: String, userID: String)?
    // v1.41: fetch devices() every 2nd refresh (tick 0, 2, 4…) to save watch
    // battery — machine health changes slowly and rides the WC fallback anyway.
    private var refreshTickCount = 0

    init() {
        // v0.2.14 — one-shot migration off UserDefaults for any auth tokens
        // the leaky pre-v0.2.14 build wrote there. Must run before
        // restoreSession() so a Keychain-only build doesn't lose an
        // already-bridged session that lives only in UserDefaults.
        Self.migrateLegacyUserDefaultsTokens()

        self.api = APIClient()
        self.authManager = AuthManager(api: api, persistTokens: { access, refresh in
            if !access.isEmpty {
                KeychainHelper.save(key: "cli_pulse_token", value: access)
            } else {
                KeychainHelper.delete(key: "cli_pulse_token")
            }
            if let refresh, !refresh.isEmpty {
                KeychainHelper.save(key: "cli_pulse_refresh_token", value: refresh)
            } else {
                KeychainHelper.delete(key: "cli_pulse_refresh_token")
            }
        })

        #if DEBUG
        // An App Store screenshot capture: Demo's data as this Watch's own
        // refresh would hold it, no session restore, no observers, no network.
        if WatchScreenshotLaunch.activeScreen != nil {
            applyScreenshotDemo(WatchScreenshotLaunch.demoSnapshot())
            return
        }
        #endif

        Task { await restoreSession() }

        // Listen for iPhone auth
        NotificationCenter.default.addObserver(forName: .watchDidReceiveAuth, object: nil, queue: .main) { [weak self] notif in
            guard let self, let info = notif.userInfo,
                  let token = info["access_token"] as? String,
                  !token.isEmpty,
                  let identity = Self.sessionIdentity(
                      from: info
                  )
            else {
                return
            }
            Task { @MainActor in
                await self.applyWatchAuth(
                    token: token,
                    identity: identity,
                    email: info["email"] as? String ?? "",
                    name: info["name"] as? String ?? ""
                )
            }
        }

        // Re-apply cached fallback when the phone pushes fresh application context.
        // preferLive=false — the push is authoritative, so overwrite any stale
        // data the watch has from a prior refresh.
        // v1.10.1 P3b: bind `self` in the outer closure before the Task hop.
        // Swift 6 forbids referencing a captured `var` (weak self binding)
        // from concurrently-executing code; bind-then-capture passes a
        // plain `let` into the Task and silences the violation cleanly.
        NotificationCenter.default.addObserver(forName: .watchDidReceiveContext, object: nil, queue: .main) { [weak self] notification in
            guard
                let self,
                let info = notification.userInfo,
                Self.sessionIdentity(from: info) != nil
            else {
                return
            }
            Task { @MainActor in
                self.applyFallbackData(from: WatchSessionManager.shared, preferLive: false)
            }
        }

        // 1.61 (B1): an access token the iPhone renewed for its session.
        NotificationCenter.default.addObserver(forName: .watchDidReceiveCredentials, object: nil, queue: .main) { [weak self] notification in
            guard
                let self,
                let info = notification.userInfo,
                let token = info["access_token"] as? String,
                let identity = Self.sessionIdentity(from: info)
            else {
                return
            }
            Task { @MainActor in
                await self.adoptPhoneAccessToken(token, for: identity)
            }
        }

        NotificationCenter.default.addObserver(forName: .watchPhoneBecameReachable, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.isAuthenticated, self.sessionSource == .phone, self.awaitingPhoneCredentials else { return }
                await self.refreshAll()
            }
        }

        NotificationCenter.default.addObserver(forName: .watchDidReceiveLogout, object: nil, queue: .main) { [weak self] notification in
            guard
                let self,
                let info = notification.userInfo,
                let identity = Self.sessionIdentity(
                    from: info
                )
            else {
                return
            }
            Task { @MainActor in
                self.applyRemoteLogout(identity)
            }
        }
    }

    // MARK: - Auth Actions

    func sendOTP(email: String) async {
        otpRequestGeneration &+= 1
        let requestGeneration = otpRequestGeneration
        isLoading = true
        lastError = nil
        do {
            let sentEmail = try await authManager.sendOTP(
                email: email
            )
            guard
                requestGeneration == otpRequestGeneration,
                !isAuthenticated
            else {
                return
            }
            otpEmail = sentEmail
            otpSent = true
        } catch {
            guard requestGeneration == otpRequestGeneration else {
                return
            }
            lastError = error.localizedDescription
        }
        if requestGeneration == otpRequestGeneration {
            isLoading = false
        }
    }

    func verifyOTP(code: String) async {
        let email = otpEmail
        guard let lease = await beginAuthTransition(
            kind: .authentication
        ) else {
            return
        }
        isLoading = true
        lastError = nil
        do {
            // Verify against an isolated client. It may mutate its own actor
            // state while awaiting, but it cannot resurrect an older session
            // in the app's shared APIClient.
            let candidateAPI = APIClient()
            let response = try await candidateAPI.verifyOTP(
                email: email,
                code: code
            )
            guard await commitAuthenticatedSession(
                response,
                lease: lease,
                remoteIdentity: nil,
                source: .watch
            ) else {
                return
            }
            otpSent = false
            otpEmail = ""
            await refreshAll()
        } catch {
            guard authTransitionGate.canCommit(lease) else {
                return
            }
            lastError = error.localizedDescription
        }
        if authTransitionGate.canCommit(lease) {
            isLoading = false
        }
    }

    func resetOTP() {
        otpRequestGeneration &+= 1
        let state = authManager.resetOTP()
        otpSent = state.otpSent
        otpEmail = state.otpEmail
        lastError = state.lastError
        isLoading = false
    }

    /// The iPhone's sign-in. 1.61 (B1): installed without a refresh token; the
    /// iPhone renews this session (`WatchCredentialRelay`).
    func applyWatchAuth(
        token: String,
        identity: WatchSessionIdentity,
        email: String,
        name: String
    ) async {
        guard let lease = await beginAuthTransition(
            preservingRemoteIdentity: identity,
            kind: .authentication
        ) else {
            return
        }
        isLoading = true
        let response = AuthResponse(
            access_token: token,
            refresh_token: nil,
            user: UserDTO(
                id: identity.userID,
                name: name,
                email: email
            ),
            paired: true
        )
        guard await commitAuthenticatedSession(
            response,
            lease: lease,
            remoteIdentity: identity,
            source: .phone
        ) else {
            return
        }
        applyFallbackData(
            from: WatchSessionManager.shared,
            preferLive: false
        )
        await refreshAll()
        if authTransitionGate.canCommit(lease) {
            isLoading = false
        }
    }

    func signOut() {
        let lease = authTransitionGate.beginTransition()
        otpRequestGeneration &+= 1
        // 1.61: nothing the iPhone delivered for the session left is kept, and
        // no question queued for it is answered into the next one.
        deliveredPhoneToken = nil
        WatchSessionManager.shared.cancelQueuedCredentialRequests()
        // 1.61 (B1): a session from the iPhone is the iPhone's to revoke (its
        // sign-out does). Revoking it from here would sign the iPhone out.
        // The stored record first: a restore or a sign-in still in flight has
        // already reset `sessionSource`.
        let revokesOnServer = (
            WatchSessionRecord.stored(KeychainHelper.load(key: WatchSessionRecord.keychainKey))?.source
                ?? sessionSource
        ).renewsItself
        let token =
            KeychainHelper.load(key: "cli_pulse_token") ?? ""
        stopRefreshLoop()
        refreshGate.authDidChange()
        KeychainHelper.delete(key: "cli_pulse_token")
        KeychainHelper.delete(
            key: "cli_pulse_refresh_token"
        )
        KeychainHelper.delete(key: WatchSessionRecord.keychainKey)
        currentUserID = ""
        remoteSessionEpoch = nil
        sessionSource = .watch
        awaitingPhoneCredentials = false
        isAuthenticated = false
        isPaired = false
        userName = ""
        userEmail = ""
        otpSent = false
        otpEmail = ""
        clearRemoteData()
        WatchSessionManager.shared.clearCachedData()

        // The generation check inside APIClient makes this safe even if a new
        // phone auth or OTP transition starts before this Task is scheduled.
        Task { @MainActor [api, authManager] in
            _ = await api.beginExternalAuthorizationTransition(
                generation: lease.generation
            )
            if revokesOnServer {
                await authManager.signOut(
                    currentAccessToken: token
                )
            }
        }
    }

    private func beginAuthTransition(
        preservingRemoteIdentity:
            WatchSessionIdentity? = nil,
        kind: WatchAuthTransitionKind
    ) async -> WatchAuthTransitionLease? {
        let lease = authTransitionGate.beginTransition()
        otpRequestGeneration &+= 1
        // 1.61: a question queued for the session this transition ends must
        // not be answered into the next one (an iPhone's "signed out" for it
        // would end a session signed in here meanwhile).
        WatchSessionManager.shared.cancelQueuedCredentialRequests()
        stopRefreshLoop()
        refreshGate.authDidChange()
        if kind.clearsPersistedCredentials {
            KeychainHelper.delete(key: "cli_pulse_token")
            KeychainHelper.delete(
                key: "cli_pulse_refresh_token"
            )
            KeychainHelper.delete(key: WatchSessionRecord.keychainKey)
        }
        currentUserID = ""
        remoteSessionEpoch = nil
        sessionSource = .watch
        awaitingPhoneCredentials = false
        isAuthenticated = false
        isPaired = false
        userName = ""
        userEmail = ""
        clearRemoteData()
        let receivedIdentity =
            WatchSessionManager.shared
                .lastReceivedIdentity
        if receivedIdentity != preservingRemoteIdentity {
            WatchSessionManager.shared.clearCachedData()
        }

        let began = await api
            .beginExternalAuthorizationTransition(
                generation: lease.generation
            )
        guard
            began,
            authTransitionGate.canCommit(lease)
        else {
            return nil
        }
        return lease
    }

    private func commitAuthenticatedSession(
        _ response: AuthResponse,
        lease: WatchAuthTransitionLease,
        remoteIdentity: WatchSessionIdentity?,
        source: WatchSessionSource
    ) async -> Bool {
        guard
            authTransitionGate.canCommit(lease),
            let normalizedIdentity = WatchSessionIdentity(
                userID: response.user.id,
                epoch: 1
            ),
            remoteIdentity?.userID
                == normalizedIdentity.userID
                || remoteIdentity == nil
        else {
            return false
        }

        // 1.61 (B1): a session from the iPhone is installed with no refresh
        // token and renewed by asking the iPhone; this Watch's own keeps its.
        let installed = await api
            .installExternalAuthenticatedSession(
                accessToken: response.access_token,
                refreshToken: source.renewsItself ? response.refresh_token : nil,
                userID: normalizedIdentity.userID,
                transitionGeneration:
                    lease.generation,
                renewer: source.renewsItself
                    ? nil
                    : makePhoneRenewer(userID: normalizedIdentity.userID, lease: lease, client: api)
            )
        guard
            installed,
            authTransitionGate.canCommit(lease)
        else {
            return false
        }

        // Persist only after the shared API actor accepted the same newest
        // transition. A stale OTP/restore result never reaches Keychain.
        // The record first: a token saved without its record would be taken
        // for the Watch's own at the next launch.
        KeychainHelper.save(
            key: WatchSessionRecord.keychainKey,
            value: WatchSessionRecord(
                source: source,
                userID: normalizedIdentity.userID,
                name: response.user.name,
                email: response.user.email
            ).encoded
        )
        KeychainHelper.save(
            key: "cli_pulse_token",
            value: response.access_token
        )
        if source.renewsItself,
           let refreshToken = response.refresh_token,
           !refreshToken.isEmpty {
            KeychainHelper.save(
                key: "cli_pulse_refresh_token",
                value: refreshToken
            )
        } else {
            KeychainHelper.delete(
                key: "cli_pulse_refresh_token"
            )
        }

        currentUserID = normalizedIdentity.userID
        remoteSessionEpoch = remoteIdentity?.epoch
        sessionSource = source
        awaitingPhoneCredentials = false
        userName = response.user.name
        userEmail = response.user.email
        isPaired = response.paired
        isAuthenticated = true
        serverOnline = true
        startRefreshLoop()
        return true
    }

    private func applyRemoteLogout(
        _ identity: WatchSessionIdentity
    ) {
        guard WatchRemoteLogoutPolicy
            .shouldInvalidateAuthentication(
                isAuthenticated: isAuthenticated,
                currentUserID: currentUserID,
                currentRemoteEpoch:
                    remoteSessionEpoch,
                logoutIdentity: identity
            )
        else {
            return
        }
        signOut()
    }

    private func clearRemoteData() {
        dashboard = nil
        providers = []
        providerAccounts = []
        sessions = []
        alerts = []
        devices = []
        devicePresence = nil
        devicePresenceAt = nil
        fetchedDeviceNumbers = nil
        costSummary = CostSummary()
        isLoading = false
        lastError = nil
        lastRefresh = nil
        serverOnline = false
        providerDataLoaded = false
        usesLegacyProviderSummary = true
        refreshTickCount = 0
    }

    // MARK: - Device names

    /// 1.60 (C9): the account's devices, numbered for "Device N"
    /// (`DeviceNameNumbers`), for "Hide personal information": the whole list
    /// from the Watch's own last fetch, as the iPhone numbers it, else the
    /// devices it was sent (only those that report machine health).
    var deviceNameNumbers: DeviceNameNumbers { fetchedDeviceNumbers ?? .devices(devices) }
    private var fetchedDeviceNumbers: DeviceNameNumbers?

    // MARK: - Sessions clock

    /// 1.60 (59-05): the moment the Watch counts sessions and devices against
    /// (`SessionsClock`, as `AppState.sessionsClock` on the iPhone and Mac):
    /// now, and in Demo (or a screenshot capture of it) the moment its one
    /// refresh is shown at, so Demo's rows do not age out while it is open.
    func sessionsClock(now: Date = Date()) -> Date {
        SessionsClock.at(now, demoRefresh: (isDemoMode || currentUserID == "demo") ? lastRefresh : nil)
    }

    /// 1.61 (B4): the Live page's sections at `clock` (`sessionsClock()`,
    /// read once by the caller), `WatchLivePage`: `live` is the figure the
    /// Pulse chip shows.
    func liveSections(at clock: Date) -> (live: [SessionRecord], recent: [SessionRecord]) {
        WatchLivePage.sections(sessions, now: clock)
    }

    // MARK: - Provider Helpers

    var enabledProviderNames: Set<String> {
        ProviderAccountPresentation.visibleProviderNames(
            accounts: providerAccounts,
            legacyProviderNames:
                providers.map(\.provider),
            usesLegacyFallback:
                usesLegacyProviderSummary
        )
    }

    var enabledProviderAccounts: [ProviderAccountUsage] {
        ProviderAccountPresentation.enabledAccounts(
            providerAccounts
        )
    }

    var providerAccountGroups: [ProviderAccountGroup] {
        ProviderAccountPresentation.enabledGroups(
            providerAccounts
        )
    }

    func accounts(
        for providerName: String
    ) -> [ProviderAccountUsage] {
        guard let provider = ProviderKind(rawValue: providerName) else {
            return []
        }
        return providerAccountGroups.first {
            $0.provider == provider
        }?.accounts ?? []
    }

    // MARK: - Alert Actions

    func acknowledgeAlert(_ alert: AlertRecord) async {
        do {
            _ = try await api.acknowledgeAlert(id: alert.id)
            await refreshAll()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func resolveAlert(_ alert: AlertRecord) async {
        do {
            _ = try await api.resolveAlert(id: alert.id)
            await refreshAll()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func snoozeAlert(_ alert: AlertRecord, minutes: Int) async {
        do {
            _ = try await api.snoozeAlert(id: alert.id, minutes: minutes)
            await refreshAll()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Refresh

    func refreshAll() async {
        #if DEBUG
        if WatchScreenshotLaunch.activeScreen != nil { return }   // a capture never refreshes
        #endif
        guard let lease = refreshGate.beginRefresh(
            isAuthenticated: isAuthenticated
        ) else {
            return
        }
        isLoading = true
        lastError = nil
        let fetchDevices = refreshTickCount % 2 == 0   // ticks 0,2,4… (first paint included)
        refreshTickCount &+= 1
        do {
            async let dashTask = api.dashboard()
            async let providerSummaryTask =
                api.providerAccountSummary()
            async let sessTask = api.sessions()
            async let alertTask = api.alerts()

            let fetchedDashboard = try await dashTask
            let fetchedProviderSummary =
                try await providerSummaryTask
            let fetchedSessions = try await sessTask
            let fetchedAlerts = try await alertTask
            var fetchedDevices: [WatchDeviceSummary]?
            var fetchedNumbers: DeviceNameNumbers?
            var fetchedPresence: [WatchDevicePresence]?
            if fetchDevices, let rawDevices = try? await api.devices() {
                fetchedDevices =
                    WatchDeviceTrim.summaries(from: rawDevices)
                fetchedNumbers = .devices(rawDevices)
                fetchedPresence = WatchDevicePresence.list(from: rawDevices)
            }

            guard refreshGate.canCommit(
                lease,
                isAuthenticated: isAuthenticated
            ) else {
                return
            }
            dashboard = fetchedDashboard
            // Same display projection the iPhone and Mac apply
            // (`QuotaBindingCap`): an exhausted weekly Codex window reads
            // through to the 5-hour bar and the ring.
            // Retired providers' rows are left out, as on the iPhone and
            // the Mac (`ProviderRoster.shown`).
            providers = QuotaBindingCap.projectedForDisplay(
                ProviderRoster.shown(fetchedProviderSummary.providers)
            )
            providerAccounts = QuotaBindingCap.projectedForDisplay(
                ProviderRoster.shown(fetchedProviderSummary.providerAccounts)
            )
            usesLegacyProviderSummary =
                fetchedProviderSummary.usedLegacyFallback
            providerDataLoaded = true
            sessions = fetchedSessions
            alerts = fetchedAlerts
            if let fetchedDevices {
                devices = fetchedDevices
                fetchedDeviceNumbers = fetchedNumbers
                devicePresence = fetchedPresence
                devicePresenceAt = Date()
            }
            serverOnline = true
            lastRefresh = Date()
        } catch {
            guard refreshGate.canCommit(
                lease,
                isAuthenticated: isAuthenticated
            ) else {
                return
            }
            serverOnline = false
            lastError = error.localizedDescription
        }
        isLoading = false
    }

    func startRefreshLoop() {
        #if DEBUG
        if WatchScreenshotLaunch.activeScreen != nil { return }   // a capture never refreshes
        #endif
        stopRefreshLoop()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.refreshAll()
            }
        }
    }

    func stopRefreshLoop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    #if DEBUG
    /// The screenshot capture's state (`WatchScreenshotLaunch.demoSnapshot`):
    /// what `applyFallbackData(preferLive: false)` stores when the iPhone
    /// relays its refresh of the account Demo describes, with the legacy
    /// provider summary every build reads.
    private func applyScreenshotDemo(_ demo: WatchScreenshotLaunch.Snapshot) {
        currentUserID = "demo"
        isAuthenticated = true
        isPaired = true
        userName = L10n.auth.demoUserName
        userEmail = "demo@clipulse.app"
        dashboard = demo.dashboard
        providers = demo.providers
        providerAccounts = []
        usesLegacyProviderSummary = true
        providerDataLoaded = true
        sessions = demo.sessions
        alerts = demo.alerts
        devices = demo.devices
        devicePresence = demo.devicePresence
        devicePresenceAt = demo.refreshedAt
        serverOnline = true
        lastRefresh = demo.refreshedAt
        isLoading = false
        lastError = nil
    }
    #endif

    // MARK: - Session Restore

    private func restoreSession() async {
        if isDemoMode {
            guard await beginAuthTransition(
                kind: .demoMode
            ) != nil else {
                return
            }
            currentUserID = "demo"
            isAuthenticated = true
            isPaired = true
            // No Watch view shows this yet; resolved like the phone's Demo so
            // the first one that does is not English in every language.
            userName = L10n.auth.demoUserName
            userEmail = "demo@clipulse.app"
            return
        }

        let token = KeychainHelper.load(key: "cli_pulse_token") ?? ""
        let refreshToken = KeychainHelper.load(key: "cli_pulse_refresh_token")
        guard !token.isEmpty else { return }
        // 1.61 (B1): who renews the stored session. One stored before 1.61
        // has no record and is renewed here, as it was, until the iPhone next
        // sends its sign-in.
        let record = WatchSessionRecord.resolve(
            stored: KeychainHelper.load(key: WatchSessionRecord.keychainKey),
            accessToken: token,
            lastPhoneUserID: WatchSessionManager.shared.lastPhoneUserID
        )
        let source = WatchSessionRecord.source(of: record)

        guard let lease = await beginAuthTransition(
            kind: .sessionRestore
        ) else {
            return
        }
        isLoading = true
        // Validate/refresh the stored credentials in an isolated actor.
        // Only the newest transition may install the result into `api`.
        let candidateAPI = APIClient(token: token)
        do {
            if source == .phone, let record {
                await candidateAPI.setSessionRenewer(
                    makePhoneRenewer(userID: record.userID, lease: lease, client: candidateAPI)
                )
            } else {
                await candidateAPI.updateRefreshToken(
                    refreshToken
                )
            }
            let response = try await candidateAPI.me()
            guard await commitAuthenticatedSession(
                response,
                lease: lease,
                remoteIdentity: nil,
                source: source
            ) else {
                return
            }
            await adoptDeliveredPhoneToken()
            await refreshAll()
        } catch {
            guard authTransitionGate.canCommit(lease) else {
                return
            }
            // `WatchSessionRestoreCredentialPolicy` for the Watch's own
            // session; a session from the iPhone ends only on its word.
            let action = WatchCredentialRelay.restoreFailureAction(source: source, error: error)
            if action == .showOffline, let record {
                // 1.61 (B1): a session from the iPhone is not signed out because
                // the iPhone (or the server) could not be reached at launch. It
                // shows the last data the iPhone sent, as stale, with its token
                // as renewed so far, and asks again.
                await commitPhoneSessionOffline(
                    record,
                    accessToken: await candidateAPI.getToken() ?? token,
                    lease: lease,
                    error: error
                )
                return
            }
            if action == .deleteCredentials {
                KeychainHelper.delete(key: "cli_pulse_token")
                KeychainHelper.delete(
                    key: "cli_pulse_refresh_token"
                )
                KeychainHelper.delete(key: WatchSessionRecord.keychainKey)
            } else {
                // 1.60: `me()` now refreshes an expired token (Supabase
                // Auth's 403 `bad_jwt`). If that refresh succeeded and a
                // later step failed (offline, 5xx), the server has spent the
                // refresh token the Keychain still holds; keep the rotated
                // pair, or the next launch is refused and signed out.
                let rotatedAccess = await candidateAPI.getToken()
                let rotatedRefresh = await candidateAPI.getRefreshToken()
                if authTransitionGate.canCommit(lease),
                   let rotatedAccess, !rotatedAccess.isEmpty,
                   let rotatedRefresh, !rotatedRefresh.isEmpty,
                   rotatedRefresh != refreshToken {
                    KeychainHelper.save(key: "cli_pulse_token", value: rotatedAccess)
                    KeychainHelper.save(key: "cli_pulse_refresh_token", value: rotatedRefresh)
                }
            }
            lastError = error.localizedDescription
        }
        if authTransitionGate.canCommit(lease) {
            isLoading = false
        }
    }

    // MARK: - 1.61 (B1): a session the iPhone renews

    /// The renewer for a session from the iPhone: asks the iPhone for the
    /// current access token of `userID`'s session instead of refreshing.
    /// `lease` is the auth transition that installed the session: an answer
    /// that arrives after another one (a sign-out, a new sign-in, even of the
    /// same account) is acted on by nobody.
    /// `client` (1.61): the client whose session this renews, for the token it
    /// holds now.
    private func makePhoneRenewer(
        userID: String,
        lease: WatchAuthTransitionLease,
        client: APIClient
    ) -> APIClient.SessionRenewer {
        { [weak self, weak client] in
            guard let self else { throw WatchCredentialRelayError.waitingForPhone }
            let held = await client?.getToken()
            return try await self.renewFromPhone(userID: userID, lease: lease, holding: held)
        }
    }

    private func renewFromPhone(
        userID: String,
        lease: WatchAuthTransitionLease,
        holding held: String?
    ) async throws -> String {
        // 1.61: a newer token the iPhone already delivered, before asking again.
        if authTransitionGate.canCommit(lease),
           let kept = WatchCredentialRelay.usableDelivered(
               deliveredPhoneToken.flatMap { WatchCredentialRelay.sameUser($0.userID, userID) ? $0.token : nil },
               userID: userID,
               holding: held
           ) {
            KeychainHelper.save(key: "cli_pulse_token", value: kept)
            awaitingPhoneCredentials = false
            return kept
        }
        // The fingerprint of the token held tells an iPhone holding the same
        // one to refresh rather than hand it back (1.61).
        let answer = await WatchSessionManager.shared.requestCurrentCredentials(userID: userID, heldToken: held)
        // Acted on only while the session asked about is still this Watch's.
        let stillOurs = authTransitionGate.canCommit(lease)
        switch WatchCredentialRelay.watchAction(for: answer, currentUserID: userID) {
        case let .install(accessToken):
            guard stillOurs else { throw WatchCredentialRelayError.waitingForPhone }
            KeychainHelper.save(key: "cli_pulse_token", value: accessToken)
            awaitingPhoneCredentials = false
            return accessToken
        case .signOut:
            // The iPhone says it is signed out: the only answer that ends the
            // session (as its sign-out message would).
            if stillOurs { signOut() }
            throw APIError.tokenExpired
        case .wait:
            if stillOurs { awaitingPhoneCredentials = true }
            throw WatchCredentialRelayError.waitingForPhone
        }
    }

    /// An access token the iPhone sent for its session (a refresh there, or
    /// its answer to a queued request). A session waiting for it refreshes.
    private func adoptPhoneAccessToken(_ token: String, for identity: WatchSessionIdentity) async {
        // 1.61: no session from the iPhone is in yet (a launch's restore is
        // still out): keep the token for it rather than drop it.
        if !isAuthenticated {
            let kept = deliveredPhoneToken.flatMap { WatchCredentialRelay.sameUser($0.userID, identity.userID) ? $0.token : nil }
            if let newest = WatchCredentialRelay.newerDelivered(token, than: kept, userID: identity.userID) {
                deliveredPhoneToken = (newest, identity.userID)
            }
            return
        }
        guard
            isAuthenticated,
            sessionSource == .phone,
            identity.matches(authenticatedUserID: currentUserID, remoteEpoch: nil),
            await api.adoptRenewedAccessToken(token),
            isAuthenticated, sessionSource == .phone
        else {
            return
        }
        KeychainHelper.save(key: "cli_pulse_token", value: token)
        if awaitingPhoneCredentials || !serverOnline {
            awaitingPhoneCredentials = false
            await refreshAll()
        }
    }

    /// 1.61: a token the iPhone delivered before this account's session from
    /// the iPhone was in, adopted now (only if it expires later than the one
    /// held). True when one was.
    @discardableResult
    private func adoptDeliveredPhoneToken() async -> Bool {
        guard
            isAuthenticated, sessionSource == .phone,
            let delivered = deliveredPhoneToken,
            WatchCredentialRelay.sameUser(delivered.userID, currentUserID)
        else { return false }
        deliveredPhoneToken = nil
        guard await api.adoptRenewedAccessToken(delivered.token), isAuthenticated, sessionSource == .phone else {
            return false
        }
        KeychainHelper.save(key: "cli_pulse_token", value: delivered.token)
        return true
    }

    /// A restore of a session from the iPhone that could not be checked:
    /// signed in, from the record, showing the last data the iPhone sent.
    private func commitPhoneSessionOffline(
        _ record: WatchSessionRecord,
        accessToken: String,
        lease: WatchAuthTransitionLease,
        error: Error
    ) async {
        let response = AuthResponse(
            access_token: accessToken,
            refresh_token: nil,
            user: UserDTO(id: record.userID, name: record.name, email: record.email),
            paired: true
        )
        guard await commitAuthenticatedSession(
            response,
            lease: lease,
            remoteIdentity: nil,
            source: .phone
        ) else {
            return
        }
        applyFallbackData(from: WatchSessionManager.shared)
        serverOnline = false
        awaitingPhoneCredentials = (error as? WatchCredentialRelayError) == .waitingForPhone
        lastError = error.localizedDescription
        isLoading = false
        // 1.61: a token the iPhone delivered while this restore was out.
        if await adoptDeliveredPhoneToken() {
            awaitingPhoneCredentials = false
            await refreshAll()
            return
        }
        // The iPhone may have become reachable while this restore was out, and
        // its notice found nothing waiting yet: ask now.
        if awaitingPhoneCredentials, WatchSessionManager.shared.isPhoneReachable {
            await refreshAll()
        }
    }

    // MARK: - WCSession Fallback

    /// Merge cached WCSession data into state.
    ///
    /// - `preferLive = true` (default): only fill empty/nil fields — used on
    ///   launch / when cached data is strictly a fallback for a failing live
    ///   refresh.
    /// - `preferLive = false`: overwrite current values with the cached
    ///   snapshot — used when the iPhone just pushed fresh data and we know
    ///   it's at least as new as whatever the watch has locally.
    func applyFallbackData(from sessionManager: WatchSessionManager, preferLive: Bool = true) {
        guard
            !isDemoMode,
            isAuthenticated,
            !currentUserID.isEmpty,
            let identity =
                sessionManager.lastReceivedIdentity,
            identity.matches(
                authenticatedUserID: currentUserID,
                remoteEpoch: remoteSessionEpoch
            )
        else {
            return
        }
        let overwrite = !preferLive
        if overwrite {
            dashboard =
                sessionManager.lastReceivedDashboard
            // Already projected on the iPhone (an older iPhone build sends
            // raw values); projecting a projected value changes nothing.
            providers = QuotaBindingCap.projectedForDisplay(
                ProviderRoster.shown(sessionManager.lastReceivedProviders)
            )
            providerAccounts = []
            usesLegacyProviderSummary = true
            providerDataLoaded = true
            sessions =
                sessionManager.lastReceivedSessions
            alerts =
                sessionManager.lastReceivedAlerts
            devices =
                sessionManager.lastReceivedDevices
            // An iPhone before 1.61 sends none; the Watch's own list stays.
            if let presence = sessionManager.lastReceivedDevicePresence {
                devicePresence = presence
                devicePresenceAt = sessionManager.lastSyncDate
            }
            lastRefresh =
                sessionManager.lastSyncDate
                    ?? lastRefresh
            // The fresh push came from an authenticated iPhone — if the
            // watch was showing an old lastError banner from a prior 401 /
            // offline attempt, clear it.
            lastError = nil
            serverOnline = true
            return
        }
        if let dash = sessionManager.lastReceivedDashboard, overwrite || dashboard == nil {
            dashboard = dash
        }
        if !sessionManager.lastReceivedProviders.isEmpty, overwrite || providers.isEmpty {
            providers = QuotaBindingCap.projectedForDisplay(
                ProviderRoster.shown(sessionManager.lastReceivedProviders)
            )
            providerAccounts = []
            usesLegacyProviderSummary = true
            providerDataLoaded = true
        }
        if !sessionManager.lastReceivedSessions.isEmpty, overwrite || sessions.isEmpty {
            sessions = sessionManager.lastReceivedSessions
        }
        if !sessionManager.lastReceivedAlerts.isEmpty, overwrite || alerts.isEmpty {
            alerts = sessionManager.lastReceivedAlerts
        }
        if !sessionManager.lastReceivedDevices.isEmpty, overwrite || devices.isEmpty {
            devices = sessionManager.lastReceivedDevices
        }
        if devicePresence == nil, let presence = sessionManager.lastReceivedDevicePresence {
            devicePresence = presence
            devicePresenceAt = sessionManager.lastSyncDate
        }
    }

    nonisolated private static func sessionIdentity(
        from payload: [AnyHashable: Any]
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

    nonisolated private static func sessionEpoch(
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

    // MARK: - v0.2.14 Legacy Token Migration

    /// Pre-v0.2.14 builds wrote auth tokens to UserDefaults in addition to
    /// Keychain. UserDefaults on watchOS is not encrypted at rest, so it is
    /// a real exfiltration surface. This one-shot migration runs at every
    /// launch (idempotent — no-op when UserDefaults is clean), adopts any
    /// stranded UserDefaults values into Keychain only when Keychain is
    /// empty for that key, and clears the UserDefaults entries either way.
    /// Slated for removal in v0.3.x once the install base has rolled over.
    static func migrateLegacyUserDefaultsTokens() {
        let legacyAccessKey = "cli_pulse_watch_auth_token"
        let legacyRefreshKey = "cli_pulse_watch_refresh_token"

        let legacyAccess = UserDefaults.standard.string(forKey: legacyAccessKey)
        let legacyRefresh = UserDefaults.standard.string(forKey: legacyRefreshKey)

        guard legacyAccess != nil || legacyRefresh != nil else {
            return
        }

        // Adopt only if Keychain is empty — Keychain is canonical and we
        // never overwrite a fresh value with a stale UserDefaults copy.
        if let access = legacyAccess, !access.isEmpty,
           (KeychainHelper.load(key: "cli_pulse_token") ?? "").isEmpty {
            KeychainHelper.save(key: "cli_pulse_token", value: access)
        }
        if let refresh = legacyRefresh, !refresh.isEmpty,
           (KeychainHelper.load(key: "cli_pulse_refresh_token") ?? "").isEmpty {
            KeychainHelper.save(key: "cli_pulse_refresh_token", value: refresh)
        }

        // Clear the UserDefaults copies regardless. If a Keychain write
        // somehow failed, the user re-authenticates through the iPhone —
        // same UX as a routine token expiry — and we never leak again.
        UserDefaults.standard.removeObject(forKey: legacyAccessKey)
        UserDefaults.standard.removeObject(forKey: legacyRefreshKey)
    }
}
