import Foundation

internal struct DemoData {
    let dashboard: DashboardSummary
    let providers: [ProviderUsage]
    let sessions: [SessionRecord]
    let devices: [DeviceRecord]
    let alerts: [AlertRecord]
}

internal enum DemoDataProvider {
    static func generate() -> DemoData {
        let formatter = sharedISO8601Formatter
        let now = Date()

        func timestamp(_ offset: TimeInterval = 0) -> String {
            formatter.string(from: now.addingTimeInterval(offset))
        }

        func trend(base: Int) -> [UsagePoint] {
            (0..<12).map { index in
                UsagePoint(
                    timestamp: timestamp(Double(-11 + index) * 3600),
                    value: base + Int.random(in: -2000...2000)
                )
            }
        }

        // Codex carries its weekly window as a real tier, named the way
        // CodexCollector names it, so the quota alert below comes out of the
        // generator with a tier name the tier mapper translates. Without a tier
        // the generator falls back to the synthetic "Overall", which is left
        // untranslated on purpose (scripts/quota_tier_names.json).
        let providers = [
            ProviderUsage(provider: "Codex", today_usage: 85900, week_usage: 462000,
                          estimated_cost_today: 1.03, estimated_cost_week: 5.54,
                          cost_status_today: "Estimated", cost_status_week: "Estimated",
                          quota: 500000, remaining: 38000,
                          tiers: [TierDTO(name: "Weekly", quota: 500000, remaining: 38000)],
                          status_text: "92% used",
                          trend: trend(base: 85000), recent_sessions: ["ios-dashboard"], recent_errors: []),
            ProviderUsage(provider: "Gemini", today_usage: 43400, week_usage: 214000,
                          estimated_cost_today: 0.35, estimated_cost_week: 1.71,
                          cost_status_today: "Estimated", cost_status_week: "Estimated",
                          quota: 300000, remaining: 86000, status_text: "71% used",
                          trend: trend(base: 43000), recent_sessions: ["helper-heartbeat"], recent_errors: []),
            ProviderUsage(provider: "Claude", today_usage: 24800, week_usage: 132000,
                          estimated_cost_today: 0.37, estimated_cost_week: 1.98,
                          cost_status_today: "Estimated", cost_status_week: "Estimated",
                          quota: 250000, remaining: 118000, status_text: "53% used",
                          trend: trend(base: 24000), recent_sessions: ["provider-adapters"], recent_errors: []),
        ]

        // Session names are identifiers, the way a real one reads (a command or
        // a project), not English sentences: they are data, shown as-is in
        // every language, and they reappear inside the alert titles below.
        let sessions = [
            SessionRecord(id: "s1", name: "ios-dashboard", provider: "Codex",
                          project: "cli-pulse-ios", device_name: "MacBook Pro",
                          started_at: timestamp(-7200), last_active_at: timestamp(),
                          status: "running", total_usage: 24500, estimated_cost: 0.29,
                          cost_status: "Estimated", requests: 142, error_count: 0,
                          collection_confidence: "high"),
            SessionRecord(id: "s2", name: "helper-heartbeat", provider: "Gemini",
                          project: "cli-pulse-helper", device_name: "lab-server-01",
                          started_at: timestamp(-3600), last_active_at: timestamp(),
                          status: "syncing", total_usage: 12800, estimated_cost: 0.10,
                          cost_status: "Estimated", requests: 87, error_count: 0,
                          collection_confidence: "medium"),
            SessionRecord(id: "s3", name: "api-gateway", provider: "Codex",
                          project: "backend-api", device_name: "build-box",
                          started_at: timestamp(-7200), last_active_at: timestamp(-3600),
                          status: "failed", total_usage: 8400, estimated_cost: 0.10,
                          cost_status: "Estimated", requests: 56, error_count: 3,
                          collection_confidence: "high"),
            SessionRecord(id: "s4", name: "provider-adapters", provider: "Claude",
                          project: "provider-layer", device_name: "MacBook Pro",
                          started_at: timestamp(-3600), last_active_at: timestamp(),
                          status: "running", total_usage: 6200, estimated_cost: 0.09,
                          cost_status: "Estimated", requests: 38, error_count: 0,
                          collection_confidence: "low"),
        ]

        let devices = [
            DeviceRecord(id: "d1", name: "MacBook Pro", type: "laptop", system: "macOS 15.4",
                         status: "online", last_sync_at: timestamp(), helper_version: "0.2.0",
                         current_session_count: 2, cpu_usage: 42, memory_usage: 68),
            DeviceRecord(id: "d2", name: "lab-server-01", type: "server", system: "Ubuntu 24.04",
                         status: "online", last_sync_at: timestamp(), helper_version: "0.2.0",
                         current_session_count: 1, cpu_usage: 23, memory_usage: 45),
            DeviceRecord(id: "d3", name: "build-box", type: "server", system: "macOS 14.7",
                         status: "offline", last_sync_at: timestamp(-3600), helper_version: "0.1.9",
                         current_session_count: 0, cpu_usage: nil, memory_usage: nil),
        ]

        // Every demo alert is a row a real producer writes, with its exact type,
        // id prefix and English template, so AlertPresentation localizes it the
        // way it localizes production. The stored title and message stay English
        // like every producer's; only the rendering is translated. Kinds no live
        // producer emits (the retired backend's Quota Critical, Session Failed,
        // Helper Offline, Cost Spike and Error Rate Spike) were dropped rather
        // than given templates of their own. DemoDataLocalizationTests fails if
        // a row here stops being recognized.
        //
        // The desktop's Daily/Weekly Budget Exceeded rows are localized too but
        // left out: their types are not in the webhook alias map yet, and
        // backend/supabase/ci_check_alert_types.py holds every type named in
        // this file to that map.

        // Quota: the cross-platform generator itself, with the default
        // thresholds, so this row cannot drift from production.
        let quotaAlerts = AlertGenerator.evaluateQuotaAlerts(
            providers: providers, thresholds: AlertThresholds.defaults.asArray
        ).compactMap(AlertGenerator.makeAlertRecord(from:))

        let busy = sessions[0]          // Codex on the MacBook Pro
        let longRunning = sessions[1]   // Gemini on lab-server-01

        let alerts = quotaAlerts + [
            // Swift helper, AlertGenerator.generate session-CPU rule. It does
            // not set a device name.
            AlertRecord(id: "session-spike-s1-3f9a2c1e", type: "Usage Spike", severity: "Warning",
                        title: "\(busy.name) is consuming high CPU",
                        message: "Using ~46% of total system CPU (10 cores) for \(busy.provider).",
                        created_at: timestamp(-1800), is_read: false, is_resolved: false,
                        acknowledged_at: nil, snoozed_until: nil,
                        related_project_id: nil, related_project_name: busy.project,
                        related_session_id: busy.id, related_session_name: busy.name,
                        related_provider: busy.provider, related_device_name: nil,
                        source_kind: "session", source_id: nil,
                        grouping_key: "Usage Spike:\(busy.provider)",
                        suppression_key: "Usage Spike:s1-3f9a2c1e"),
            // Python helper (helper/system_collector.py), device-CPU rule; its
            // uploader fills in the device name and the grouping keys.
            AlertRecord(id: "cpu-spike-d2", type: "Usage Spike", severity: "Warning",
                        title: "Device CPU usage is elevated",
                        message: "helper sampled CPU usage at 91%.",
                        created_at: timestamp(-3600), is_read: true, is_resolved: false,
                        acknowledged_at: nil, snoozed_until: nil,
                        related_project_id: nil, related_project_name: nil,
                        related_session_id: nil, related_session_name: nil,
                        related_provider: nil, related_device_name: "lab-server-01",
                        source_kind: "device", source_id: nil,
                        grouping_key: "Usage Spike:system", suppression_key: "Usage Spike:global"),
            // Python helper, long-running-session rule.
            AlertRecord(id: "session-long-s2-8d41b7e0", type: "Session Too Long", severity: "Info",
                        title: "\(longRunning.name) has been running for a long time",
                        message: "Long-running local agent session detected by helper.",
                        created_at: timestamp(-7200), is_read: true, is_resolved: false,
                        acknowledged_at: nil, snoozed_until: nil,
                        related_project_id: "p2", related_project_name: longRunning.project,
                        related_session_id: longRunning.id, related_session_name: longRunning.name,
                        related_provider: longRunning.provider, related_device_name: longRunning.device_name,
                        source_kind: "session", source_id: longRunning.id,
                        grouping_key: "Session Too Long:\(longRunning.provider)",
                        suppression_key: "Session Too Long:\(longRunning.id)"),
        ]

        // Risk signals are display text that RiskSignalsList renders verbatim,
        // held in memory and never stored or synced, so they are localized here,
        // as the only real producer (DataRefreshManager's noAiToolsDetected)
        // does. enterDemoMode runs this in the active language.
        let lowQuotaPercent = 10
        let riskSignals =
            providers.compactMap { p -> String? in
                guard let quota = p.quota, quota > 0, let remaining = p.remaining,
                      remaining * 100 < quota * lowQuotaPercent else { return nil }
                return L10n.dashboard.riskQuotaLow(p.provider, lowQuotaPercent)
            }
            + devices.filter { $0.status == "offline" }.map { L10n.dashboard.riskDeviceOffline($0.name) }

        let breakdowns = providers.map { provider in
            ProviderBreakdown(provider: provider.provider, usage: provider.today_usage,
                              estimated_cost: provider.estimated_cost_today,
                              cost_status: "Estimated", remaining: provider.remaining)
        }

        let dashboard = DashboardSummary(
            total_usage_today: providers.reduce(0) { $0 + $1.today_usage },
            total_estimated_cost_today: providers.reduce(0) { $0 + $1.estimated_cost_today },
            cost_status: "Estimated",
            total_requests_today: sessions.reduce(0) { $0 + $1.requests },
            active_sessions: sessions.filter { $0.status == "running" || $0.status == "syncing" }.count,
            online_devices: devices.filter { $0.status == "online" }.count,
            unresolved_alerts: alerts.filter { !$0.is_resolved }.count,
            provider_breakdown: breakdowns,
            top_projects: [
                TopProject(id: "p1", name: "cli-pulse-ios", usage: 24500, estimated_cost: 0.29, cost_status: "Estimated"),
                TopProject(id: "p2", name: "cli-pulse-helper", usage: 12800, estimated_cost: 0.10, cost_status: "Estimated"),
                TopProject(id: "p3", name: "backend-api", usage: 8400, estimated_cost: 0.10, cost_status: "Estimated"),
            ],
            trend: (0..<24).map { index in
                UsagePoint(
                    timestamp: timestamp(Double(-23 + index) * 3600),
                    value: 4000 + Int.random(in: 0...3000)
                )
            },
            // Empty, as every real producer leaves it (APIClient, DataRefreshManager).
            // Its only renderer is the Watch home screen, which never receives
            // the demo dashboard, so sample rows here were English nobody saw.
            recent_activity: [],
            risk_signals: riskSignals,
            alert_summary: AlertSummaryDTO(
                critical: alerts.filter { $0.severity == "Critical" }.count,
                warning: alerts.filter { $0.severity == "Warning" }.count,
                info: alerts.filter { $0.severity == "Info" }.count
            )
        )

        return DemoData(
            dashboard: dashboard,
            providers: providers,
            sessions: sessions,
            devices: devices,
            alerts: alerts
        )
    }

    /// A year of plausible daily usage for the Demo-mode activity heatmap.
    ///
    /// Deterministic on purpose — no random source — so the same "Try Demo" screen
    /// renders identically every time, which is what App Store screenshots and
    /// tests both need. Today's row reproduces the `generate()` provider figures
    /// exactly (85.9K / 43.4K / 24.8K tokens), so the heatmap's today cell and the
    /// dashboard's Usage Today tile agree instead of telling two different stories.
    ///
    /// Shape: weekdays busier than weekends, usage ramping up over the year the way
    /// a real adopter's does, and a scattering of idle days that thins out as the
    /// habit forms — a flat wall of identical cells reads as fake.
    static func dailyUsage(days: Int, today: Date = Date(), calendar: Calendar = .current) -> [CloudEntry] {
        struct Profile { let provider: String; let model: String; let todayTokens: Int; let todayCost: Double }
        let profiles = [
            Profile(provider: "Codex", model: "gpt-5-codex", todayTokens: 85_900, todayCost: 1.03),
            Profile(provider: "Gemini", model: "gemini-2.5-pro", todayTokens: 43_400, todayCost: 0.35),
            Profile(provider: "Claude", model: "claude-sonnet-4-5", todayTokens: 24_800, todayCost: 0.37),
        ]

        /// Stable value in [0, 1) for (day offset, salt) — a SplitMix64 step.
        func unit(_ offset: Int, _ salt: UInt64) -> Double {
            var z = UInt64(truncatingIfNeeded: offset) &* 0x9E37_79B9_7F4A_7C15 &+ salt
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z >> 11) / Double(1 << 53)
        }

        func entry(_ key: String, _ p: Profile, tokens: Int, cost: Double) -> CloudEntry {
            // mergeCloudDays sums all three buckets; the split only needs to be sane.
            let cached = tokens * 55 / 100
            let output = tokens * 12 / 100
            return CloudEntry(date: key, provider: p.provider, model: p.model,
                              inputTokens: tokens - cached - output, cachedTokens: cached,
                              outputTokens: output, cost: cost)
        }

        var rows: [CloudEntry] = []
        let span = max(1, days)
        for offset in 0..<span {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let key = DailyUsageStats.localDayKey(date, calendar: calendar)

            if offset == 0 {
                rows += profiles.map { entry(key, $0, tokens: $0.todayTokens, cost: $0.todayCost) }
                continue
            }

            let age = Double(offset) / Double(span)                 // 0 = today, 1 = a year ago
            let activeChance = 0.93 - 0.50 * age                    // the habit forms over time
            guard unit(offset, 1) < activeChance else { continue }  // an idle day

            let weekday = calendar.component(.weekday, from: date)  // 1 = Sunday … 7 = Saturday
            let weekend = weekday == 1 || weekday == 7
            let ramp = 1.0 - 0.7 * age
            let dayScale = ramp * (weekend ? 0.35 : 1.0) * (0.45 + 0.9 * unit(offset, 2))

            for (i, p) in profiles.enumerated() {
                // Not every provider is used every day.
                guard unit(offset, 10 + UInt64(i)) < 0.85 else { continue }
                let jitter = 0.6 + 0.8 * unit(offset, 20 + UInt64(i))
                let tokens = Int(Double(p.todayTokens) * dayScale * jitter)
                guard tokens > 0 else { continue }
                let cost = p.todayCost * Double(tokens) / Double(p.todayTokens)
                rows.append(entry(key, p, tokens: tokens, cost: (cost * 100).rounded() / 100))
            }
        }
        return rows
    }
}

extension AppState {
    public func enterDemoMode() {
        isDemoMode = true
        isAuthenticated = true
        isPaired = true
        userName = "Demo User"
        userEmail = "demo@clipulse.app"
        serverOnline = true
        lastRefresh = Date()

        applyDemoData(DemoDataProvider.generate())
        buildProviderDetails()
        updateCostSummary()
        publishWidgetData()
    }

    func applyDemoData(_ demoData: DemoData) {
        dashboard = demoData.dashboard
        providers = demoData.providers
        sessions = demoData.sessions
        devices = demoData.devices
        alerts = demoData.alerts
    }
}
