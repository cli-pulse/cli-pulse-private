#if os(macOS)
import Foundation
import AppKit
import CLIPulseCore
import os

/// Core daemon that collects local data and syncs to Supabase.
/// Runs on a background DispatchSourceTimer every N seconds.
final class HelperDaemon {
    private let logger = Logger(subsystem: "yyh.CLI-Pulse.helper", category: "daemon")
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.clipulse.helper.daemon", qos: .utility)
    private let apiClient = HelperAPIClient()
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

    /// Default sync interval (seconds). Can be overridden via shared UserDefaults.
    private var syncInterval: Int {
        let defaults = UserDefaults(suiteName: HelperIPC.suiteName)
        let stored = defaults?.integer(forKey: HelperIPC.syncIntervalKey) ?? 0
        return stored >= 60 ? stored : 120
    }

    func start() {
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
        let (providerTiers, collectorStatus) = await collectProviderQuotas()

        // Step 4.5: Write collector results to app group for main app
        writeCollectorResultsToAppGroup(providerTiers)
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
        let enabledProviderNames: Set<String>? = {
            guard let defaults = UserDefaults(suiteName: HelperIPC.suiteName),
                  let data = defaults.data(forKey: HelperIPC.providerConfigsKey),
                  let saved = try? JSONDecoder().decode([ProviderConfig].self, from: data)
            else { return nil }
            return Set(saved.filter(\.isEnabled).map(\.kind.rawValue))
        }()
        let filteredSessions: [SessionRecord] = {
            guard let enabled = enabledProviderNames else { return scanResult.sessions }
            return scanResult.sessions.filter { enabled.contains($0.provider) }
        }()
        if filteredSessions.count != scanResult.sessions.count {
            logger.info("Filtered \(scanResult.sessions.count - filteredSessions.count) sessions from disabled providers")
        }
        let sessionDicts = filteredSessions.map { sessionToDict($0) }
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
            let result = try await apiClient.sync(
                config: config,
                sessions: sessionDicts,
                alerts: alerts,
                providerRemaining: providerRemaining,
                providerTiers: providerTiers
            )
            logger.info("Synced \(result.sessionsSynced) sessions, \(result.alertsSynced) alerts")

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

    /// Run the same collectors the main app uses, producing tier data for Supabase.
    /// Runs every enabled provider collector.
    ///
    /// Also returns a per-provider outcome map for backend diagnostics
    /// (migrate_v0.71). The outcomes already existed as control flow — they were
    /// just logged locally, so a device that delivers no usage data looked
    /// identical from the backend whether its providers were missing, disabled,
    /// or actively failing.
    ///
    /// What lands in the map, and why NOT everything: `ProviderConfig.defaults()`
    /// enables EVERY registered `ProviderKind`, so a stock install runs ~50
    /// collectors of which the user realistically has two or three actually
    /// installed. Emitting all of them would blow the RPC's per-row entry cap and
    /// silently drop whichever providers sort last — the payload would look
    /// complete while hiding real failures (codex review). So the map carries
    /// only providers that genuinely exist on this machine (`ok` / `empty` /
    /// `error`), plus a single `_counts` key so the totals — including how many
    /// were skipped as disabled or absent — are never lost.
    private func collectProviderQuotas() async -> (tiers: [String: Any], status: [String: String]) {
        var result: [String: Any] = [:]
        var status: [String: String] = [:]
        var disabledCount = 0
        var unavailableCount = 0

        // Read provider configs from shared app group (written by main app)
        var configs: [ProviderConfig] = ProviderConfig.defaults()
        if let defaults = UserDefaults(suiteName: HelperIPC.suiteName),
           let data = defaults.data(forKey: HelperIPC.providerConfigsKey),
           let saved = try? JSONDecoder().decode([ProviderConfig].self, from: data) {
            configs = saved
            // Hydrate secrets from Keychain
            for i in configs.indices {
                configs[i].loadSecrets()
            }
        }

        logger.info("Running \(CollectorRegistry.collectors.count) registered collectors")
        for collector in CollectorRegistry.collectors {
            let providerName = collector.kind.rawValue
            // Run collector for any enabled provider (not just active sessions)
            // so quota data is available even when no session is running.

            let config = configs.first(where: { $0.kind == collector.kind }) ?? ProviderConfig(kind: collector.kind)
            // Respect the user's enabled-set. The tier-migration auto-disables
            // extra providers for free users, and users can also disable
            // providers manually. Before this filter, the helper would still
            // collect quota for all 26 kinds and push them to Supabase, which
            // defeats the migration's intent and wastes network + battery.
            // (v1.10.4 free-tier fix, 2026-04-23.)
            if !config.isEnabled {
                logger.debug("Skipping \(providerName): disabled in user config")
                disabledCount += 1
                continue
            }
            let available = collector.isAvailable(config: config)
            if !available {
                logger.debug("Skipping \(providerName): isAvailable=false")
                // Enabled but nothing to read — CLI not installed, or no
                // credentials on this machine. Counted, not listed: with every
                // ProviderKind enabled by default this is the overwhelming
                // majority (~47 of ~50) and would swamp the row.
                unavailableCount += 1
                continue
            }

            do {
                let collectorResult = try await collector.collect(config: config)
                let usage = collectorResult.usage

                var tierData: [String: Any] = [
                    "quota": usage.quota ?? 100,
                    "remaining": usage.remaining ?? 100,
                    "today_usage": usage.today_usage,
                    "week_usage": usage.week_usage,
                    "status_text": usage.status_text,
                ]
                if let planType = usage.plan_type { tierData["plan_type"] = planType }
                if let resetTime = usage.reset_time { tierData["reset_time"] = resetTime }

                let tiers: [[String: Any]] = usage.tiers.map { tier in
                    var d: [String: Any] = [
                        "name": tier.name,
                        "quota": tier.quota,
                        "remaining": tier.remaining,
                    ]
                    if let rt = tier.reset_time { d["reset_time"] = rt }
                    return d
                }
                tierData["tiers"] = tiers

                result[providerName] = tierData
                logger.debug("Collected \(providerName): \(usage.tiers.count) tiers")
                // ok vs empty — the load-bearing distinction for this whole
                // diagnostic. Lives in CLIPulseCore so it is unit-testable; see
                // `classifyCollectorOutcome` for why `status_text` must not be
                // part of the test (it is always populated, even on the exact
                // no-data paths we are hunting).
                status[providerName] = HelperAPIClient.classifyCollectorOutcome(
                    tiersCount: usage.tiers.count,
                    quota: usage.quota,
                    remaining: usage.remaining,
                    todayUsage: usage.today_usage,
                    weekUsage: usage.week_usage
                )
            } catch {
                logger.warning("Collector failed for \(providerName): \(error.localizedDescription)")
                status[providerName] = "error"
            }
        }

        // Totals for the providers deliberately left out of the map above, so a
        // reader can tell "3 real providers, 47 not installed" from "3 real
        // providers, 47 switched off by the user".
        status["_counts"] = "d=\(disabledCount) u=\(unavailableCount) p=\(status.count)"

        return (tiers: result, status: status)
    }

    // MARK: - App Group Collector Sharing

    private func writeCollectorResultsToAppGroup(_ providerTiers: [String: Any]) {
        // Wrap with timestamp so main app can reject stale data
        let payload: [String: Any] = [
            "timestamp": sharedISO8601Formatter.string(from: Date()),
            "providers": providerTiers,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            HelperIPC.writeCollectorResults(data)
            logger.debug("Wrote \(providerTiers.count) collector results to app group")
        } else {
            logger.error("Failed to encode collector results for app group write")
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
