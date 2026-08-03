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
                    refreshToken: info["refresh_token"] as? String,
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
                remoteIdentity: nil
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

    func applyWatchAuth(
        token: String,
        refreshToken: String?,
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
            refresh_token: refreshToken,
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
            remoteIdentity: identity
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
        let token =
            KeychainHelper.load(key: "cli_pulse_token") ?? ""
        stopRefreshLoop()
        refreshGate.authDidChange()
        KeychainHelper.delete(key: "cli_pulse_token")
        KeychainHelper.delete(
            key: "cli_pulse_refresh_token"
        )
        currentUserID = ""
        remoteSessionEpoch = nil
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
            await authManager.signOut(
                currentAccessToken: token
            )
        }
    }

    private func beginAuthTransition(
        preservingRemoteIdentity:
            WatchSessionIdentity? = nil,
        kind: WatchAuthTransitionKind
    ) async -> WatchAuthTransitionLease? {
        let lease = authTransitionGate.beginTransition()
        otpRequestGeneration &+= 1
        stopRefreshLoop()
        refreshGate.authDidChange()
        if kind.clearsPersistedCredentials {
            KeychainHelper.delete(key: "cli_pulse_token")
            KeychainHelper.delete(
                key: "cli_pulse_refresh_token"
            )
        }
        currentUserID = ""
        remoteSessionEpoch = nil
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
        remoteIdentity: WatchSessionIdentity?
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

        let installed = await api
            .installExternalAuthenticatedSession(
                accessToken: response.access_token,
                refreshToken: response.refresh_token,
                userID: normalizedIdentity.userID,
                transitionGeneration:
                    lease.generation
            )
        guard
            installed,
            authTransitionGate.canCommit(lease)
        else {
            return false
        }

        // Persist only after the shared API actor accepted the same newest
        // transition. A stale OTP/restore result never reaches Keychain.
        KeychainHelper.save(
            key: "cli_pulse_token",
            value: response.access_token
        )
        if let refreshToken = response.refresh_token,
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
        costSummary = CostSummary()
        isLoading = false
        lastError = nil
        lastRefresh = nil
        serverOnline = false
        providerDataLoaded = false
        usesLegacyProviderSummary = true
        refreshTickCount = 0
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
            if fetchDevices, let rawDevices = try? await api.devices() {
                fetchedDevices =
                    WatchDeviceTrim.summaries(from: rawDevices)
            }

            guard refreshGate.canCommit(
                lease,
                isAuthenticated: isAuthenticated
            ) else {
                return
            }
            dashboard = fetchedDashboard
            providers = fetchedProviderSummary.providers
            providerAccounts =
                fetchedProviderSummary.providerAccounts
            usesLegacyProviderSummary =
                fetchedProviderSummary.usedLegacyFallback
            providerDataLoaded = true
            sessions = fetchedSessions
            alerts = fetchedAlerts
            if let fetchedDevices {
                devices = fetchedDevices
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
            userName = "Demo User"
            userEmail = "demo@clipulse.app"
            return
        }

        let token = KeychainHelper.load(key: "cli_pulse_token") ?? ""
        let refreshToken = KeychainHelper.load(key: "cli_pulse_refresh_token")
        guard !token.isEmpty else { return }

        guard let lease = await beginAuthTransition(
            kind: .sessionRestore
        ) else {
            return
        }
        isLoading = true
        do {
            // Validate/refresh the stored credentials in an isolated actor.
            // Only the newest transition may install the result into `api`.
            let candidateAPI = APIClient(token: token)
            await candidateAPI.updateRefreshToken(
                refreshToken
            )
            let response = try await candidateAPI.me()
            guard await commitAuthenticatedSession(
                response,
                lease: lease,
                remoteIdentity: nil
            ) else {
                return
            }
            await refreshAll()
        } catch {
            guard authTransitionGate.canCommit(lease) else {
                return
            }
            if let apiError = error as? APIError,
               WatchSessionRestoreCredentialPolicy
                   .shouldDeletePersistedCredentials(
                       after: apiError
                   ) {
                KeychainHelper.delete(key: "cli_pulse_token")
                KeychainHelper.delete(
                    key: "cli_pulse_refresh_token"
                )
            }
            lastError = error.localizedDescription
        }
        if authTransitionGate.canCommit(lease) {
            isLoading = false
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
            providers =
                sessionManager.lastReceivedProviders
            providerAccounts = []
            usesLegacyProviderSummary = true
            providerDataLoaded = true
            sessions =
                sessionManager.lastReceivedSessions
            alerts =
                sessionManager.lastReceivedAlerts
            devices =
                sessionManager.lastReceivedDevices
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
            providers = sessionManager.lastReceivedProviders
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
