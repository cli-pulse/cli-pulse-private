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

    // MARK: - Collection + Sync (fully async)

    private func collectAndSync() async {
        // Async-safe check-and-set to prevent concurrent sync cycles
        guard await syncGuard.tryStart() else {
            logger.debug("Sync already in progress — skipping")
            return
        }
        defer { Task { await syncGuard.finish() } }

        logger.info("Starting collection cycle")

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

        // Step 4.5: Write collector results to app group for main app
        writeCollectorResultsToAppGroup(providerCollection)
        HelperIPC.postSyncNotification()

        guard let config = HelperConfig.load() else {
            logger.info("No helper config found — collected local provider data only")
            HelperIPC.writeStatus(HelperIPC.Status(
                state: .running, lastSync: Date(), helperVersion: "1.0.0"
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
        let providerPlanStatus: [String: String]? = await {
            do { return try await LocalSessionControlClient().hello().providerPlanStatus }
            catch { return nil }
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

            // Update status
            HelperIPC.writeStatus(HelperIPC.Status(
                state: .running, lastSync: Date(), helperVersion: "1.0.0"
            ))

        } catch {
            logger.error("Sync failed: \(error.localizedDescription)")
            HelperIPC.writeStatus(HelperIPC.Status(
                state: .error, lastSync: nil, error: error.localizedDescription, helperVersion: "1.0.0"
            ))
        }
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
                logger.warning("Collector failed for \(providerName): \(error.localizedDescription)")
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
