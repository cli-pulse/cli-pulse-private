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

        // Deterministic, like `dailyUsage`: with `Int.random` the hourly bars
        // came out different in every language of one screenshot run and in
        // every run.
        func trend(base: Int, salt: UInt64) -> [UsagePoint] {
            (0..<12).map { index in
                UsagePoint(
                    timestamp: timestamp(Double(-11 + index) * 3600),
                    value: base - 2000 + Int(unit(index, salt) * 4001)
                )
            }
        }

        // Codex carries its weekly window as a real tier, named the way
        // CodexCollector names it, so the quota alert below comes out of the
        // generator with a tier name the tier mapper translates. Without a tier
        // the generator falls back to the synthetic "Overall", which is left
        // untranslated on purpose (scripts/quota_tier_names.json).
        //
        // Gemini likewise carries the window GeminiCollector reports, named by
        // model family ("Pro", a vendor term shown as-is in every language).
        // Without a tier the Providers screen made up a bar labelled
        // "Default", which told nobody anything. At 71% used it stays under the
        // 80% warning threshold, so no alert is added.
        //
        // Gemini is quota-only, as it is for every real account: GeminiCollector
        // reports no tokens and no cost ("Unavailable"), CostUsageScanner reads
        // only Codex and Claude logs, and `daily_usage_metrics` (the cloud's
        // tokens and cost) is fed by that scanner, so no producer ever gives
        // Gemini a token count or a dollar figure. Demo used to (43.4K tokens,
        // $0.35 today), and they reached the totals, the Cost Summary and
        // Provider Usage of every screenshot. `testDemoGivesGeminiNoTokensOrCost`
        // holds it to that.
        //
        // No provider lists recent sessions: only OllamaCollector fills
        // `recent_sessions`, so a Codex, Gemini or Claude card never draws that
        // line for a real account.
        let providers = [
            ProviderUsage(provider: "Codex", today_usage: 85900, week_usage: 462000,
                          estimated_cost_today: 1.03, estimated_cost_week: 5.54,
                          cost_status_today: "Estimated", cost_status_week: "Estimated",
                          quota: 500000, remaining: 38000,
                          tiers: [TierDTO(name: "Weekly", quota: 500000, remaining: 38000)],
                          status_text: "92% used",
                          trend: trend(base: 85000, salt: 201), recent_sessions: [], recent_errors: []),
            ProviderUsage(provider: "Gemini", today_usage: 0, week_usage: 0,
                          estimated_cost_today: 0, estimated_cost_week: 0,
                          cost_status_today: "Unavailable", cost_status_week: "Unavailable",
                          quota: 300000, remaining: 86000,
                          tiers: [TierDTO(name: "Pro", quota: 300000, remaining: 86000)],
                          status_text: "71% used",
                          trend: [], recent_sessions: [], recent_errors: []),
            ProviderUsage(provider: "Claude", today_usage: 24800, week_usage: 132000,
                          estimated_cost_today: 0.37, estimated_cost_week: 1.98,
                          cost_status_today: "Estimated", cost_status_week: "Estimated",
                          quota: 250000, remaining: 118000, status_text: "53% used",
                          trend: trend(base: 24000, salt: 203), recent_sessions: [], recent_errors: []),
        ]

        // Session names are identifiers, the way a real one reads (a command or
        // a project), not English sentences: they are data, shown as-is in
        // every language, and they reappear inside the alert titles below.
        //
        // helper-heartbeat carries the long-running alert below, so it looks
        // like a session that would trip it: the helpers only fire at 400 or
        // more requests, and count a request per 45 s of runtime. Seven hours
        // gives 560, and it crossed 400 at the five-hour mark, two hours ago,
        // which is when the alert says it was raised.
        //
        // It runs on lab-server-01, a Linux server. Off a Mac a session comes
        // from the desktop app's process scan (ported verbatim from the Python
        // helper's, helper/system_collector.py): usage is runtime times
        // max(1.5, CPU% + 1), and the cost is left out (`exact_cost` null,
        // which helper_sync stores as 0). Seven hours of a quiet process is
        // therefore 37.8K and $0.00. Demo showed 12.8K and $0.10, a Gemini
        // dollar figure no producer writes: even the Mac helper's flat Gemini
        // rate ($0.001 per 1K, LocalScanner) would have made 12.8K one cent.
        // `testDemoSessionsKeepTheProcessScanFloor` and
        // `testASessionOffAMacCarriesNoCost` hold it to that.
        //
        // Two sessions sit in the Sessions tab's Recent tier (last written 5
        // to 30 minutes ago, SessionFreshnessTierClassifier): api-gateway,
        // last written shortly before build-box went offline, and a finished
        // docs-refresh. Without them the Active section was the whole list and
        // the lower half of the screen was empty.
        //
        // No session has errors or a "failed" status: every producer (both
        // helpers, the local scanners, the desktop app) writes error_count 0
        // and a live status, so a real Sessions tab never draws the red Errors
        // figure or the red border api-gateway used to have.
        //
        // Every status is "Running", the only one a producer writes; helper_sync
        // turns a row "Ended" ten minutes after its process is gone, by which
        // time the app's freshness filter (five minutes) no longer lists it.
        // Demo had "running", "syncing" and "idle", and the iPad's session list
        // drew Syncing and Idle badges no account can get.
        let sessions = [
            SessionRecord(id: "s1", name: "ios-dashboard", provider: "Codex",
                          project: "cli-pulse-ios", device_name: "MacBook Pro",
                          started_at: timestamp(-7200), last_active_at: timestamp(),
                          status: "Running", total_usage: 24500, estimated_cost: 0.29,
                          cost_status: "Estimated", requests: 142, error_count: 0,
                          collection_confidence: "high"),
            SessionRecord(id: "s2", name: "helper-heartbeat", provider: "Gemini",
                          project: "cli-pulse-helper", device_name: "lab-server-01",
                          started_at: timestamp(-7 * 3600), last_active_at: timestamp(),
                          status: "Running", total_usage: 37800, estimated_cost: 0,
                          cost_status: "Estimated", requests: 560, error_count: 0,
                          collection_confidence: "medium"),
            SessionRecord(id: "s3", name: "api-gateway", provider: "Codex",
                          project: "backend-api", device_name: "build-box",
                          started_at: timestamp(-7200), last_active_at: timestamp(-1200),
                          status: "Running", total_usage: 8400, estimated_cost: 0.10,
                          cost_status: "Estimated", requests: 56, error_count: 0,
                          collection_confidence: "high"),
            SessionRecord(id: "s4", name: "provider-adapters", provider: "Claude",
                          project: "provider-layer", device_name: "MacBook Pro",
                          started_at: timestamp(-3600), last_active_at: timestamp(),
                          status: "Running", total_usage: 6200, estimated_cost: 0.09,
                          cost_status: "Estimated", requests: 38, error_count: 0,
                          collection_confidence: "low"),
            SessionRecord(id: "s5", name: "docs-refresh", provider: "Claude",
                          project: "cli-pulse-docs", device_name: "MacBook Pro",
                          started_at: timestamp(-2700), last_active_at: timestamp(-720),
                          status: "Running", total_usage: 4100, estimated_cost: 0.06,
                          cost_status: "Estimated", requests: 21, error_count: 0,
                          collection_confidence: "high"),
        ]

        // CPU figures agree with the alerts below: the MacBook Pro's total sits
        // above the ~46% its ios-dashboard session alone is using, and
        // lab-server-01 reports the 91% its device-CPU alert quotes.
        let devices = [
            DeviceRecord(id: "d1", name: "MacBook Pro", type: "laptop", system: "macOS 15.4",
                         status: "online", last_sync_at: timestamp(), helper_version: "0.2.0",
                         current_session_count: 2, cpu_usage: 58, memory_usage: 68),
            DeviceRecord(id: "d2", name: "lab-server-01", type: "server", system: "Ubuntu 24.04",
                         status: "online", last_sync_at: timestamp(), helper_version: "0.2.0",
                         current_session_count: 1, cpu_usage: 91, memory_usage: 45),
            DeviceRecord(id: "d3", name: "build-box", type: "server", system: "macOS 14.7",
                         status: "offline", last_sync_at: timestamp(-900), helper_version: "0.1.9",
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

        // From the local refresh's own producer, with Demo's facts: it has
        // sessions and provider data, so it raises nothing and the Risk Signals
        // card hides, as it would for a real account in this state. It used to
        // hold a low-quota and a device-offline signal, kinds only the retired
        // backend wrote. enterDemoMode runs this in the active language.
        let riskSignals = DashboardRiskSignals.local(
            foundSessions: !sessions.isEmpty,
            foundProviderData: !providers.isEmpty)

        let breakdowns = providers.map { provider in
            ProviderBreakdown(provider: provider.provider, usage: provider.today_usage,
                              estimated_cost: provider.estimated_cost_today,
                              cost_status: "Estimated", remaining: provider.remaining)
        }

        let dashboard = DashboardSummary(
            total_usage_today: providers.reduce(0) { $0 + $1.today_usage },
            total_estimated_cost_today: providers.reduce(0) { $0 + $1.estimated_cost_today },
            cost_status: "Estimated",
            // 0, as the signed-in dashboard Demo draws always carries it:
            // `dashboard_summary` has no request column (APIClient.dashboardSummary).
            // Only the local refresh route counts requests, so the Requests tile
            // shows there alone (OverviewFormatters.showsRequestsMetric); Demo
            // takes the `.noOp` route.
            total_requests_today: 0,
            // The Sessions tab's Active section, by freshness (every status is
            // Running); ScreenshotLaunchTests holds the two equal.
            active_sessions: SessionFreshnessTierClassifier.partition(sessions, now: now).active.count,
            online_devices: devices.filter { $0.status == "online" }.count,
            unresolved_alerts: alerts.filter { !$0.is_resolved }.count,
            provider_breakdown: breakdowns,
            // Empty, as every real producer leaves it (APIClient, DataRefreshManager),
            // so the Top Projects card hides here too. Sample rows put it in every
            // App Store screenshot while no customer could see it. Put rows back
            // only in the change that gives a real account some.
            top_projects: [],
            // Empty, as every real producer leaves it (APIClient's
            // `dashboard_summary` row has no hourly column, and the local
            // refresh keeps none), so the Overview's Hourly Activity card hides
            // here too. 24 sample bars put it in every App Store screenshot
            // while no customer could see it. Put bars back only in the change
            // that gives a real account some.
            trend: [],
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

    /// Stable value in [0, 1) for (offset, salt) — a SplitMix64 step. Demo data
    /// draws every "random" figure from this, so each screen is the same in
    /// every language and on every run.
    static func unit(_ offset: Int, _ salt: UInt64) -> Double {
        var z = UInt64(truncatingIfNeeded: offset) &* 0x9E37_79B9_7F4A_7C15 &+ salt
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }

    /// A year of plausible daily usage for the Demo-mode activity heatmap.
    ///
    /// Deterministic on purpose — no random source — so the same "Try Demo" screen
    /// renders identically every time, which is what App Store screenshots and
    /// tests both need. Today's row reproduces the `generate()` provider figures
    /// exactly (85.9K / 24.8K tokens), so the heatmap's today cell and the
    /// dashboard's Usage Today tile agree instead of telling two different stories.
    ///
    /// Shape: weekdays busier than weekends, usage ramping up over the year the way
    /// a real adopter's does, and a scattering of idle days that thins out as the
    /// habit forms — a flat wall of identical cells reads as fake.
    static func dailyUsage(days: Int, today: Date = Date(), calendar: Calendar = .current) -> [CloudEntry] {
        // `salt` keeps each provider's day-by-day draws where they were when
        // Gemini had a row here: nothing records Gemini tokens or cost (see
        // `generate()`), so it has none, and Codex and Claude keep their history.
        struct Profile { let provider: String; let model: String; let todayTokens: Int; let todayCost: Double; let salt: UInt64 }
        let profiles = [
            Profile(provider: "Codex", model: "gpt-5-codex", todayTokens: 85_900, todayCost: 1.03, salt: 0),
            Profile(provider: "Claude", model: "claude-sonnet-4-5", todayTokens: 24_800, todayCost: 0.37, salt: 2),
        ]

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

            for p in profiles {
                // Not every provider is used every day.
                guard unit(offset, 10 + p.salt) < 0.85 else { continue }
                let jitter = 0.6 + 0.8 * unit(offset, 20 + p.salt)
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
        // Demo reads nothing on this Mac, so the helper reads nothing either.
        recordAccountForHelper()
        // Shown as the Settings account title, the heading of every localized
        // screenshot of that screen. Nothing stores or syncs it: a relaunch in
        // Demo comes back through here and resolves it again.
        userName = L10n.auth.demoUserName
        userEmail = "demo@clipulse.app"
        serverOnline = true
        lastRefresh = Date()
        // Demo mode cannot pair, so Settings — and every screenshot of it —
        // shows the paired account without a repair line.
        refreshThisMacPairing()

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
