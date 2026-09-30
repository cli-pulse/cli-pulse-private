#if os(macOS)
import Foundation
import AppKit
import CLIPulseCore
import os

/// Core daemon that collects local data and syncs to Supabase.
/// Runs on a background DispatchSourceTimer every N seconds.
final class HelperDaemon {
    private let logger = Logger(subsystem: "yyh.CLI-Pulse.helper", category: "daemon")
    private let runtimeEnvironment: CLIPulseRuntimeEnvironment
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.clipulse.helper.daemon", qos: .utility)
    private lazy var apiClient = HelperAPIClient()
    private var isRunning = false
    /// v1.44 observability (migrate_v0.71): the last collector-outcome map sent
    /// to the backend, and the device it was sent FOR, so an unchanged outcome
    /// costs no RPC. Set only on success, so a transient failure retries on the
    /// next cycle.
    ///
    /// The deviceId is part of the key on purpose: this daemon is long-lived and
    /// re-reads `HelperConfig` every cycle, so a re-pair or account switch swaps
    /// the device underneath us. Keyed on the map alone, an unchanged outcome
    /// would mean the NEW device row never receives a status at all (codex
    /// review — the same trap the app-version report already had to fix).
    private var lastReportedCollectorStatus: (deviceId: String, status: [String: String])?
    /// The previous cycle's computed outcome map, used to require an outcome to
    /// hold for TWO consecutive cycles before it is reported.
    ///
    /// Why: `didWake` fires an immediate collect, and the ~49 collectors run
    /// serially doing network I/O. On wake the network is often not up yet, so
    /// the providers early in registry order (Claude/Codex/Gemini — the
    /// highest-value ones) throw while later ones succeed as connectivity
    /// returns. Reporting that sweep would overwrite the device's authoritative
    /// diagnostic with a wake artifact — and since the row carries no timestamp,
    /// triage cannot tell it from the persistent auth-expired fault this field
    /// exists to find. It self-corrects next cycle, unless the user shuts the lid
    /// first. Confirming twice also stops a single flaky endpoint from flipping
    /// the whole-map comparison every cycle, which would defeat the
    /// no-RPC-in-steady-state property. (Independent adversarial review.)
    private var pendingCollectorStatus: [String: String]?
    /// Accessed only from `queue` or `syncActor` to prevent concurrent sync cycles.
    private let syncGuard = SyncGuard()
    private var suspendCount = 0

    /// Actor that replaces NSLock for async-safe mutual exclusion.
    private actor SyncGuard {
        private var isSyncing = false

        /// Returns `true` if this call acquired the lock (was not already syncing).
        func tryStart() -> Bool {
            guard !isSyncing else { return false }
            isSyncing = true
            return true
        }

        func finish() { isSyncing = false }
    }

    init(runtimeEnvironment: CLIPulseRuntimeEnvironment = .current) {
        self.runtimeEnvironment = runtimeEnvironment
    }

    /// Default sync interval (seconds). Can be overridden via shared UserDefaults.
    private var syncInterval: Int {
        let defaults = UserDefaults(suiteName: HelperIPC.suiteName)
        let stored = defaults?.integer(forKey: HelperIPC.syncIntervalKey) ?? 0
        return stored >= 60 ? stored : 120
    }

    private var providerAccountsWriteV2Enabled: Bool {
        UserDefaults(suiteName: HelperIPC.suiteName)?.bool(
            forKey: HelperIPC.providerAccountsWriteV2Key
        ) ?? false
    }

    func start() {
        guard runtimeEnvironment.allowsLoginItemHelperStartup else {
            logger.fault(
                "Blocked daemon startup outside the exact production helper runtime"
            )
            return
        }
        guard !isRunning else { return }
        isRunning = true
        logger.info("Daemon starting, interval=\(self.syncInterval)s")

        // Initial sync immediately
        Task { await collectAndSync() }

        // Set up repeating timer
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + .seconds(syncInterval), repeating: .seconds(syncInterval))
        source.setEventHandler { [weak self] in
            Task { [weak self] in await self?.collectAndSync() }
        }
        source.resume()
        timer = source

        // Sleep/wake handling
        let wsnc = NSWorkspace.shared.notificationCenter
        wsnc.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        wsnc.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)

        // The app changed the local-scan answer: act on it now, not at the
        // next tick up to two minutes later.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(helperInputsDidChange),
            name: HelperIPC.helperInputsDidChangeNotificationName,
            object: nil
        )
    }

    func stop() {
        // Resume before cancel to avoid crash on suspended source
        if suspendCount > 0 {
            timer?.resume()
            suspendCount = 0
        }
        timer?.cancel()
        timer = nil
        isRunning = false
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        logger.info("Daemon stopped")
    }

    // MARK: - Sleep/Wake

    @objc private func willSleep() {
        guard suspendCount == 0 else { return }
        suspendCount += 1
        timer?.suspend()
        logger.info("System sleeping — paused timer")
    }

    @objc private func didWake() {
        guard suspendCount > 0 else { return }
        suspendCount -= 1
        timer?.resume()
        logger.info("System woke — resumed timer + immediate sync")
        Task { [weak self] in await self?.collectAndSync() }
    }

    @objc private func helperInputsDidChange() {
        logger.info("Local-scan answer changed — running a cycle now")
        Task { [weak self] in await self?.collectAndSync() }
    }

    // MARK: - The local-scan answer

    /// May this cycle read the Mac? Asked from the answer the app copies to
    /// the app group (`LocalScanConsentStore.mirror`), read afresh each time
    /// because the app changes it while this process runs. See
    /// `LocalCollectionPolicy.helperCycle`: this process has no sign-in, and a
    /// pairing the app has not signed out of stands in for one.
    private func localScanCycle(
        isSignedIn: @autoclosure () -> Bool
    ) -> LocalCollectionPolicy.HelperCycle {
        let mirrored = UserDefaults(suiteName: HelperIPC.suiteName)
            .flatMap(LocalScanConsentStore.loadMirror)
        return LocalCollectionPolicy.helperCycle(
            mirroredConsent: mirrored?.consent,
            isSignedIn: isSignedIn()
        )
    }

    /// Whether the app last said it is signed out (`HelperIPC.appSignedOutKey`).
    /// The pairing outlives a sign-out, so it cannot say this itself.
    private var appSignedOut: Bool {
        UserDefaults(suiteName: HelperIPC.suiteName).map(HelperIPC.isAppSignedOut) ?? false
    }

    /// A cycle the answer does not allow. Nothing is read — no scan, no
    /// collector, no Keychain, no provider — and nothing is sent: not the
    /// sync and not the heartbeat either.
    ///
    /// Why not even a heartbeat: `helper_heartbeat` writes this cycle's
    /// session count to the device row, and a zero the helper did not look
    /// for would overwrite the last real one; `helper_sync` with no sessions
    /// marks this Mac's running sessions Ended. Left alone, the device row
    /// keeps what it last had and ages, which is how the other devices show
    /// a Mac that is not reporting, and that is what this Mac is doing.
    ///
    /// The status says why, so Settings does not show a helper that does
    /// nothing as running in green (`HelperStatusLine`).
    private func skipCycle(_ cycle: LocalCollectionPolicy.HelperCycle) {
        // An outcome from before the pause is not a second sighting of one
        // after it (see `pendingCollectorStatus`).
        pendingCollectorStatus = nil
        switch cycle {
        case .collect:
            return
        case .paused:
            logger.info("Local scan not allowed — cycle skipped")
            HelperIPC.writeStatus(HelperIPC.Status(
                state: .running, helperVersion: "1.0.0",
                pauseCode: HelperIPC.PauseCode.localScanOff
            ))
        case .awaitingAnswer:
            // A helper that started before the app has run since this
            // version was installed: the app copies the answer as it starts.
            logger.info("No local-scan answer from the app yet — cycle skipped")
            HelperIPC.writeStatus(HelperIPC.Status(
                state: .running, helperVersion: "1.0.0"
            ))
        }
    }

    // MARK: - Collection + Sync (fully async)

    private func collectAndSync() async {
        // Async-safe check-and-set to prevent concurrent sync cycles
        guard await syncGuard.tryStart() else {
            logger.debug("Sync already in progress — skipping")
            return
        }
        defer { Task { await syncGuard.finish() } }

        logger.info("Starting collection cycle")

        // Step 0: the local-scan answer, before anything is read. For
        // `.undecided` the account decides; the pairing is read (a Keychain
        // read) only then, and not once the app has signed out.
        let cycle = localScanCycle(isSignedIn: !appSignedOut && HelperConfig.load() != nil)
        guard cycle == .collect else {
            skipCycle(cycle)
            return
        }

        // Step 1: Device metrics
        let device = DeviceMetrics.collect()
        logger.debug("Device: cpu=\(device.cpuUsage)%, mem=\(device.memoryUsage)%")

        // Step 2: Sessions via LocalScanner
        let scanResult = LocalScanner.shared.scan()
        logger.debug("Scanned \(scanResult.sessions.count) sessions")

        // Step 3: Alerts.
        // Iter2 fix: pass the helper's stable device_id so the device-CPU
        // alert id is `cpu-spike-<deviceID>-<hour>` instead of the global
        // `cpu-spike-global` static id (which never re-fired after first
        // resolve and collided across multi-device users). Falls back to the
        // host name when the helper is not yet paired (matches previous
        // behavior on the unpaired path).
        let alertDeviceID = HelperConfig.load()?.deviceId
            ?? ProcessInfo.processInfo.hostName
        let alerts = AlertGenerator.generate(
            device: device,
            sessions: scanResult.sessions,
            sessionCPU: scanResult.sessionCPU,
            deviceID: alertDeviceID
        )

        // Step 4: Provider quotas via collectors
        let providerCollection = await collectProviderQuotas()
        let collectorStatus = providerCollection.collectorStatus

        // Asked again: the collectors take a while, and a "Not now" or a
        // sign-out meanwhile must stop this cycle too. What it read is
        // dropped, not written for the app or sent.
        //
        // A pairing the app has signed out of is not used: nothing is sent to
        // the account, whatever the answer. A yes still lets the helper collect
        // for the app on this Mac, as for local mode.
        let pairing = appSignedOut ? nil : HelperConfig.load()
        let cycleAfterCollecting = localScanCycle(isSignedIn: pairing != nil)
        guard cycleAfterCollecting == .collect else {
            skipCycle(cycleAfterCollecting)
            return
        }

        // Step 4.5: Write collector results to app group for main app
        writeCollectorResultsToAppGroup(providerCollection)
        HelperIPC.postSyncNotification()

        guard let config = pairing else {
            logger.info("Not paired, or the app is signed out — collected local provider data only")
            // No `lastSync`: nothing was synced, and Settings › Advanced reads
            // any `lastSync` as "Synced just now". It now says "Running".
            HelperIPC.writeStatus(HelperIPC.Status(
                state: .running, lastSync: nil, helperVersion: "1.0.0"
            ))
            return
        }

        // Step 5-6: Sync to Supabase
        // Respect the user's enabled-set here too: sessions for providers the
        // user (or the tier-migration) disabled are local observations only,
        // not shipped to Supabase. When no config suite is readable (very
        // first launch before main app has written), pass sessions through
        // unfiltered rather than losing data silently.
        let savedProviderConfigs: [ProviderConfig]? = {
            guard let defaults = UserDefaults(suiteName: HelperIPC.suiteName),
                  let data = defaults.data(forKey: HelperIPC.providerConfigsKey),
                  let saved = try? JSONDecoder().decode([ProviderConfig].self, from: data)
            else { return nil }
            return saved
        }()
        let enabledProviderNames = savedProviderConfigs.map {
            Set($0.filter(\.isEnabled).map(\.kind.rawValue))
        }
        let filteredSessions: [SessionRecord] = {
            guard let enabled = enabledProviderNames else { return scanResult.sessions }
            return scanResult.sessions.filter { enabled.contains($0.provider) }
        }()
        if filteredSessions.count != scanResult.sessions.count {
            logger.info("Filtered \(scanResult.sessions.count - filteredSessions.count) sessions from disabled providers")
        }
        let sessionDicts = filteredSessions.map { sessionToDict($0) }
        let syncableAccountIDs =
            ProviderAccountSyncOwnership.accountIDs(
                in: savedProviderConfigs ?? [],
                ownedBy: config.userId
            )
        let syncableAccounts =
            providerCollection.accounts.filter {
                syncableAccountIDs.contains($0.accountID)
            }
        let providerTiers = HelperAPIClient.legacyProviderTiers(
            from: providerCollection.accounts,
            configs: savedProviderConfigs ?? [],
            ownedBy: config.userId
        )
        let providerRemaining: [String: Int] = providerTiers.compactMapValues { dict in
            (dict as? [String: Any])?["remaining"] as? Int
        }

        // v0.60: source the per-provider managed-session plan map from the local
        // spawn helper's UDS `hello` (the single source of truth — reuses the real
        // ProviderSpawner logic instead of a divergent parser) and forward it on the
        // heartbeat so phones can warn before an off-plan managed session. Best-effort:
        // if no local helper is listening, pass nil → the RPC omits the param → the
        // server preserves the last-known value (never clobbers to {}).
        //
        // v1.55: `hello` reads ~/.codex/auth.json for this only when the
        // caller says the local-scan answer allows reading this Mac
        // (`localScanAllowed`). This is a collecting cycle, which is what the
        // answer gates (the cycle gate added by PR #626 returns before any of
        // this on a "Not now"), so it says yes.
        let providerPlanStatus: [String: String]? = await {
            do {
                return try await LocalSessionControlClient()
                    .hello(localScanAllowed: true).providerPlanStatus
            } catch { return nil }
        }()

        do {
            // Heartbeat
            try await apiClient.heartbeat(
                config: config,
                cpuUsage: device.cpuUsage,
                memoryUsage: device.memoryUsage,
                activeSessionCount: scanResult.activeSessionCount,
                providerPlanStatus: providerPlanStatus
            )

            // NOTE: the app-version report (migrate_v0.70) deliberately does
            // NOT happen here. macOS does not restart this LoginItem after an
            // in-place app update, so this process can still be the OLD binary
            // — it would report a stale version, or (for any build predating
            // the feature) never report at all. `AppState` reports it from the
            // main app instead, which is guaranteed to be the new version.
            //
            // Collector status (migrate_v0.71) DOES belong here: this daemon is
            // the process that actually runs the collectors, so it is the only
            // thing that knows why a provider produced nothing. Re-reported only
            // when the outcome map CHANGES, so a steady state costs no RPCs.
            // Best-effort — never break the sync that follows.
            // Confirm-twice (see `pendingCollectorStatus`): only an outcome that
            // held across two consecutive cycles is worth writing as this
            // device's diagnostic.
            let heldTwice = (pendingCollectorStatus == collectorStatus)
            pendingCollectorStatus = collectorStatus
            if heldTwice,
               lastReportedCollectorStatus?.deviceId != config.deviceId
                || lastReportedCollectorStatus?.status != collectorStatus {
                do {
                    try await apiClient.reportCollectorStatus(config: config, status: collectorStatus)
                    lastReportedCollectorStatus = (deviceId: config.deviceId, status: collectorStatus)
                } catch {
                    logger.debug("collector-status report failed (retrying next cycle): \(error.localizedDescription, privacy: .public)")
                }
            }

            // Sync
            let legacyProviderRemaining =
                providerAccountsWriteV2Enabled
                ? [String: Int]()
                : providerRemaining
            let legacyProviderTiers =
                providerAccountsWriteV2Enabled
                ? [String: Any]()
                : providerTiers
            let result = try await apiClient.sync(
                config: config,
                sessions: sessionDicts,
                alerts: alerts,
                providerRemaining: legacyProviderRemaining,
                providerTiers: legacyProviderTiers
            )
            logger.info("Synced \(result.sessionsSynced) sessions, \(result.alertsSynced) alerts")

            // In v2 mode helper_sync carries sessions/alerts only; provider
            // quotas have exactly one writer below. Failure-soft: an older
            // backend missing the staged RPC must not break session, alert, or
            // heartbeat sync, but it must not regain projection ownership.
            if providerAccountsWriteV2Enabled,
               !syncableAccounts.isEmpty {
                do {
                    let synced = try await apiClient
                        .syncProviderAccountQuotas(
                            config: config,
                            accounts: syncableAccounts,
                            observedAt: providerCollection.observedAt
                        )
                    logger.info(
                        "Synced \(synced) provider account quotas"
                    )
                } catch {
                    logger.warning(
                        "Provider account v2 sync failed; response details omitted"
                    )
                }
            } else if providerAccountsWriteV2Enabled,
                      !providerCollection.accounts.isEmpty {
                logger.warning(
                    "Provider account v2 sync paused: no local accounts are owned by the paired CLIPulse user"
                )
            }

            // Update status. `deviceId` says which pairing this was: the app
            // must not read a failure of a device it has since replaced as a
            // failure of the current one (`ThisMacPairing`).
            HelperIPC.writeStatus(HelperIPC.Status(
                state: .running, lastSync: Date(), helperVersion: "1.0.0",
                deviceId: config.deviceId
            ))

        } catch {
            // Store a token, not text: this process never sees the in-app
            // language, so the app renders the token in its own. The English
            // detail is for the log (the HTTP body was already logged where it
            // was thrown, which is why it is left out here).
            let code = HelperSyncFailure.code(for: error)
            let detail = Self.englishDetail(for: error)
            logger.error("Sync failed [\(code, privacy: .public)]: \(detail, privacy: .public)")
            HelperIPC.writeStatus(HelperIPC.Status(
                state: .error, lastSync: nil, error: detail, errorCode: code, helperVersion: "1.0.0",
                deviceId: config.deviceId
            ))
        }
    }

    /// The failure without its HTTP body, in English whatever the system
    /// language: the case name and status for helper errors, domain and code
    /// for everything else.
    private static func englishDetail(for error: Error) -> String {
        if let helperError = error as? HelperAPIError {
            if case let .httpError(status, function, _) = helperError {
                return "\(function) HTTP \(status)"
            }
            return String(describing: helperError)
        }
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)"
    }

    // MARK: - Provider Quota Collection

    private struct ProviderQuotaCollection {
        let accounts: [HelperIPC.CollectorAccountPayload]
        let providers: [String: HelperIPC.CollectorUsagePayload]
        let collectorStatus: [String: String]
        let observedAt: Date
    }

    /// Run the same collectors the main app uses once per enabled account.
    /// The provider dictionary remains a deterministic compatibility
    /// projection for the existing helper_sync RPC and old main apps. Collector
    /// status remains a provider-level diagnostic, using a deterministic
    /// worst-account projection when two accounts share a provider.
    private func collectProviderQuotas() async -> ProviderQuotaCollection {
        reportClaudeKeychainAccess()
        var accountResults: [HelperIPC.CollectorAccountPayload] = []
        var providerProjection: [String: HelperIPC.CollectorUsagePayload] = [:]
        var status: [String: String] = [:]
        var disabledCount = 0
        var unavailableCount = 0

        // Read provider configs from shared app group (written by main app)
        var configs: [ProviderConfig] = ProviderConfig.defaults()
        var hasPersistentAccountIDs = false
        if let defaults = UserDefaults(suiteName: HelperIPC.suiteName),
           let data = defaults.data(forKey: HelperIPC.providerConfigsKey),
           let saved = try? JSONDecoder().decode([ProviderConfig].self, from: data) {
            configs = saved
            hasPersistentAccountIDs = true
            // Hydrate secrets from Keychain
            for i in configs.indices {
                configs[i].loadSecrets()
            }
        }

        let orderedConfigs = configs.sorted {
            if $0.sortOrder != $1.sortOrder {
                return $0.sortOrder < $1.sortOrder
            }
            if $0.kind.rawValue != $1.kind.rawValue {
                return $0.kind.rawValue < $1.kind.rawValue
            }
            return $0.accountID.uuidString < $1.accountID.uuidString
        }

        logger.info("Inspecting \(orderedConfigs.count) account configs")
        for config in orderedConfigs {
            let providerName = config.kind.rawValue
            guard config.isEnabled else {
                logger.debug("Skipping \(providerName): disabled in user config")
                disabledCount += 1
                continue
            }
            guard let collector = CollectorRegistry.collector(
                for: config.kind,
                config: config
            ) else {
                logger.debug("Skipping \(providerName): isAvailable=false")
                // Enabled but nothing to read — CLI not installed, or no
                // credentials on this machine. Counted, not listed: with every
                // ProviderKind enabled by default this is the overwhelming
                // majority (~47 of ~50) and would swamp the row.
                unavailableCount += 1
                continue
            }

            let collectionStartedAt = Date()
            do {
                let collectorResult = try await collector.collect(config: config)
                let usage = collectorResult.usage
                let payload = HelperIPC.CollectorUsagePayload(
                    quota: usage.quota,
                    remaining: usage.remaining,
                    todayUsage: usage.today_usage,
                    weekUsage: usage.week_usage,
                    statusText: usage.status_text,
                    planType: usage.plan_type,
                    resetTime: usage.reset_time,
                    tiers: usage.tiers,
                    metadata: usage.metadata.map(HelperIPC.CollectorMetadataPayload.init)
                )

                // Lowest sortOrder wins the provider compatibility projection.
                if providerProjection[providerName] == nil {
                    providerProjection[providerName] = payload
                }

                // Never publish an ephemeral UUID made by ProviderConfig.defaults().
                // Account rows start only after the main app has written migrated,
                // stable ProviderConfig values into the app group.
                if hasPersistentAccountIDs {
                    accountResults.append(
                        HelperIPC.CollectorAccountPayload(
                            accountID: config.accountID,
                            provider: providerName,
                            accountLabel: config.accountLabel,
                            planOverride: config.planOverride,
                            planOverrideUpdatedAt:
                                config.planOverrideUpdatedAt,
                            planDetectionStartedAt:
                                collectionStartedAt,
                            dataKind: helperDataKind(collectorResult.dataKind),
                            usage: payload
                        )
                    )
                }
                logger.debug("Collected \(providerName): \(usage.tiers.count) tiers")
                // ok vs empty — the load-bearing distinction for this whole
                // diagnostic. Lives in CLIPulseCore so it is unit-testable; see
                // `classifyCollectorOutcome` for why `status_text` must not be
                // part of the test (it is always populated, even on the exact
                // no-data paths we are hunting).
                let candidateStatus =
                    CollectorRunner.classify(collectorResult).telemetryToken
                status[providerName] =
                    HelperAPIClient.aggregateCollectorStatus(
                        current: status[providerName],
                        candidate: candidateStatus
                    )
            } catch {
                logger.warning("Collector failed for \(providerName): \(CollectorError.logText(for: error))")
                status[providerName] =
                    HelperAPIClient.aggregateCollectorStatus(
                        current: status[providerName],
                        candidate: "error"
                    )
            }
        }

        // Totals for the providers deliberately left out of the map above, so a
        // reader can tell "3 real providers, 47 not installed" from "3 real
        // providers, 47 switched off by the user".
        status["_counts"] = "d=\(disabledCount) u=\(unavailableCount) p=\(status.count)"

        return ProviderQuotaCollection(
            accounts: accountResults,
            providers: providerProjection,
            collectorStatus: status,
            observedAt: Date()
        )
    }

    /// Settings › Privacy's Claude keychain switches, as this helper's
    /// collectors apply them (`PrivacySettings.followAppCopy`, set at launch):
    /// recorded in the app group so Settings can say whether this helper
    /// follows them (`HelperClaudeKeychainConfirmation`), and logged when it
    /// changes. A decision, not a promise about a whole cycle: the collectors
    /// ask again at each read, so a switch turned on mid-cycle stops the next
    /// read.
    ///
    /// Called at the start of every collecting cycle, and by
    /// `HelperAppDelegate` when the helper starts, when the app changes a
    /// switch (`HelperInputs.didChangeNotificationName`), and when the app asks
    /// at its launch (`HelperPrivacyInputs.reportRequestNotificationName`).
    /// Those three pass `announce`, which posts
    /// `HelperPrivacyInputs.didReportNotificationName` so Settings reads the
    /// report again at once; a cycle's own `didSync` covers the per-cycle one.
    func reportClaudeKeychainAccess(announce: Bool = false) {
        let access = PrivacySettings.shared.claudeKeychainAccess
        guard let defaults = UserDefaults(suiteName: HelperIPC.suiteName) else { return }
        if HelperPrivacyInputs.recordHelperReport(access, to: defaults) {
            logClaudeKeychainAccess(access)
        }
        if announce {
            HelperInputs.postDidReport()
        }
    }

    private func logClaudeKeychainAccess(_ access: ClaudeKeychainAccess) {
        switch access {
        case .read:
            logger.info("Claude Code keychain item: read when needed (both Privacy switches off)")
        case .skippedStrictPrivacyMode:
            logger.info("Claude Code keychain item: skipped (Strict privacy mode is on)")
        case .skippedBySetting:
            logger.info("Claude Code keychain item: skipped (Skip Claude Code keychain access is on)")
        case .skippedAwaitingApp:
            logger.info("Claude Code keychain item: skipped until the app copies its Privacy switches")
        }
    }

    // MARK: - App Group Collector Sharing

    private func writeCollectorResultsToAppGroup(_ collection: ProviderQuotaCollection) {
        let envelope = HelperIPC.CollectorResultsEnvelopeV2(
            timestamp: sharedISO8601Formatter.string(
                from: collection.observedAt
            ),
            accounts: collection.accounts,
            providers: collection.providers
        )
        do {
            let data = try HelperIPC.encodeCollectorResultsV2(envelope)
            HelperIPC.writeCollectorResults(data)
            logger.debug(
                "Wrote \(collection.accounts.count) account results and \(collection.providers.count) provider projections to app group"
            )
        } catch {
            logger.error(
                "Failed to encode collector results for app group write: \(error.localizedDescription)"
            )
        }
    }

    private func helperDataKind(
        _ kind: CollectorDataKind
    ) -> HelperIPC.CollectorDataKind {
        switch kind {
        case .quota: return .quota
        case .credits: return .credits
        case .statusOnly: return .statusOnly
        }
    }

    // MARK: - Helpers

    private func sessionToDict(_ session: SessionRecord) -> [String: Any] {
        var dict: [String: Any] = [
            "id": session.id,
            "name": session.name,
            "provider": session.provider,
            "project": session.project,
            "status": session.status,
            "total_usage": session.total_usage,
            "exact_cost": session.estimated_cost,
            "requests": session.requests,
            "error_count": session.error_count,
            "collection_confidence": session.collection_confidence ?? "medium",
            "started_at": session.started_at,
            "last_active_at": session.last_active_at,
        ]
        // Yield score plumbing: omit key entirely when nil so server preserves
        // any previously-stored hash via COALESCE in helper_sync.
        if let projectHash = session.project_hash {
            dict["project_hash"] = projectHash
        }
        return dict
    }
}
#endif
