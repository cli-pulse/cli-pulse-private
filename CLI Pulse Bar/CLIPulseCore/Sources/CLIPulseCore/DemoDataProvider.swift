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
    /// than five minutes earlier, so everything Demo lists was written within
    /// five minutes of one refresh. That refresh ran 90 seconds ago, inside
    /// the iPhone's default two-minute interval, as a real phone's last one
    /// did, and its sessions were written at it.
    ///
    /// Demo used to keep two sessions written four and five minutes before
    /// the refresh, so that they read "Recent" now. Only a row with no scan
    /// prefix could: every session in the cloud is a process-scan row, which
    /// reads Running while its producer rewrites it and is hidden after
    /// (`SessionFreshnessTierClassifier`). Demo's rows had no prefix ("s1"),
    /// so they all read "Recent activity", as a Developer ID Mac's did while
    /// the classifier tested for `proc-` alone.
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
        //
        // v1.57: on the Mac, Codex, Gemini and Claude carry the metadata their
        // collectors attach (a cloud provider with quota windows and no exact
        // cost), as every real Mac's do: the local collectors run there and
        // their metadata survives the merge with the account's figures. The
        // Mac card reads it: a quota provider's tokens are I/O ("85.9K I/O"),
        // where one without it reads as an API's own count ("85.9K"). Demo
        // had none, so the store screenshots and the card's height
        // measurement showed a Codex row production never draws. The iPhone
        // reads the account's figures, which carry no metadata, so Demo's
        // stay without it there. `testDemoOnTheMacCarriesItsCollectorsMetadata`
        // holds it to the collectors.
        let providers = [
            ProviderUsage(provider: "Codex", today_usage: 85900, week_usage: 462000,
                          estimated_cost_today: 1.03, estimated_cost_week: 5.54,
                          estimated_cost_30_day: 23.83,
                          cost_status_today: "Estimated", cost_status_week: "Estimated",
                          quota: 100, remaining: 8,
                          tiers: [TierDTO(name: "Weekly", quota: 100, remaining: 8)],
                          status_text: "92% used",
                          trend: trend(base: 85000, salt: 201), recent_sessions: [], recent_errors: [],
                          metadata: macCollectorMetadata("Codex")),
            ProviderUsage(provider: "Gemini", today_usage: 0, week_usage: 0,
                          estimated_cost_today: 0, estimated_cost_week: 0,
                          cost_status_today: "Unavailable", cost_status_week: "Unavailable",
                          quota: 100, remaining: 29,
                          tiers: [TierDTO(name: "Pro", quota: 100, remaining: 29)],
                          status_text: "71% used",
                          trend: [], recent_sessions: [], recent_errors: [],
                          metadata: macCollectorMetadata("Gemini")),
            ProviderUsage(provider: "Claude", today_usage: 24800, week_usage: 132000,
                          estimated_cost_today: 0.37, estimated_cost_week: 1.98,
                          estimated_cost_30_day: 8.51,
                          cost_status_today: "Estimated", cost_status_week: "Estimated",
                          quota: 100, remaining: 47,
                          tiers: [TierDTO(name: "5h Window", quota: 100, remaining: 47),
                                  TierDTO(name: "Weekly", quota: 100, remaining: 69)],
                          status_text: "53% used",
                          trend: trend(base: 24000, salt: 203), recent_sessions: [], recent_errors: [],
                          metadata: macCollectorMetadata("Claude")),
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
        // Every session is a process-scan row with its producer's id, as
        // every session in the cloud is: the MacBook Pro's rows come from
        // the LoginItem helper (`local-<pid>`, the flat-rate cost above),
        // lab-server-01's from the desktop app (`proc-<pid>`).
        // So each reads Running, with its provider and project for a title
        // and none of the figures above, which the Sessions tab hides for a
        // scan row (`SessionRecord.hasProcessHeuristicMetrics`); they are
        // still the ones a scan writes, because the Overview's tiles and the
        // CPU alert below read them. The rows had ids no producer writes
        // ("s1"), so the Sessions tab drew them as log activity, "Recent
        // activity" with Usage, Cost and Requests, as it drew a Developer ID
        // Mac's rows while it tested for `proc-` alone.
        //
        // All of them were written at the refresh. Demo had two more,
        // api-gateway on build-box and a finished docs-refresh, last written
        // four and five minutes before it, to fill a Recent section. A scan
        // row that old is hidden, not Recent (the section is for logs written
        // in the last 30 minutes, which no cloud row is), so they were
        // dropped rather than drawn where no account can see them.
        // `testDemoIsOneRefreshTheCloudRouteCouldHaveKept` holds every row to
        // the filter and `testDemoSessionsAreProcessScanRowsAsEveryCloudSessionIs`
        // to their producers' ids.
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
            SessionRecord(id: "local-48213", name: "ios-dashboard", provider: "Codex",
                          project: "cli-pulse-ios", device_name: "MacBook Pro",
                          started_at: timestamp(busyStarted), last_active_at: timestamp(),
                          status: "Running", total_usage: 24500, estimated_cost: 0.049,
                          cost_status: "Estimated", requests: 160, error_count: 0,
                          collection_confidence: "high"),
            SessionRecord(id: "proc-3120", name: "helper-heartbeat", provider: "Gemini",
                          project: "cli-pulse-helper", device_name: "lab-server-01",
                          started_at: timestamp(-7 * 3600), last_active_at: timestamp(),
                          status: "Running", total_usage: 37800, estimated_cost: 0,
                          cost_status: "Estimated", requests: 560, error_count: 0,
                          collection_confidence: "medium"),
            SessionRecord(id: "local-48977", name: "provider-adapters", provider: "Claude",
                          project: "provider-layer", device_name: "MacBook Pro",
                          started_at: timestamp(-3600), last_active_at: timestamp(),
                          status: "Running", total_usage: 6200, estimated_cost: 0.0186,
                          cost_status: "Estimated", requests: 80, error_count: 0,
                          collection_confidence: "low"),
        ]

        // CPU figures agree with the alerts below. The MacBook Pro's
        // device-CPU alert is an hour old: its helper raised it at 91% and
        // keeps the row after the spike, so the 58% it reads now is the
        // present, not a contradiction. lab-server-01 reads 91% and has no
        // alert, because the desktop app, which reports it, has no device-CPU
        // rule. Each device last synced no earlier than its sessions were
        // written, since its sync wrote them. build-box lists none: its
        // helper last synced six minutes ago, and found nothing running.
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
        // On a Mac the LoginItem helper's skip used to test for `proc-`
        // alone, which its LocalScanner rows (`local-`) never carry, so it
        // raised the alert for every detected AI tool (Claude.app included)
        // open five hours: the false alarm v1.16.1 set out to remove. It
        // skips every scan row now (`SessionRecord.isProcessScanRow`), so no
        // producer raises it for any session Demo shows, and Integrations no
        // longer offers it as a webhook event.
        // `testDemoRaisesNoLongRunningAlert`.
        //
        // The cloud's rows, in the order `APIClient.alerts` asks for them
        // (`created_at.desc`): the device-CPU alert an hour old, then the
        // session-CPU alert two hours old.
        let cloudAlerts = [
            // Swift helper, AlertGenerator.generate device-CPU rule (85% of
            // the Mac): keyed to the helper's device id, with no device name,
            // which helper_sync stores as sent. It was lab-server-01's, with
            // the Python helper's keys; but that helper, the Companion CLI,
            // ships only as a macOS package, and the desktop app, which
            // reports Linux machines, has no device-CPU rule.
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
            // Its id and suppression key carry the session's id and a digest
            // of it and its start (`AlertGenerator.alertSessionIDSuffix`).
            AlertRecord(id: "session-spike-\(busy.id)-3f9a2c1e", type: "Usage Spike", severity: "Warning",
                        title: "\(busy.name) is consuming high CPU",
                        message: "Using ~46% of total system CPU (10 cores) for \(busy.provider).",
                        created_at: timestamp(busyStarted + 30), is_read: false, is_resolved: false,
                        acknowledged_at: nil, snoozed_until: nil,
                        related_project_id: nil, related_project_name: busy.project,
                        related_session_id: busy.id, related_session_name: busy.name,
                        related_provider: busy.provider, related_device_name: nil,
                        source_kind: "session", source_id: nil,
                        grouping_key: "Usage Spike:\(busy.provider)",
                        suppression_key: "Usage Spike:\(busy.id)-3f9a2c1e"),
        ]
        // Then the quota alert, last: the cloud route appends the alerts it
        // raises itself after the cloud's rows (DataRefreshManager,
        // `augmentedAlerts.append`), and no list sorts them again. So a real
        // iPhone, iPad or Mac lists this account's alerts 1h, 2h, 1m, and so
        // does a Watch the iPhone has relayed them to (WatchAlertSort keeps
        // the order of alerts of one severity). Demo had the quota alert
        // first and the session-CPU alert above the device-CPU one, an order
        // no refresh gives. `testDemoListsTheAlertsInTheOrderTheCloudRouteGives`.
        let alerts = cloudAlerts + quotaAlerts

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
            // `dashboard_summary` counts every session whose status is
            // 'Running', with no time window, and helper_sync turns a row
            // 'Ended' only ten minutes after its process is gone; the cloud
            // route never bumps the tile down (DataRefreshManager raises it to
            // the rows it lists). Every Demo row was written at the refresh, so
            // the tile, the Sessions tab's "N running" and its list all read 3.
            // (A real account whose process ended a few minutes ago reads one
            // more on the tile than in the list until helper_sync ends it.)
            // `testTheOverviewTilesCountWhatDashboardSummaryCounts`.
            active_sessions: sessions.filter { $0.status == "Running" }.count,
            // `dashboard_summary` counts the rows whose status is 'Online'.
            online_devices: devices.filter { $0.status == DeviceStatus.online.rawValue }.count,
            // `dashboard_summary` counts the unresolved rows of public.alerts,
            // and the cloud route passes that count through. The quota alert
            // is the app's own, raised as it refreshes and never uploaded, so
            // the Alerts tile reads 2 while the alert list and the tab badge,
            // which count the merged list, read 3. Demo counted the quota
            // alert in the tile too, which no account sees.
            unresolved_alerts: cloudAlerts.filter { !$0.is_resolved }.count,
            provider_breakdown: breakdowns,
            // Empty, as every real producer leaves it (APIClient, DataRefreshManager),
            // so the iPhone's and Watch's Top Projects card hides here too. Sample
            // rows put it in every App Store screenshot while no customer could see
            // it. Since 1.58 the Mac's card reads this Mac's own scan instead, and
            // Demo's Mac gives it one (`macScan`).
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

    /// The metadata `name`'s collector attaches (CodexCollector,
    /// ClaudeSourceStrategy, GeminiCollector: a cloud provider with quota
    /// windows and no exact cost), on the Mac, where those collectors run;
    /// nil elsewhere, where the account's figures carry none.
    static func macCollectorMetadata(_ name: String) -> ProviderMetadata? {
        #if os(macOS)
        return ProviderMetadata(display_name: name, category: "cloud",
                                supports_exact_cost: false, supports_quota: true)
        #else
        return nil
        #endif
    }

    /// The account's synced daily rows behind each Demo provider card's
    /// usage row and small chart on the Mac (`ProviderCardUsageBuilder`), and
    /// behind the iPhone and iPad card's Today, This Week, chart and the day
    /// it lists by model (`ProviderCardAccountFigures`): the last 30 days of
    /// Codex and Claude, the rows `get_daily_usage` returns.
    ///
    /// They add up to the figures `generate()` gives each provider. For cost,
    /// a real account's rows do the same: the server's `provider_summary` sums
    /// these rows' cost over the same windows. So today's rows hold today's
    /// cost, today and the six days before hold the week's, and all 30 days
    /// hold the 30-day cost, each to the cent. Their I/O tokens (input +
    /// output) equal each provider's Today and This Week tokens, which is what
    /// every card shows, since each counts the rows' I/O wherever there are
    /// rows. A real account's `provider_summary` tokens count each token once
    /// instead (migrate_v0.86; input + cached + output on a server without
    /// it), which only the card of a provider without rows shows (and the
    /// Watch, which reads no rows). For these Codex rows that is their I/O,
    /// since Codex's input holds its cached input; for Claude's it is four
    /// times their I/O (the cache below is three times it), which Demo's
    /// Claude figures, its I/O, do not show. The 30-day tokens, which nothing
    /// else in Demo states, follow the week's tokens per dollar.
    ///
    /// The days have the shape of Demo's year of history (`dailyUsage`, what
    /// the usage dashboard draws): the same idle days, and within the week and
    /// within the rest of the month the same busy and quiet days, scaled to
    /// those figures. Scaled, most of them are larger than the year's own
    /// figures for the same days, so in Demo the usage dashboard and the
    /// Activity heatmap show smaller days than the cards' charts, which a real
    /// account's cannot. `DemoProviderCardHistoryTests` holds them to the shape
    /// and the sums.
    static func providerCardHistory(
        providers: [ProviderUsage],
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> [DailyUsage] {
        let windows = ProviderUsageWindows(now: now, timeZone: timeZone)
        // Newest first: offset 0 is today.
        let keys = Array(windows.dayKeys.reversed())
        let year = dailyUsage(days: 365, today: now, calendar: DayKey.calendar(in: timeZone))

        var rows: [DailyUsage] = []
        for usage in providers {
            let history = year.filter { $0.provider == usage.provider }
            guard let model = history.first?.model,
                  usage.estimated_cost_30_day > 0, usage.estimated_cost_week > 0 else { continue }
            var historyTokens: [String: Int] = [:]
            for row in history {
                historyTokens[row.date, default: 0] += row.inputTokens + row.cachedTokens + row.outputTokens
            }
            let todayCents = Int((usage.estimated_cost_today * 100).rounded())
            let weekCents = Int((usage.estimated_cost_week * 100).rounded())
            let monthCents = Int((usage.estimated_cost_30_day * 100).rounded())
            let todayTokens = usage.today_usage
            let weekTokens = usage.week_usage
            let monthTokens = Int((Double(weekTokens) * Double(monthCents) / Double(weekCents)).rounded())

            var tokens = Array(repeating: 0, count: keys.count)
            var cents = Array(repeating: 0, count: keys.count)
            tokens[0] = todayTokens
            cents[0] = todayCents
            for (span, tokenTotal, centTotal) in [
                (1..<7, weekTokens - todayTokens, weekCents - todayCents),
                (7..<keys.count, monthTokens - weekTokens, monthCents - weekCents),
            ] {
                let offsets = Array(span)
                var weights = offsets.map { Double(historyTokens[keys[$0]] ?? 0) }
                if weights.allSatisfy({ $0 == 0 }) { weights = offsets.map { _ in 1 } }
                for (index, share) in Self.apportion(tokenTotal, by: weights).enumerated() {
                    tokens[offsets[index]] = share
                }
                for (index, share) in Self.apportion(centTotal, by: weights).enumerated() {
                    cents[offsets[index]] = share
                }
            }
            for offset in keys.indices where tokens[offset] > 0 || cents[offset] > 0 {
                let io = tokens[offset]
                let output = io * 12 / 100
                rows.append(DailyUsage(
                    date: keys[offset], provider: usage.provider, model: model,
                    inputTokens: io - output,
                    // Codex's input holds its cached input; Claude's cache is
                    // counted beside it. Only the card's I/O (input + output)
                    // is read from these.
                    cachedTokens: usage.provider == "Codex" ? (io - output) * 6 / 10 : io * 3,
                    outputTokens: output,
                    cost: Double(cents[offset]) / 100))
            }
        }
        return rows
    }

    /// v1.58 (P1-4): the folders Demo's Mac scan splits its usage across,
    /// with each one's share of Codex's and of Claude's usage. Invented: no
    /// real name or path. The first three are the projects Demo's sessions
    /// run in. Six, so the lists show the "Top 5 of 6" line a busy Mac does.
    static let macProjects: [(name: String, codex: Double, claude: Double)] = [
        ("cli-pulse-ios", 0.46, 0.12),
        ("provider-layer", 0.14, 0.41),
        ("cli-pulse-helper", 0.09, 0.19),
        ("web-dashboard", 0.17, 0.14),
        ("docs-site", 0.08, 0.09),
        ("release-tools", 0.06, 0.05),
    ]

    /// Where Demo's projects live. Invented, like the names.
    static let macProjectsFolder = "/Users/demo/Developer"

    /// v1.58 (P1-4): Demo's Mac as a Mac that scans its session logs and is
    /// the only device that uploads the account's usage: its scan rows are
    /// the account's synced rows (`rows`, `providerCardHistory`), so every
    /// card, the usage panel's This Mac and All devices, and the Cost
    /// Summary agree, as on a real Mac with one device. Like every real
    /// scan it has Claude's message counts (the `__claude_msg__` bucket,
    /// one message per 190 tokens, as the store set's local history), and
    /// its rows split by project (`macProjects`), each day and model
    /// apportioned in whole tokens and cents so the projects add up to the
    /// rows exactly. Deterministic: a day's shares lean a little from day to
    /// day (`unit`), the same in every language and run.
    ///
    /// v1.58 (P1-5): and by session (`sessions(from:…)`), the project rows
    /// cut into sessions of a few days each, last active no later than
    /// `now`, Demo's refresh: the Codex session in `cli-pulse-ios` and the
    /// Claude one in `provider-layer` a minute before it, as the logs of
    /// Demo's two running sessions on this Mac would be.
    static func macScan(rows: [DailyUsage], now: Date = Date(), timeZone: TimeZone = .current) -> CostUsageScanResult {
        var entries: [CostUsageScanResult.DailyEntry] = []
        var projects: [CostUsageScanResult.ProjectEntry] = []
        var claudeTokensByDay: [String: Int] = [:]
        let identities = macProjects.map { ProjectIdentity.folder(macProjectsFolder + "/" + $0.name) }
        for (index, row) in rows.enumerated() where row.provider == "Codex" || row.provider == "Claude" {
            entries.append(.init(
                date: row.date, provider: row.provider, model: row.model,
                inputTokens: row.inputTokens, cachedTokens: row.cachedTokens, outputTokens: row.outputTokens,
                costUSD: row.cost))
            if row.provider == "Claude" {
                claudeTokensByDay[row.date, default: 0] += row.inputTokens + row.cachedTokens + row.outputTokens
            }
            let isCodex = row.provider == "Codex"
            let weights = macProjects.enumerated().map { offset, project in
                (isCodex ? project.codex : project.claude) * (0.8 + 0.4 * unit(index, 300 + UInt64(offset)))
            }
            let inputs = apportion(row.inputTokens, by: weights)
            let cached = apportion(row.cachedTokens, by: weights)
            let outputs = apportion(row.outputTokens, by: weights)
            let cents = apportion(Int((row.cost * 100).rounded()), by: weights)
            for offset in identities.indices
            where inputs[offset] > 0 || cached[offset] > 0 || outputs[offset] > 0 || cents[offset] > 0 {
                projects.append(.init(
                    provider: row.provider, project: identities[offset], date: row.date, model: row.model,
                    inputTokens: inputs[offset], cachedTokens: cached[offset], outputTokens: outputs[offset],
                    costUSD: Double(cents[offset]) / 100))
            }
        }
        for (day, tokens) in claudeTokensByDay.sorted(by: { $0.key < $1.key }) {
            entries.append(.init(
                date: day, provider: "Claude", model: ScanEntry.messageBucketModel,
                inputTokens: 0, cachedTokens: 0, outputTokens: 0, costUSD: nil,
                messageCount: max(1, tokens / 190)))
        }
        let sessions = Self.sessions(
            from: projects, daysPerSession: 3, now: now, timeZone: timeZone,
            runningIn: ["Codex": "cli-pulse-ios", "Claude": "provider-layer"], salt: 700)
        return CostUsageScanResult(
            entries: entries, projects: projects, sessions: sessions.entries, sessionDetails: sessions.details)
    }

    /// v1.58 (P1-5): invented project rows cut into sessions as a Mac's scan
    /// would split them: each project's rows in runs of `daysPerSession`
    /// days (counted back from today), a session each, so the sessions add
    /// up to the projects, and so to the rows, exactly. Each is last active
    /// on its latest day: at an hour of that day for a past day, and before
    /// `now` for today, a minute before it in the projects `runningIn` names
    /// (by provider), whose logs a running session is writing. Claude
    /// sessions have up to four subagents and Codex ones up to two, each
    /// with usage on the session's latest day. Deterministic (`unit`).
    static func sessions(
        from projects: [CostUsageScanResult.ProjectEntry],
        daysPerSession: Int,
        now: Date,
        timeZone: TimeZone = .current,
        runningIn: [String: String] = [:],
        salt: UInt64
    ) -> (entries: [CostUsageScanResult.SessionEntry], details: [CostUsageScanResult.SessionDetail]) {
        let calendar = DayKey.calendar(in: timeZone)
        let today = calendar.startOfDay(for: now)
        func daysAgo(_ key: String) -> Int {
            guard let day = DayKey.date(from: key, in: timeZone) else { return 0 }
            return max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: day), to: today).day ?? 0)
        }
        struct Session {
            let provider: String
            let project: ProjectIdentity
            var latestDaysAgo: Int
            var latestDay: String
        }
        var sessions: [String: Session] = [:]
        var entries: [CostUsageScanResult.SessionEntry] = []
        for entry in projects {
            let ago = daysAgo(entry.date)
            let key = entry.provider.lowercased() + ":" + entry.project.key + "#" + String(ago / max(1, daysPerSession))
            entries.append(.init(
                provider: entry.provider, session: key, date: entry.date, model: entry.model,
                inputTokens: entry.inputTokens, cachedTokens: entry.cachedTokens, outputTokens: entry.outputTokens,
                costUSD: entry.costUSD, priceIsApproximate: entry.priceIsApproximate))
            var session = sessions[key]
                ?? Session(provider: entry.provider, project: entry.project, latestDaysAgo: ago, latestDay: entry.date)
            if ago < session.latestDaysAgo {
                session.latestDaysAgo = ago
                session.latestDay = entry.date
            }
            sessions[key] = session
        }
        var details: [CostUsageScanResult.SessionDetail] = []
        for (index, key) in sessions.keys.sorted().enumerated() {
            guard let session = sessions[key] else { continue }
            let lastActivity: Date
            if session.latestDaysAgo == 0 {
                let running = runningIn[session.provider] == session.project.name
                let minutes = running ? 1 : 20 + Int(unit(index, salt) * 280)
                lastActivity = max(today, now.addingTimeInterval(-Double(minutes) * 60))
            } else {
                let day = calendar.date(byAdding: .day, value: -session.latestDaysAgo, to: today) ?? today
                let minutes = 9 * 60 + Int(unit(index, salt + 1) * 13 * 60)
                lastActivity = day.addingTimeInterval(Double(minutes) * 60)
            }
            let most = session.provider == "Claude" ? 5.0 : 3.0
            let subagents = Int(unit(index, salt + 2) * most)
            details.append(.init(
                provider: session.provider, key: key, project: session.project, lastActivity: lastActivity,
                subagentLastDays: Array(repeating: session.latestDay, count: subagents)))
        }
        return (entries, details)
    }

    /// `total` split in proportion to `weights` in whole units, adding up to
    /// `total` exactly: each takes its floor, and the units left over go to
    /// the largest remainders.
    static func apportion(_ total: Int, by weights: [Double]) -> [Int] {
        let sum = weights.reduce(0, +)
        guard total > 0, sum > 0 else { return weights.map { _ in 0 } }
        let exact = weights.map { Double(total) * $0 / sum }
        var shares = exact.map { Int($0.rounded(.down)) }
        let left = total - shares.reduce(0, +)
        let order = exact.indices.sorted {
            (exact[$0] - Double(shares[$0]), -$0) > (exact[$1] - Double(shares[$1]), -$1)
        }
        for index in order.prefix(left) { shares[index] += 1 }
        return shares
    }
}

extension AppState {
    /// v1.58: the moment the Sessions lists classify their rows against
    /// (`SessionFreshnessTierClassifier`: Running, Recent, hidden): now, and
    /// in Demo the moment its one refresh is shown at, when Demo was entered
    /// (its refresh plus `DemoDataProvider.refreshAge`).
    ///
    /// Demo never refreshes (`RefreshRouter.decide` is a no-op in it), and
    /// its sessions were written at its refresh. Against the clock every one
    /// was hidden about three and a half minutes after Try Demo
    /// (`processFreshnessWindow`, five minutes from the refresh), and the
    /// Sessions tab emptied, with the iPhone's Overview tile and the iPad
    /// sidebar's count at 0 beside it. Against Demo's own clock they stay as
    /// Demo was entered. Read by the Sessions tab (Mac, iPhone, iPad), its
    /// legend and Running count, the iPhone's Overview tile and the iPad
    /// sidebar.
    public func sessionsClock(now: Date = Date()) -> Date {
        guard isDemoMode, let lastRefresh else { return now }
        return min(now, lastRefresh.addingTimeInterval(DemoDataProvider.refreshAge))
    }

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
        // moment it was entered: a real account is between two refreshes, and
        // its sessions and alerts are dated at or before the last one.
        lastRefresh = demo.refreshedAt
        // Demo mode cannot pair, so Settings — and every screenshot of it —
        // shows the paired account without a repair line.
        refreshThisMacPairing()

        applyDemoData(demo)
        // Demo is a signed-in account, and a signed-in account's provider
        // cards read its synced daily rows on every platform: the Mac card's
        // usage row and small chart, and the iPhone and iPad card's chart with
        // its Token / Cost choice and the day it lists by model. Not behind a
        // platform check, so Try Demo on an iPhone or iPad (the Demo App
        // Review uses) draws that chart, and the Mac's tests run the iPhone's
        // Demo too (`DemoProviderCardHistoryTests`).
        dailyUsage = DemoDataProvider.providerCardHistory(providers: demo.providers)
        #if os(macOS)
        // v1.58: and Demo's Mac scans its logs, as a real one does, so the
        // Overview's Top Projects and the usage panel's Projects have this
        // Mac's projects to list. Its rows are the synced ones: it is the
        // account's only uploading device (`DemoDataProvider.macScan`).
        costUsageScanResult = DemoDataProvider.macScan(rows: dailyUsage, now: demo.refreshedAt)
        #endif
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
