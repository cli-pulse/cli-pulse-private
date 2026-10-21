import XCTest
@testable import CLIPulseCore

/// Pin the Active/Recent tier classification used by the macOS / iOS
/// Sessions tab section split. Coexists with the existing
/// `SessionFreshnessFilterTests` — `filterCurrent` still drops the
/// same rows the new tier classifier marks `.hidden`, so the cloud
/// filter contract is unchanged.
final class SessionFreshnessTierTests: XCTestCase {
    private typealias C = SessionFreshnessTierClassifier
    private let isoFormatter = ISO8601DateFormatter()

    /// Use a fixed "now" so ISO8601 second-truncation is deterministic.
    /// A `Date()`-derived now would have sub-second drift that pushes
    /// boundary cases just past the window after a string round-trip.
    private let referenceNow = Date(timeIntervalSince1970: 1_700_000_000)

    private func make(
        id: String,
        name: String = "Claude · cli-pulse",
        device: String = "MacBook Pro",
        ageSeconds: TimeInterval,
        now: Date,
        status: String = "running"
    ) -> SessionRecord {
        let lastActive = now.addingTimeInterval(-ageSeconds)
        return SessionRecord(
            id: id,
            name: name,
            provider: "Claude",
            project: "cli-pulse",
            device_name: device,
            started_at: isoFormatter.string(from: lastActive),
            last_active_at: isoFormatter.string(from: lastActive),
            status: status,
            total_usage: 0,
            estimated_cost: 0,
            cost_status: "Estimated",
            requests: 0,
            error_count: 0
        )
    }

    // MARK: - process-confirmed sessions

    func test_process_session_within_window_is_activeProcess() {
        let now = referenceNow
        let s = make(id: "proc-12345", ageSeconds: 30, now: now)
        XCTAssertEqual(C.classify(s, now: now), .activeProcess)
    }

    func test_process_session_at_exact_window_is_activeProcess() {
        let now = referenceNow
        // 300s window (two 120 s producer cycles + a minute) — boundary inclusive.
        let s = make(id: "proc-12345", ageSeconds: 300, now: now)
        XCTAssertEqual(C.classify(s, now: now), .activeProcess)
    }

    func test_process_session_past_window_is_hidden_not_recent() {
        // Process-confirmed evidence becomes meaningless once the
        // helper has stopped refreshing — don't demote to Recent
        // (which is a JSONL-only signal), just hide.
        let now = referenceNow
        let s = make(id: "proc-12345", ageSeconds: 301, now: now)
        XCTAssertEqual(C.classify(s, now: now), .hidden)
    }

    func test_local_scanner_session_is_classified_like_a_proc_one() {
        // LocalScanner's rows (the Developer ID app and the LoginItem
        // helper) are `local-<pid>`. They read "Recent activity" while
        // the classifier tested for `proc-` alone.
        let now = referenceNow
        XCTAssertEqual(C.classify(make(id: "local-12345", ageSeconds: 30, now: now), now: now), .activeProcess)
        XCTAssertEqual(C.classify(make(id: "local-12345", ageSeconds: 300, now: now), now: now), .activeProcess)
        XCTAssertEqual(C.classify(make(id: "local-12345", ageSeconds: 600, now: now), now: now), .hidden)
    }

    // MARK: - JSONL-synthesized sessions

    func test_jsonl_session_under_5min_is_activeJsonl() {
        let now = referenceNow
        let s = make(id: "jsonl-claude-abc", ageSeconds: 60, now: now)
        XCTAssertEqual(C.classify(s, now: now), .activeJsonl)
    }

    func test_jsonl_session_at_exact_5min_is_activeJsonl() {
        let now = referenceNow
        let s = make(id: "jsonl-claude-abc", ageSeconds: 300, now: now)
        XCTAssertEqual(C.classify(s, now: now), .activeJsonl)
    }

    func test_jsonl_session_between_5min_and_30min_is_recentJsonl() {
        let now = referenceNow
        let s = make(id: "jsonl-claude-abc", ageSeconds: 600, now: now)
        XCTAssertEqual(C.classify(s, now: now), .recentJsonl)
    }

    func test_jsonl_session_at_exact_30min_is_recentJsonl() {
        let now = referenceNow
        let s = make(id: "jsonl-claude-abc", ageSeconds: 1800, now: now)
        XCTAssertEqual(C.classify(s, now: now), .recentJsonl)
    }

    func test_jsonl_session_past_30min_is_hidden() {
        let now = referenceNow
        let s = make(id: "jsonl-claude-abc", ageSeconds: 1801, now: now)
        XCTAssertEqual(C.classify(s, now: now), .hidden)
    }

    // MARK: - rows with no prefix

    func test_cloud_row_without_prefix_uses_jsonl_age_tiers() {
        // No producer uploads a row without a scan prefix today (every
        // cloud session is `local-` or `proc-`), but one that did would
        // be treated as JSONL-equivalent — we don't know whether a
        // remote process is alive, only what Supabase last persisted.
        let now = referenceNow
        let id = "cloud-uuid-from-other-device"
        let fresh = make(id: id, ageSeconds: 60, now: now)
        let stale = make(id: id, ageSeconds: 600, now: now)
        let dropped = make(id: id, ageSeconds: 2000, now: now)
        XCTAssertEqual(C.classify(fresh, now: now), .activeJsonl)
        XCTAssertEqual(C.classify(stale, now: now), .recentJsonl)
        XCTAssertEqual(C.classify(dropped, now: now), .hidden)
    }

    // MARK: - artifacts always hidden, even with proc- prefix

    func test_application_path_artifact_hidden_regardless_of_age() {
        let now = referenceNow
        let s = make(
            id: "proc-12345",
            name: "/Applications/Claude.app/Contents/MacOS/Claude",
            ageSeconds: 30,
            now: now
        )
        XCTAssertEqual(C.classify(s, now: now), .hidden)
    }

    func test_node_no_warnings_artifact_hidden() {
        let now = referenceNow
        let s = make(
            id: "proc-99",
            name: "node --no-warnings /usr/local/lib/codex/cli.js",
            ageSeconds: 5,
            now: now
        )
        XCTAssertEqual(C.classify(s, now: now), .hidden)
    }

    // MARK: - garbage / future timestamp

    func test_unparseable_last_active_is_hidden() {
        let now = referenceNow
        let s = SessionRecord(
            id: "proc-1",
            name: "Claude",
            provider: "Claude",
            project: "x",
            device_name: "Mac",
            started_at: "not-a-timestamp",
            last_active_at: "also-bad",
            status: "running",
            total_usage: 0,
            estimated_cost: 0,
            cost_status: "Estimated",
            requests: 0,
            error_count: 0
        )
        XCTAssertEqual(C.classify(s, now: now), .hidden)
    }

    func test_future_last_active_is_hidden() {
        let now = referenceNow
        // Negative age = clock skew on the helper. Don't trust.
        let s = make(id: "proc-1", ageSeconds: -10, now: now)
        XCTAssertEqual(C.classify(s, now: now), .hidden)
    }

    // MARK: - partition()

    func test_partition_bins_active_and_recent_correctly() {
        let now = referenceNow
        let activeProc = make(id: "proc-1", ageSeconds: 30, now: now)
        let activeJsonl = make(id: "jsonl-claude-a", ageSeconds: 100, now: now)
        let recentJsonl = make(id: "jsonl-claude-b", ageSeconds: 900, now: now)
        let hidden = make(id: "jsonl-claude-c", ageSeconds: 3600, now: now)
        let (active, recent) = C.partition(
            [hidden, recentJsonl, activeJsonl, activeProc],
            now: now
        )
        XCTAssertEqual(active.map(\.id), ["proc-1", "jsonl-claude-a"])
        XCTAssertEqual(recent.map(\.id), ["jsonl-claude-b"])
    }

    func test_partition_sorts_each_bucket_by_recency_desc() {
        let now = referenceNow
        let older = make(id: "proc-1", ageSeconds: 120, now: now)
        let newer = make(id: "proc-2", ageSeconds: 30, now: now)
        let (active, _) = C.partition([older, newer], now: now)
        XCTAssertEqual(active.map(\.id), ["proc-2", "proc-1"])
    }

    // MARK: - tier metadata

    func test_isVisible_matches_section_assignment() {
        XCTAssertTrue(FreshnessTier.activeProcess.isVisible)
        XCTAssertTrue(FreshnessTier.activeJsonl.isVisible)
        XCTAssertTrue(FreshnessTier.recentJsonl.isVisible)
        XCTAssertFalse(FreshnessTier.hidden.isVisible)
    }

    func test_section_assignment() {
        XCTAssertEqual(FreshnessTier.activeProcess.section, .active)
        XCTAssertEqual(FreshnessTier.activeJsonl.section, .active)
        XCTAssertEqual(FreshnessTier.recentJsonl.section, .recent)
        XCTAssertEqual(FreshnessTier.hidden.section, .hidden)
    }

    func test_badge_strings_are_short_and_distinct() {
        let saved = LocaleOverrideStore.shared.override
        defer { LocaleOverrideStore.shared.set(saved) }
        LocaleOverrideStore.shared.set("en")

        // Sentence case, like the status pill ("Running") the process rows show
        // beside them.
        XCTAssertEqual(FreshnessTier.activeProcess.badge, "Running")
        XCTAssertEqual(FreshnessTier.activeJsonl.badge,   "Recent activity")
        XCTAssertEqual(FreshnessTier.recentJsonl.badge,   "Recent")
        XCTAssertEqual(FreshnessTier.hidden.badge,        "")
    }

    /// The legend under the list explains the chips, so each of its lines
    /// has to name its chip exactly as the chip reads. It used to explain one
    /// state ("Recent = JSONL activity only") for two different chips, and
    /// zh-Hant joined the two names with a slash without saying how they
    /// differ.
    ///
    /// Referential on purpose: it reads the badge and the status pill, not a
    /// copy of their text, so rewording a badge without its line fails here.
    func test_each_legend_line_names_its_badge_in_every_locale() {
        let saved = LocaleOverrideStore.shared.override
        defer { LocaleOverrideStore.shared.set(saved) }

        for locale in ["en", "es", "ja", "ko", "zh-Hans", "zh-Hant"] {
            LocaleOverrideStore.shared.set(locale)
            // Process-confirmed rows show the status pill, not tier.badge.
            let lines: [(String, String)] = [
                (L10n.sessions.legendRunning, L10n.status.localized("running")),
                (L10n.sessions.legendRecentActivity, FreshnessTier.activeJsonl.badge),
                (L10n.sessions.legendRecent, FreshnessTier.recentJsonl.badge),
            ]
            for (line, name) in lines {
                XCTAssertFalse(line.hasPrefix("sessions."), "\(locale) renders the raw key")
                XCTAssertFalse(name.isEmpty)
                // "<name> =" at the start, every line's form. A bare
                // `contains` would let "Recent" pass on the strength of
                // "Recent activity".
                XCTAssertTrue(line.hasPrefix("\(name) ="), "\(locale) line does not define \"\(name)\": \(line)")
            }
        }
    }

    /// v1.58: the legend explains the badges the list shows, and only
    /// those. Since 1.57 every session the account holds is a process-scan
    /// row, so the iPhone and iPad lists read "Running" alone, while the
    /// legend went on defining "Recent activity" and "Recent", which no row
    /// wore; in Spanish it defined "Activa" under an "Activas" header whose
    /// rows all read "En ejecución". Asserted in zh-Hans: the English
    /// fallback of a missing key reads as English.
    func test_the_legend_explains_only_the_badges_the_rows_wear() {
        let saved = LocaleOverrideStore.shared.override
        defer { LocaleOverrideStore.shared.set(saved) }
        LocaleOverrideStore.shared.set("zh-Hans")
        let now = referenceNow
        let running = make(id: "local-48213", ageSeconds: 60, now: now)
        let otherMac = make(id: "proc-3120", ageSeconds: 200, now: now)
        let recentLog = make(id: "jsonl-a", ageSeconds: 120, now: now)
        let olderLog = make(id: "jsonl-b", ageSeconds: 900, now: now)
        let stale = make(id: "local-1", ageSeconds: 3_600, now: now)

        // What the iPhone and iPad list: synced scan rows only.
        XCTAssertEqual(SessionFreshnessLegend.lines(for: [running, otherMac, stale], now: now),
                       ["运行中 = 已确认进程存在。"])
        XCTAssertEqual(SessionFreshnessLegend.text(for: [running, otherMac], now: now),
                       "运行中 = 已确认进程存在。")
        // A Mac with its own session logs: a line for each badge, in the
        // order the sections run.
        XCTAssertEqual(SessionFreshnessLegend.lines(for: [olderLog, recentLog, running], now: now),
                       ["运行中 = 已确认进程存在。", "最近活动 = 5 分钟内写入过日志。", "最近 = 30 分钟内写入过日志。"])
        XCTAssertEqual(SessionFreshnessLegend.lines(for: [olderLog], now: now), ["最近 = 30 分钟内写入过日志。"])
        // A row the list hides explains nothing; nothing listed, no legend.
        XCTAssertEqual(SessionFreshnessLegend.lines(for: [stale], now: now), [])
        XCTAssertNil(SessionFreshnessLegend.text(for: [stale], now: now))
        XCTAssertNil(SessionFreshnessLegend.text(for: [], now: now))
        // One line a badge.
        XCTAssertEqual(SessionFreshnessLegend.text(for: [running, olderLog], now: now),
                       "运行中 = 已确认进程存在。\n最近 = 30 分钟内写入过日志。")
    }

    /// v1.58: in Spanish the "Recent activity" badge read "Activa", so a row
    /// known only from its log sat under the "Activas" header beside
    /// "En ejecución" rows, which are active too, and the legend defined
    /// "Activa" as something narrower than its header. It says what the
    /// English badge says now.
    func test_spanish_recent_activity_badge_is_not_the_active_header() {
        let saved = LocaleOverrideStore.shared.override
        defer { LocaleOverrideStore.shared.set(saved) }
        LocaleOverrideStore.shared.set("es")
        XCTAssertEqual(FreshnessTier.activeJsonl.badge, "Actividad reciente")
        XCTAssertEqual(L10n.sessions.legendRecentActivity,
                       "Actividad reciente = registro escrito en los últimos 5 min.")
        XCTAssertFalse(L10n.sessions.sectionActive.lowercased()
            .hasPrefix(FreshnessTier.activeJsonl.badge.lowercased()))
    }

    /// v1.58: the iPhone's and iPad's session count (the Overview's Sessions
    /// tile, the iPad sidebar's Active Sessions) is the rows the Sessions tab
    /// lists under Active. `dashboard_summary` counts every row still marked
    /// Running, and a row is marked Ended only when its Mac syncs again, so a
    /// Mac that went to sleep with AI tools open left them on the tile while
    /// the tab, which drops a scan row its producer stopped rewriting, listed
    /// none.
    func test_the_session_count_is_the_rows_listed_under_active() {
        let now = referenceNow
        let running = make(id: "local-48213", ageSeconds: 60, now: now)
        let otherMac = make(id: "proc-3120", ageSeconds: 299, now: now)
        // Marked Running on the server, its Mac asleep for an hour.
        let asleep = make(id: "local-77", ageSeconds: 3_600, now: now, status: "Running")
        let recentLog = make(id: "jsonl-a", ageSeconds: 120, now: now)
        let olderLog = make(id: "jsonl-b", ageSeconds: 900, now: now)
        let rows = [running, otherMac, asleep, recentLog, olderLog]
        XCTAssertEqual(SessionListCount.active(rows, now: now), 3)
        XCTAssertEqual(SessionListCount.active(rows, now: now),
                       C.partition(rows, now: now).active.count, "the tile and the Active section disagree")
        XCTAssertEqual(SessionListCount.active([asleep], now: now), 0)
        XCTAssertEqual(SessionListCount.active([], now: now), 0)
    }

    /// v1.58: Demo is one refresh that never runs again, and its sessions
    /// were written at it. Classified against the clock, every one was
    /// hidden about three and a half minutes after Try Demo: the Sessions
    /// tab emptied, and the iPhone's Overview tile and the iPad sidebar
    /// counted 0. Against Demo's own clock (`AppState.sessionsClock`) they
    /// stay as Demo was entered, however long it stays open.
    @MainActor
    func test_demo_sessions_stay_listed_on_demos_own_clock() {
        let suite = "SessionFreshnessTierTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(
            runtimeEnvironment: .resolveForTesting(infoDictionary: [:], environment: [:]),
            defaults: defaults,
            performLaunchSetup: false)
        let real = Date()
        XCTAssertEqual(state.sessionsClock(now: real), real, "outside Demo the lists read the clock")

        state.enterDemoMode()
        let entered = SessionListCount.active(state.sessions, now: state.sessionsClock())
        XCTAssertEqual(entered, 3, "Demo's three sessions read Running")
        for minutes in [4.0, 10, 60] {
            let later = Date().addingTimeInterval(minutes * 60)
            let clock = state.sessionsClock(now: later)
            XCTAssertEqual(SessionListCount.active(state.sessions, now: clock), entered, "\(minutes) min into Demo")
            XCTAssertEqual(C.partition(state.sessions, now: clock).active.count, entered, "\(minutes) min: the tab")
            XCTAssertEqual(SessionFreshnessLegend.lines(for: state.sessions, now: clock),
                           [L10n.sessions.legendRunning], "\(minutes) min: the legend")
        }
        // What the lists read before: the clock hides them all.
        XCTAssertEqual(SessionListCount.active(state.sessions, now: Date().addingTimeInterval(600)), 0)
    }

    // MARK: - Claude Code 2.x user-Library binaries are NOT artifacts

    /// Claude Code 2.x packages its CLI as `claude.app` under the
    /// user's Library. The helper's `_pretty_name` truncates the
    /// `ps` command to ≤48 chars, which surfaces a session name like
    /// `/Users/jason/Library/Application Support/Claud...`. The
    /// earlier filter dropped any path-prefixed name, hiding the
    /// real CLI even when the helper saw it as a live process.
    func test_claude_code_2x_user_library_path_kept_as_activeProcess() {
        let now = referenceNow
        let s = make(
            id: "proc-6168",
            name: "/Users/jason/Library/Application Support/Claude/claude-code/2.1.121/claude.app/Contents/MacOS/claude --output-format stream-json",
            ageSeconds: 30,
            now: now
        )
        XCTAssertEqual(C.classify(s, now: now), .activeProcess,
                       "Claude Code 2.x user-Library path must NOT be filtered as artifact")
    }

    func test_truncated_user_library_path_kept_as_activeProcess() {
        // _pretty_name caps at 48 chars + "..." — pin the exact shape
        // the helper would emit so a future truncation tweak can't
        // silently re-introduce the false-positive.
        let now = referenceNow
        let s = make(
            id: "proc-6168",
            name: "/Users/jason/Library/Application Support/Cl...",
            ageSeconds: 30,
            now: now
        )
        XCTAssertEqual(C.classify(s, now: now), .activeProcess)
    }

    func test_plain_codex_command_kept_as_activeProcess() {
        let now = referenceNow
        let s = make(id: "proc-7777", name: "codex", ageSeconds: 5, now: now)
        XCTAssertEqual(C.classify(s, now: now), .activeProcess)
    }

    func test_homebrew_codex_path_kept_as_activeProcess() {
        let now = referenceNow
        let s = make(
            id: "proc-7777",
            name: "/usr/local/bin/codex --some-flag",
            ageSeconds: 5,
            now: now
        )
        XCTAssertEqual(C.classify(s, now: now), .activeProcess)
    }

    // MARK: - actual artifacts still get hidden

    func test_applications_claude_app_macos_binary_hidden() {
        let now = referenceNow
        let s = make(
            id: "proc-1",
            name: "/Applications/Claude.app/Contents/MacOS/Claude",
            ageSeconds: 5,
            now: now
        )
        XCTAssertEqual(C.classify(s, now: now), .hidden)
    }

    func test_applications_claude_disclaimer_helper_hidden() {
        let now = referenceNow
        let s = make(
            id: "proc-1",
            name: "/Applications/Claude.app/Contents/Helpers/disclaimer /Users/jason/Library/...",
            ageSeconds: 5,
            now: now
        )
        XCTAssertEqual(C.classify(s, now: now), .hidden)
    }

    func test_applications_frameworks_subprocess_hidden() {
        let now = referenceNow
        let s = make(
            id: "proc-1",
            name: "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper",
            ageSeconds: 5,
            now: now
        )
        XCTAssertEqual(C.classify(s, now: now), .hidden)
    }

    func test_electron_renderer_subprocess_hidden() {
        let now = referenceNow
        let s = make(
            id: "proc-1",
            name: "claude --type=renderer --enable-features=...",
            ageSeconds: 5,
            now: now
        )
        XCTAssertEqual(C.classify(s, now: now), .hidden)
    }

    func test_electron_gpu_process_hidden() {
        let now = referenceNow
        let s = make(
            id: "proc-1",
            name: "Codex Helper --type=gpu-process --field-trial-handle=...",
            ageSeconds: 5,
            now: now
        )
        XCTAssertEqual(C.classify(s, now: now), .hidden)
    }

    func test_nativehost_bridge_hidden() {
        let now = referenceNow
        let s = make(
            id: "proc-1",
            name: "/Applications/SomeApp.app/Contents/Resources/bin/nativehost",
            ageSeconds: 5,
            now: now
        )
        XCTAssertEqual(C.classify(s, now: now), .hidden)
    }

    // MARK: - header running count contract

    func test_running_count_only_includes_activeProcess() {
        // Mirror the macOS / iOS header-count code: count only rows
        // whose tier is `.activeProcess`. JSONL rows must NOT bump
        // the green pill from "0" to a positive number.
        let now = referenceNow
        let sessions = [
            make(id: "proc-1",       ageSeconds: 30,  now: now),
            make(id: "proc-2",       ageSeconds: 60,  now: now),
            make(id: "jsonl-claude-a", ageSeconds: 100, now: now),  // .activeJsonl
            make(id: "jsonl-claude-b", ageSeconds: 800, now: now),  // .recentJsonl
        ]
        let count = sessions.reduce(0) { acc, s in
            acc + (C.classify(s, now: now) == .activeProcess ? 1 : 0)
        }
        XCTAssertEqual(count, 2,
                       "Only the two proc-* rows should count as running")
    }

    func test_running_count_zero_when_only_jsonl_rows() {
        // The exact case from Jason's screenshot: 3 JSONL rows, no
        // helper proc-* rows. Pre-fix the header pill said "3 运行中";
        // post-fix it must say nothing (count == 0).
        let now = referenceNow
        let sessions = [
            make(id: "jsonl-codex-a",  ageSeconds: 180, now: now),
            make(id: "jsonl-claude-b", ageSeconds: 240, now: now),
            make(id: "jsonl-claude-c", ageSeconds: 240, now: now),
        ]
        let count = sessions.reduce(0) { acc, s in
            acc + (C.classify(s, now: now) == .activeProcess ? 1 : 0)
        }
        XCTAssertEqual(count, 0)
    }

    // MARK: - against filterCurrent

    /// Process-scan rows (`local-` and `proc-`) read Running exactly as long
    /// as `filterCurrent`'s 300 s rule keeps them, so a row a refresh lists
    /// is never hidden from the list before the next refresh.
    ///
    /// It used to be tighter (180 s), on the premise that the helper
    /// rewrites its rows every 60 s. Every producer's default cycle is
    /// 120 s, so with the app's 2-minute refresh a live process could be
    /// 240 s old in the list and was hidden.
    func test_classifier_agrees_with_filterCurrent_on_scan_rows() {
        let now = referenceNow
        for id in ["proc-1", "local-1"] {
            for age: TimeInterval in [200, 240, 300] {
                let s = make(id: id, ageSeconds: age, now: now)
                XCTAssertEqual(SessionFreshnessFilter.filterCurrent([s], now: now).count, 1, "\(id) at \(age) s")
                XCTAssertEqual(C.classify(s, now: now), .activeProcess, "\(id) at \(age) s")
            }
            let stale = make(id: id, ageSeconds: 301, now: now)
            XCTAssertEqual(SessionFreshnessFilter.filterCurrent([stale], now: now).count, 0, id)
            XCTAssertEqual(C.classify(stale, now: now), .hidden, id)
        }
    }

    /// JSONL rows older than 300 s are LOOSER: `filterCurrent` drops
    /// them, the tier system shows them in the Recent section up to
    /// 30 min. `filterCurrent` itself is unchanged so the cloud merge
    /// route keeps its prior contract; the partition is the new surface.
    func test_classifier_keeps_jsonl_past_filterCurrent_window() {
        let now = referenceNow
        let s = make(id: "jsonl-claude-a", ageSeconds: 600, now: now)
        // filterCurrent (300s window) drops it…
        XCTAssertEqual(
            SessionFreshnessFilter.filterCurrent([s], now: now).count, 0
        )
        // …but the new tier classifier surfaces it in the Recent
        // section.
        XCTAssertEqual(C.classify(s, now: now), .recentJsonl)
    }
}
