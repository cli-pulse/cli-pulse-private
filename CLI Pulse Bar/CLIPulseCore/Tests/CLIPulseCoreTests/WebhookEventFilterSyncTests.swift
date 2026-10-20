// 1.58: the account's webhook event filter, read back and saved whole.
//
// Before 1.58 the Mac never read `user_settings.webhook_event_filter`: every
// launch started with no chip selected, the first change saved this launch's
// chips over the account's filter, and clearing the last chip sent nothing
// (an empty filter was passed as `nil`, which a `SettingsPatch` leaves out),
// so a filter could not be cleared from a Mac at all.

import Foundation
import XCTest
@testable import CLIPulseCore

@MainActor
final class WebhookEventFilterSyncTests: XCTestCase {
    private let userID = "6f1c2a4e-3b5d-4c7e-9a1b-2d3e4f5a6b7c"
    private var outboxDefaults: UserDefaults!
    private var outboxSuite: String!

    override func setUp() {
        super.setUp()
        WebhookFilterStubProtocol.reset()
        outboxSuite = "WebhookEventFilterSyncTests-\(UUID().uuidString)"
        outboxDefaults = UserDefaults(suiteName: outboxSuite)
    }

    override func tearDown() {
        WebhookFilterStubProtocol.reset()
        outboxDefaults.removePersistentDomain(forName: outboxSuite)
        outboxDefaults = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeAPI() async -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebhookFilterStubProtocol.self]
        let api = APIClient(
            supabaseURL: "https://webhook-filter.test",
            supabaseAnonKey: "anon",
            session: URLSession(configuration: configuration))
        _ = await api.beginExternalAuthorizationTransition(generation: 1)
        _ = await api.installExternalAuthenticatedSession(
            accessToken: "token-a", refreshToken: "refresh-a", userID: userID, transitionGeneration: 1)
        return api
    }

    private func makeState(api: APIClient) -> AppState {
        let state = AppState(
            api: api,
            providerAccountDeletionOutbox: ProviderAccountDeletionOutbox(
                defaults: outboxDefaults, storageKey: "outbox-\(UUID().uuidString)"),
            performLaunchSetup: false)
        state.isAuthenticated = true
        state.userId = userID
        return state
    }

    /// A settings row as PostgREST returns it, with `filterJSON` as the
    /// `webhook_event_filter` column (`nil` leaves the key out).
    private func settingsRows(filterJSON: String?) -> Data {
        var fields = [#""user_id":"\#(userID)""#, #""track_git_activity":true"#]
        if let filterJSON { fields.append(#""webhook_event_filter":\#(filterJSON)"#) }
        return Data("[{\(fields.joined(separator: ","))}]".utf8)
    }

    private func answerSettingsRead(with rows: Data) {
        WebhookFilterStubProtocol.handler = { request in
            if request.httpMethod == "GET" { return (200, rows) }
            return (201, Data())
        }
    }

    /// The JSON bodies of the settings writes, in the order they were sent.
    private func settingsWrites() throws -> [[String: Any]] {
        try WebhookFilterStubProtocol.recordedRequests()
            .filter { $0.httpMethod == "POST" && $0.url?.path == "/rest/v1/user_settings" }
            .map { request in
                let body = try XCTUnwrap(request.httpBody)
                return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            }
    }

    private func withLocale(_ id: String, _ body: () -> Void) {
        let store = LocaleOverrideStore.shared
        let previous = store.override
        store.set(id)
        defer { store.set(previous) }
        body()
    }

    // MARK: - Reading the saved filter

    func test_a_filter_android_saved_without_its_empty_lists_reads() throws {
        // Android writes only the lists that hold something.
        let filter = try JSONDecoder().decode(
            WebhookEventFilter.self, from: Data(#"{"types":["cost_spike"]}"#.utf8))
        XCTAssertEqual(filter, WebhookEventFilter(types: ["cost_spike"]),
                       "a filter without all three lists did not read")
    }

    func test_the_settings_read_returns_the_saved_filter() async throws {
        answerSettingsRead(with: settingsRows(
            filterJSON: #"{"severities":["Critical"],"types":["device_offline"],"providers":["Claude"]}"#))
        let snapshot = try await makeAPI().settings()
        XCTAssertEqual(snapshot.webhook_event_filter,
                       WebhookEventFilter(severities: ["Critical"], types: ["device_offline"], providers: ["Claude"]))
    }

    func test_no_saved_filter_reads_as_an_empty_filter() async throws {
        let api = await makeAPI()
        for rows in [settingsRows(filterJSON: "null"), settingsRows(filterJSON: nil), Data("[]".utf8)] {
            answerSettingsRead(with: rows)
            let snapshot = try await api.settings()
            XCTAssertEqual(snapshot.webhook_event_filter, WebhookEventFilter(),
                           String(decoding: rows, as: UTF8.self))
        }
    }

    /// A filter this build cannot read is neither "no filter" (which the next
    /// save would overwrite) nor a failed read of every other setting.
    func test_an_unreadable_filter_is_kept_apart_and_the_other_settings_still_read() async throws {
        let api = await makeAPI()
        for unreadable in [#"{"types":"cost_spike"}"#, #""cost_spike""#, "[1,2]"] {
            answerSettingsRead(with: settingsRows(filterJSON: unreadable))
            let snapshot = try await api.settings()
            XCTAssertNil(snapshot.webhook_event_filter, unreadable)
            XCTAssertTrue(snapshot.track_git_activity, "an unreadable filter failed the whole read")
        }
    }

    // MARK: - Saving

    func test_an_empty_filter_is_saved_as_null_and_nothing_else_is_sent() async throws {
        WebhookFilterStubProtocol.handler = { _ in (201, Data()) }
        let api = await makeAPI()
        try await api.updateWebhookEventFilter(WebhookEventFilter())
        try await api.updateWebhookEventFilter(WebhookEventFilter(severities: ["Warning"]))

        let writes = try settingsWrites()
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(Set(writes[0].keys), ["user_id", "webhook_event_filter"])
        XCTAssertTrue(writes[0]["webhook_event_filter"] is NSNull,
                      "clearing the filter sent \(String(describing: writes[0]["webhook_event_filter"]))")
        let saved = try XCTUnwrap(writes[1]["webhook_event_filter"] as? [String: Any])
        XCTAssertEqual(saved["severities"] as? [String], ["Warning"])
        XCTAssertEqual(saved["types"] as? [String], [])
    }

    /// iPhone parity: the iPhone has no filter chips and saves its webhook
    /// switch and URL through `pushSettingsToServer`, as the Mac does. That
    /// write must not carry the filter, or every iPhone toggle would replace
    /// the filter set on a Mac or on Android.
    func test_the_switch_and_url_save_never_carries_the_filter() async throws {
        WebhookFilterStubProtocol.handler = { _ in (201, Data()) }
        let state = makeState(api: await makeAPI())
        // Not read yet, as on an iPhone, and read, as on a Mac.
        await state.pushSettingsToServer().value
        state.applySavedWebhookEventFilter(WebhookEventFilter(types: ["cost_spike"]), readAt: state.webhookEventFilterEpoch)
        await state.pushSettingsToServer().value

        let writes = try settingsWrites()
        XCTAssertEqual(writes.count, 2)
        for write in writes {
            XCTAssertNil(write["webhook_event_filter"], "the switch-and-URL save carried the filter")
            XCTAssertNotNil(write["webhook_enabled"])
        }
        // And the general patch cannot carry it at all.
        let patch = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(state.webhookSettingsPatch())) as? [String: Any]
        XCTAssertNil(patch?["webhook_event_filter"])
    }

    // MARK: - The Mac's chips

    func test_chips_cannot_change_until_the_saved_filter_is_read() async throws {
        WebhookFilterStubProtocol.handler = { _ in (201, Data()) }
        let state = makeState(api: await makeAPI())
        XCTAssertFalse(state.webhookEventFilterLoaded)
        XCTAssertNil(state.editWebhookEventFilter { $0.severities = ["Critical"] },
                     "a change before the read would save these chips over the account's filter")
        XCTAssertEqual(state.webhookEventFilter, WebhookEventFilter())
        XCTAssertTrue(WebhookFilterStubProtocol.recordedRequests().isEmpty)
    }

    func test_the_refresh_read_loads_the_saved_filter() async throws {
        let saved = WebhookEventFilter(severities: ["Critical", "Warning"], types: ["quota_exceeded"])
        answerSettingsRead(with: settingsRows(
            filterJSON: #"{"severities":["Critical","Warning"],"types":["quota_exceeded"]}"#))
        let state = makeState(api: await makeAPI())
        await state.loadWebhookEventFilter()
        XCTAssertTrue(state.webhookEventFilterLoaded)
        XCTAssertEqual(state.webhookEventFilter, saved, "the chips did not show the account's saved filter")
    }

    func test_a_change_saves_the_whole_filter_and_clearing_it_saves_null() async throws {
        WebhookFilterStubProtocol.handler = { _ in (201, Data()) }
        let state = makeState(api: await makeAPI())
        // Saved elsewhere: a type this Mac shows and a provider it does not.
        state.applySavedWebhookEventFilter(
            WebhookEventFilter(types: ["cost_spike"], providers: ["Codex"]), readAt: state.webhookEventFilterEpoch)

        await state.editWebhookEventFilter { $0.severities.append("Critical") }?.value
        await state.editWebhookEventFilter { $0 = WebhookEventFilter() }?.value

        let writes = try settingsWrites()
        XCTAssertEqual(writes.count, 2)
        let first = try XCTUnwrap(writes[0]["webhook_event_filter"] as? [String: Any])
        XCTAssertEqual(first["severities"] as? [String], ["Critical"])
        XCTAssertEqual(first["types"] as? [String], ["cost_spike"], "the saved type was dropped")
        XCTAssertEqual(first["providers"] as? [String], ["Codex"], "what the Mac does not show was dropped")
        XCTAssertTrue(writes[1]["webhook_event_filter"] is NSNull, "an emptied filter was not sent")
        XCTAssertEqual(state.webhookEventFilter, WebhookEventFilter())
    }

    func test_saves_reach_the_server_in_order_with_the_latest_filter() async throws {
        WebhookFilterStubProtocol.handler = { _ in (201, Data()) }
        let state = makeState(api: await makeAPI())
        state.applySavedWebhookEventFilter(WebhookEventFilter(), readAt: state.webhookEventFilterEpoch)
        // Three quick changes before any save has run.
        state.editWebhookEventFilter { $0.severities = ["Critical"] }
        state.editWebhookEventFilter { $0.severities = ["Critical", "Warning"] }
        let last = state.editWebhookEventFilter { $0.types = ["device_offline"] }
        await last?.value

        let saved = try settingsWrites().compactMap { $0["webhook_event_filter"] as? [String: Any] }
        XCTAssertEqual(saved.count, 3)
        XCTAssertEqual(saved.last?["severities"] as? [String], ["Critical", "Warning"])
        XCTAssertEqual(saved.last?["types"] as? [String], ["device_offline"],
                       "the server's last write was not the last change")
        // Each save sends the filter as it is when its turn comes, so no
        // write, whatever order the requests finish in, holds an older one.
        for write in saved {
            XCTAssertEqual(write["types"] as? [String], ["device_offline"], "a save sent an older filter")
        }
        XCTAssertEqual(state.webhookEventFilterSavesInFlight, 0)
    }

    /// A read that began before a change, or that lands while a save is on
    /// its way, may hold the filter from before the change.
    func test_a_read_older_than_a_change_does_not_put_the_old_chips_back() async throws {
        WebhookFilterStubProtocol.handler = { _ in (201, Data()) }
        let state = makeState(api: await makeAPI())
        state.applySavedWebhookEventFilter(WebhookEventFilter(), readAt: state.webhookEventFilterEpoch)
        let old = WebhookEventFilter()
        let changed = WebhookEventFilter(severities: ["Info"])

        let readBeganBefore = state.webhookEventFilterEpoch
        let save = state.editWebhookEventFilter { $0 = changed }
        // Began after the change, landing while its save is on its way.
        state.applySavedWebhookEventFilter(old, readAt: state.webhookEventFilterEpoch)
        XCTAssertEqual(state.webhookEventFilter, changed, "a read during the save undid the change")
        await save?.value
        // Began before the change, landing after the save.
        state.applySavedWebhookEventFilter(old, readAt: readBeganBefore)
        XCTAssertEqual(state.webhookEventFilter, changed, "a read from before the change undid it")
        // A read that began after the save is the account's filter again.
        state.applySavedWebhookEventFilter(WebhookEventFilter(severities: ["Warning"]),
                                           readAt: state.webhookEventFilterEpoch)
        XCTAssertEqual(state.webhookEventFilter, WebhookEventFilter(severities: ["Warning"]))
    }

    func test_an_unreadable_saved_filter_cannot_be_overwritten_from_the_chips() async throws {
        WebhookFilterStubProtocol.handler = { _ in (201, Data()) }
        let state = makeState(api: await makeAPI())
        state.applySavedWebhookEventFilter(nil, readAt: state.webhookEventFilterEpoch)
        XCTAssertFalse(state.webhookEventFilterLoaded)
        XCTAssertNil(state.editWebhookEventFilter { $0.severities = ["Critical"] })
        XCTAssertTrue(try settingsWrites().isEmpty)
    }

    /// Signing out, or another account signing in, returns the chips to "not
    /// read yet"; a save still queued for the previous account sends nothing,
    /// where it would have written into the next one.
    func test_another_account_never_receives_the_previous_accounts_filter() async throws {
        WebhookFilterStubProtocol.handler = { _ in (201, Data()) }
        let state = makeState(api: await makeAPI())
        state.applySavedWebhookEventFilter(WebhookEventFilter(), readAt: state.webhookEventFilterEpoch)
        let queued = state.editWebhookEventFilter { $0.types = ["cost_spike"] }

        state.resetWebhookEventFilter()   // what sign-out and an account switch call
        state.userId = "0b9e8d7c-6f5a-4b3c-9d2e-1f0a9b8c7d6e"
        await queued?.value

        XCTAssertTrue(try settingsWrites().isEmpty, "a save for the previous account was sent")
        XCTAssertFalse(state.webhookEventFilterLoaded)
        XCTAssertEqual(state.webhookEventFilter, WebhookEventFilter())
    }

    func test_sign_out_and_an_account_switch_reset_the_filter() throws {
        // Both paths run Keychain and helper side effects a unit test should
        // not, so their wiring is checked in the source.
        let auth = try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Sources/CLIPulseCore/AuthManager.swift"),
            encoding: .utf8)
        func body(of function: String) throws -> Substring {
            let start = try XCTUnwrap(auth.range(of: "func \(function)("), function)
            let rest = auth[start.upperBound...]
            let end = rest.range(of: "\n    func ")?.lowerBound ?? rest.endIndex
            return rest[..<end]
        }
        XCTAssertTrue(try body(of: "applySignedOutState").contains("resetWebhookEventFilter()"))
        XCTAssertTrue(try body(of: "applyAuthenticatedState")
            .contains("if userId != session.userId { resetWebhookEventFilter() }"))
    }

    // MARK: - The retired type

    /// "Long session" is not offered, but a filter that holds it shows it,
    /// selected, with a line saying it is no longer raised; deselected, it is
    /// gone and not offered again.
    func test_a_saved_retired_type_is_shown_until_deselected() async throws {
        WebhookFilterStubProtocol.handler = { _ in (201, Data()) }
        let state = makeState(api: await makeAPI())
        XCTAssertFalse(WebhookEventFilter.typeChips(for: WebhookEventFilter()).contains("session_long"))

        state.applySavedWebhookEventFilter(WebhookEventFilter(types: ["session_long"]),
                                           readAt: state.webhookEventFilterEpoch)
        XCTAssertEqual(WebhookEventFilter.typeChips(for: state.webhookEventFilter),
                       ["cost_spike", "quota_exceeded", "device_offline", "session_long"],
                       "a selected type nobody can see")
        withLocale("zh-Hans") {
            XCTAssertEqual(WebhookEventFilter.retiredTypeNote(for: state.webhookEventFilter),
                           "已不再产生“会话时间过长”告警。取消选择即可将其从筛选中移除。")
        }

        await state.editWebhookEventFilter { $0.types.removeAll { $0 == "session_long" } }?.value
        XCTAssertFalse(WebhookEventFilter.typeChips(for: state.webhookEventFilter).contains("session_long"))
        XCTAssertNil(WebhookEventFilter.retiredTypeNote(for: state.webhookEventFilter))
        XCTAssertTrue(try settingsWrites().last?["webhook_event_filter"] is NSNull)
    }

    func test_the_not_loaded_line_is_translated() {
        withLocale("zh-Hans") {
            XCTAssertEqual(L10n.integrations.eventFilterNotLoaded, "已保存的筛选尚未加载，加载后才能更改。")
        }
    }

    // MARK: - The views

    /// The Mac's Integrations screen and the iPhone's run in app targets this
    /// bundle cannot run, so their wiring is checked in their source.
    func test_the_views_go_through_the_account_filter() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let mac = try String(contentsOf: app.appendingPathComponent("CLI Pulse Bar/GeneralSection.swift"),
                             encoding: .utf8)
        for wired in [
            "state.editWebhookEventFilter {",
            "isLoaded: state.webhookEventFilterLoaded,",
            "loadSaved: { await state.loadWebhookEventFilter() }",
            "ForEach(WebhookEventFilter.typeChips(for: filter), id: \\.self)",
            ".disabled(!isLoaded)",
            "WebhookEventFilter.retiredTypeNote(for: filter)",
        ] {
            XCTAssertTrue(mac.contains(wired), "GeneralSection.swift no longer has \(wired)")
        }
        XCTAssertFalse(mac.contains("onChange(of: state.webhookEventFilter)"),
                       "a change of the filter from a read would save it again")
        // The iPhone has no chips: it never edits the filter.
        let phone = try String(contentsOf: app.appendingPathComponent("CLI Pulse Bar iOS/iOSSettingsTab.swift"),
                               encoding: .utf8)
        XCTAssertFalse(phone.contains("webhookEventFilter"))
        XCTAssertTrue(phone.contains("state.pushSettingsToServer()"))
    }
}

private final class WebhookFilterStubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        handler = nil
        requests = []
    }

    static func recordedRequests() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var recorded = request
        if recorded.httpBody == nil, let stream = recorded.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            stream.close()
            recorded.httpBodyStream = nil
            recorded.httpBody = data
        }
        Self.lock.lock()
        Self.requests.append(recorded)
        let handler = Self.handler
        Self.lock.unlock()

        let (status, body) = handler?(recorded) ?? (500, Data())
        let response = HTTPURLResponse(
            url: recorded.url ?? URL(string: "https://webhook-filter.test")!,
            statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
