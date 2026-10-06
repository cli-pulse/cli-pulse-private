import Foundation

internal struct DemoData {
    /// The refresh the data came from, `DemoDataProvider.refreshAge` before
    /// it was generated. Every timestamp below is at or before it, and
    /// `enterDemoMode` shows it as the last refresh.
    let refreshedAt: Date
    let dashboard: DashboardSummary
    let providers: [ProviderUsage]
    let sessions: [SessionRecord]
    let devices: [DeviceRecord]
    let alerts: [AlertRecord]
}

internal enum DemoDataProvider {
    /// How long ago Demo's one refresh ran.
    ///
    /// Every route runs its sessions through `SessionFreshnessFilter
    /// .filterCurrent` when it refreshes, which drops a row last active more
    /// than five minutes earlier. So a row the Sessions tab files under Recent
    /// (five to thirty minutes old) appears only between refreshes, once the
    /// rows a refresh kept have aged past five minutes. Demo had Recent rows
    /// 12 and 20 minutes old beside rows active "just now" and a last refresh
    /// of "just now", which no refresh can leave. Now its data is one refresh
    /// that ran 90 seconds earlier, inside the iPhone's default two-minute
    /// interval: the active rows were written at that refresh, and the Recent
    /// rows a little before it, so they are five to six minutes old now.
    static let refreshAge: TimeInterval = 90

    static func generate() -> DemoData {
        let formatter = sharedISO8601Formatter
        let now = Date()
        let refreshedAt = now.addingTimeInterval(-refreshAge)

        /// A time relative to the refresh. Offsets are never positive: the
        /// refresh read every row, so nothing it shows can be newer
        /// (`testDemoIsOneRefreshTheCloudRouteCouldHaveKept`).
        func timestamp(_ offset: TimeInterval = 0) -> String {
            formatter.string(from: refreshedAt.addingTimeInterval(offset))
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
        //
        // Claude reports its windows the way ClaudeResultBuilder does: each a
        // percentage (quota 100), the 5-hour one first, and the provider's own
        // quota and remaining taken from it. Demo gave Claude a token quota
        // (250K, 118K left) and no window, a shape no producer sends. The Mac
        // card drew no bar for it, and the iPhone and iPad drew their legacy
        // "Quota" bar, filled to the share used beside bars filled to the
        // share left. `testDemoClaudeReportsTheWindowsItsCollectorBuilds`
        // holds it to the builder.
        //
        // Codex and Gemini report percentages too: CodexCollector and
        // GeminiCollector build every window, and the provider's own quota and
        // remaining, as quota 100 and the share left, and the cloud keeps what
        // the Mac uploads. Demo gave them token counts (500K with 38K left,
        // 300K with 86K left). The bars and the alert read the same either
        // way, but the Watch's provider screen prints the two numbers as its
        // Quota and Remaining rows: "500K" and "38K", where a real Codex reads
        // 100 and 8. `testDemoCodexAndGeminiReportTheWindowsTheirCollectorsBuild`
        // holds them to the collectors.
        //
        // Each provider with a cost carries the 30-day figure the server sends
        // (`provider_summary`: the last 30 days of `daily_usage_metrics`, a
        // window that holds the week's and today's). Without it the app fell
        // back to week x 4.3, which production no longer takes, and the Cost
        // Summary's rows ($23.82 and $8.51) came to a cent less than its
        // 30-day total ($32.34). `testTheCostSummaryRowsAddUpToItsTotals`
        // holds the rows to the total.
        let providers = [
            ProviderUsage(provider: "Codex", today_usage: 85900, week_usage: 462000,
                          estimated_cost_today: 1.03, estimated_cost_week: 5.54,
                          estimated_cost_30_day: 23.83,
                          cost_status_today: "Estimated", cost_status_week: "Estimated",
                          quota: 100, remaining: 8,
                          tiers: [TierDTO(name: "Weekly", quota: 100, remaining: 8)],
                          status_text: "92% used",
                          trend: trend(base: 85000, salt: 201), recent_sessions: [], recent_errors: []),
            ProviderUsage(provider: "Gemini", today_usage: 0, week_usage: 0,
                          estimated_cost_today: 0, estimated_cost_week: 0,
                          cost_status_today: "Unavailable", cost_status_week: "Unavailable",
                          quota: 100, remaining: 29,
                          tiers: [TierDTO(name: "Pro", quota: 100, remaining: 29)],
                          status_text: "71% used",
                          trend: [], recent_sessions: [], recent_errors: []),
            ProviderUsage(provider: "Claude", today_usage: 24800, week_usage: 132000,
                          estimated_cost_today: 0.37, estimated_cost_week: 1.98,
                          estimated_cost_30_day: 8.51,
                          cost_status_today: "Estimated", cost_status_week: "Estimated",
                          quota: 100, remaining: 47,
                          tiers: [TierDTO(name: "5h Window", quota: 100, remaining: 47),
                                  TierDTO(name: "Weekly", quota: 100, remaining: 69)],
                          status_text: "53% used",
                          trend: trend(base: 24000, salt: 203), recent_sessions: [], recent_errors: []),
        ]

        // Session names are identifiers, the way a real one reads (a command or
        // a project), not English sentences: they are data, shown as-is in
        // every language, and they reappear inside the alert titles below.
        //
        // helper-heartbeat has run on lab-server-01, a Linux server, for
        // seven hours. It used to carry a long-running alert, which no
        // producer raises for it (see the alerts below). Off a Mac a session
        // comes from the desktop app's process scan (ported verbatim from the
        // Python helper's, helper/system_collector.py): usage is runtime times
        // max(1.5, CPU% + 1), and the cost is left out (`exact_cost` null,
        // which helper_sync stores as 0). Seven hours of a quiet process is
        // therefore 37.8K and $0.00. Demo showed 12.8K and $0.10, a Gemini
        // dollar figure no producer writes: even the Mac helper's flat Gemini
        // rate ($0.001 per 1K, LocalScanner) would have made 12.8K one cent.
        // `testDemoSessionsKeepTheProcessScanFloors` and
        // `testASessionOffAMacCarriesNoCost` hold it to that.
        //
        // Every session's figures are ones a process scan writes for its
        // runtime (last_active_at - started_at): a request per 45 s and at
        // least 1.5 usage per second. On a Mac the cost is the LoginItem
        // helper's flat rate (usage/1000 x ProviderKind.defaultCostRate;
        // HelperDaemon scans with no rate lookup), or none from the Companion
        // CLI. Demo had about six times that rate (ios-dashboard: $0.29 for
        // 24.5K Codex, where the helper writes $0.05) and fewer requests than
        // the runtime gives (142 over two hours, where a scan counts 160).
        // `testASessionOnAMacCostsTheHelpersFlatRateOrNothing` holds the cost.
        //
        // Two sessions sit in the Sessions tab's Recent tier (last written 5
        // to 30 minutes ago, SessionFreshnessTierClassifier): api-gateway,
        // last written just before build-box's helper stopped syncing, and a
        // finished docs-refresh. Without them the Active section was the
        // whole list and the lower half of the screen was empty. They were 20
        // and 12 minutes old, which no refresh keeps: the cloud route drops a
        // row last active more than five minutes before it refreshes. Now they
        // stopped about four and five minutes before Demo's refresh
        // (`refreshAge`), so they are past five minutes only now, 90 seconds
        // on, as a real Recent row can be. The running sessions were written
        // at the refresh. `testDemoIsOneRefreshTheCloudRouteCouldHaveKept`
        // holds every row to the filter.
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
        let busyStarted: TimeInterval = -7200  // ios-dashboard, which the CPU alert names
        let sessions = [
            SessionRecord(id: "s1", name: "ios-dashboard", provider: "Codex",
                          project: "cli-pulse-ios", device_name: "MacBook Pro",
                          started_at: timestamp(busyStarted), last_active_at: timestamp(),
                          status: "Running", total_usage: 24500, estimated_cost: 0.049,
                          cost_status: "Estimated", requests: 160, error_count: 0,
                          collection_confidence: "high"),
            SessionRecord(id: "s2", name: "helper-heartbeat", provider: "Gemini",
                          project: "cli-pulse-helper", device_name: "lab-server-01",
                          started_at: timestamp(-7 * 3600), last_active_at: timestamp(),
                          status: "Running", total_usage: 37800, estimated_cost: 0,
                          cost_status: "Estimated", requests: 560, error_count: 0,
                          collection_confidence: "medium"),
            SessionRecord(id: "s3", name: "api-gateway", provider: "Codex",
                          project: "backend-api", device_name: "build-box",
                          started_at: timestamp(-6290), last_active_at: timestamp(-290),
                          status: "Running", total_usage: 9600, estimated_cost: 0.0192,
                          cost_status: "Estimated", requests: 133, error_count: 0,
                          collection_confidence: "high"),
            SessionRecord(id: "s4", name: "provider-adapters", provider: "Claude",
                          project: "provider-layer", device_name: "MacBook Pro",
                          started_at: timestamp(-3600), last_active_at: timestamp(),
                          status: "Running", total_usage: 6200, estimated_cost: 0.0186,
                          cost_status: "Estimated", requests: 80, error_count: 0,
                          collection_confidence: "low"),
            SessionRecord(id: "s5", name: "docs-refresh", provider: "Claude",
                          project: "cli-pulse-docs", device_name: "MacBook Pro",
                          started_at: timestamp(-2210), last_active_at: timestamp(-230),
                          status: "Running", total_usage: 4100, estimated_cost: 0.0123,
                          cost_status: "Estimated", requests: 44, error_count: 0,
                          collection_confidence: "high"),
        ]

        // CPU figures agree with the alerts below. The MacBook Pro's
        // device-CPU alert is an hour old: its helper raised it at 91% and
        // keeps the row after the spike, so the 58% it reads now is the
        // present, not a contradiction. lab-server-01 reads 91% and has no
        // alert, because the desktop app, which reports it, has no device-CPU
        // rule. Each device last synced no earlier than its sessions were
        // written, since its sync wrote them: build-box with api-gateway,
        // just before its helper stopped syncing.
        //
        // Every device reads "Online", the one status the cloud stores:
        // register_helper, the desktop's sign-in and every heartbeat and sync
        // write it, nothing writes another, and the app shows the stored
        // value. So build-box, quiet for six minutes, still reads Online, and
        // the Online Devices tile counts all three, as `dashboard_summary`
        // does. Demo had build-box "offline", a status only the retired
        // backend wrote, which took the tile to 2; and it wrote the others in
        // lower case, which `DeviceStatus` does not read as online, so the
        // Watch's machine cards, fed from the phone, drew their dots grey.
        // `testDemoDevicesReadOnlineAsTheCloudStoresThem`.
        let devices = [
            DeviceRecord(id: "d1", name: "MacBook Pro", type: "laptop", system: "macOS 15.4",
                         status: "Online", last_sync_at: timestamp(), helper_version: "0.2.0",
                         current_session_count: 2, cpu_usage: 58, memory_usage: 68),
            DeviceRecord(id: "d2", name: "lab-server-01", type: "server", system: "Ubuntu 24.04",
                         status: "Online", last_sync_at: timestamp(), helper_version: "0.2.0",
                         current_session_count: 1, cpu_usage: 91, memory_usage: 45),
            DeviceRecord(id: "d3", name: "build-box", type: "server", system: "macOS 14.7",
                         status: "Online", last_sync_at: timestamp(-290), helper_version: "0.1.9",
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
        // thresholds, so this row cannot drift from production. The app
        // raises it as it refreshes, so it is dated at the refresh.
        let quotaAlerts = AlertGenerator.evaluateQuotaAlerts(
            providers: providers, thresholds: AlertThresholds.defaults.asArray, now: refreshedAt
        ).compactMap(AlertGenerator.makeAlertRecord(from:))

        let busy = sessions[0]      // Codex on the MacBook Pro
        let busyMac = devices[0]    // the MacBook Pro

        // No alert comes from the long-running rule ("Session Too Long"). It
        // fires at 400 requests, and every session that reaches the cloud is
        // a process-scan row, whose count is only its runtime / 45, so five
        // hours of any open process trips it. v1.16.1 made the rule skip
        // those rows (helper/system_collector.py, AlertGenerator), and the
        // desktop app, which writes every session off a Mac, has no such
        // rule. Demo had one on helper-heartbeat, on lab-server-01.
        //
        // On a Mac it still fires today: the LoginItem helper's skip tests
        // for `proc-`, which its LocalScanner rows (`local-`) never carry,
        // and the Companion CLI's rule has no skip. That is the false alarm
        // v1.16.1 set out to remove, not something to put in a screenshot.
        // `testDemoRaisesNoLongRunningAlert`.
        let alerts = quotaAlerts + [
            // Swift helper, AlertGenerator.generate session-CPU rule. It does
            // not set a device name.
            //
            // The rule compares LocalScanner's CPU figure, a session's average
            // over its whole life, with 40% of the machine, and the same figure
            // sets the session's usage: runtime x (CPU% + 1), so 100 per
            // CPU-second plus one per second. helper_sync keeps an alert's
            // first created_at and updates only its text. So a session caught
            // at 46% of ten cores T seconds into its life had burned 4.6 x T
            // CPU-seconds by then, and shows at least 460 x T usage on top of
            // its runtime. Raised 30 minutes ago, 90 minutes in, that is 2.5M;
            // ios-dashboard shows 24.5K. Raised at the helper's first scan, 30
            // seconds in (a burst at launch, quiet since), 24.5K holds it.
            // `testTheSessionCPUAlertComesFromASessionThatCouldRaiseIt`.
            AlertRecord(id: "session-spike-s1-3f9a2c1e", type: "Usage Spike", severity: "Warning",
                        title: "\(busy.name) is consuming high CPU",
                        message: "Using ~46% of total system CPU (10 cores) for \(busy.provider).",
                        created_at: timestamp(busyStarted + 30), is_read: false, is_resolved: false,
                        acknowledged_at: nil, snoozed_until: nil,
                        related_project_id: nil, related_project_name: busy.project,
                        related_session_id: busy.id, related_session_name: busy.name,
                        related_provider: busy.provider, related_device_name: nil,
                        source_kind: "session", source_id: nil,
                        grouping_key: "Usage Spike:\(busy.provider)",
                        suppression_key: "Usage Spike:s1-3f9a2c1e"),
            // Swift helper, AlertGenerator.generate device-CPU rule (85% of
            // the Mac): keyed to the helper's device id, with no device name,
            // which helper_sync stores as sent. It was lab-server-01's, with
            // the Python helper's keys; but the Python helper is not shipped
            // (docs/ARCHITECTURE.md), and the desktop app, which reports
            // Linux machines, has no device-CPU rule.
            // `testTheDeviceCPUAlertIsOneTheMacHelperRaises`.
            AlertRecord(id: "cpu-spike-\(busyMac.id)", type: "Usage Spike", severity: "Warning",
                        title: "Device CPU usage is elevated",
                        message: "helper sampled CPU usage at 91%.",
                        created_at: timestamp(-3600), is_read: true, is_resolved: false,
                        acknowledged_at: nil, snoozed_until: nil,
                        related_project_id: nil, related_project_name: nil,
                        related_session_id: nil, related_session_name: nil,
                        related_provider: nil, related_device_name: nil,
                        source_kind: "device", source_id: nil,
                        grouping_key: "Usage Spike:device:\(busyMac.id)",
                        suppression_key: "cpu-spike-\(busyMac.id)"),
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
            // `dashboard_summary` counts the rows whose status is 'Online'.
            online_devices: devices.filter { $0.status == DeviceStatus.online.rawValue }.count,
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
            refreshedAt: refreshedAt,
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
        let demo = DemoDataProvider.generate()
        // The refresh Demo's data came from, a little before now, not the
        // moment it was entered: its Recent sessions are older than a refresh
        // keeps, so only an earlier refresh can have left them.
        lastRefresh = demo.refreshedAt
        // Demo mode cannot pair, so Settings — and every screenshot of it —
        // shows the paired account without a repair line.
        refreshThisMacPairing()

        applyDemoData(demo)
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
