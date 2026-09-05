import XCTest
@testable import CLIPulseCore

private final class FunnelStore: AnonymousTelemetryStore, @unchecked Sendable {
    var isEnabled = true
    var hasSeenDisclosure = true
    var installID = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000001")!
    var installReported = false
    var activationReported = false
    var helperConnectedReported = false
    var costReported = false
    var remoteLANReported = false
    var remoteTailnetReported = false
    var remoteDelegateReported = false
    var remoteNonClaudeReported = false
}

private actor FunnelTransport: AnonymousTelemetryTransport {
    private(set) var sent: [AnonymousInstallPayload] = []
    /// Statuses to throw, one per attempt, before succeeding.
    private var scripted: [Int]
    /// The shape the fake server "accepts". `.legacy` simulates a database
    /// that has not had migrate_v0.76 applied: the transport downgrades and
    /// the v0.76 fields never arrive.
    private let accepts: AnonymousInstallPayload.WireVersion

    init(rejectWith: [Int] = [], accepts: AnonymousInstallPayload.WireVersion = .current) {
        self.scripted = rejectWith
        self.accepts = accepts
    }

    func send(_ payload: AnonymousInstallPayload) async throws -> AnonymousInstallPayload.WireVersion {
        if !scripted.isEmpty {
            throw SupabaseAnonymousTelemetryTransport.TransportError.rejected(status: scripted.removeFirst())
        }
        sent.append(accepts == .legacy ? payload.legacyShaped() : payload)
        return accepts
    }

    func payloads() -> [AnonymousInstallPayload] { sent }
}

/// A6 / migrate_v0.76 — the two new funnel milestones, the UI-language field,
/// and the wire shaping that lets the client meet a database the owner has not
/// migrated yet.
final class ActivationFunnelTelemetryTests: XCTestCase {

    private func makeSubject(
        store: FunnelStore,
        transport: FunnelTransport,
        language: ReportedUILanguage = .es
    ) -> AnonymousInstallTelemetry {
        AnonymousInstallTelemetry(
            store: store, transport: transport, channel: .devid,
            rawAppVersion: "1.53.0", osMajor: 15, osMinor: 2,
            uiLanguage: { language }
        )
    }

    // MARK: - The milestones

    func test_helperConnectedIsReportedOnceAndLatches() async {
        let store = FunnelStore()
        let transport = FunnelTransport()
        let subject = makeSubject(store: store, transport: transport)

        let first = await subject.recordHelperConnectedIfNeeded()
        let second = await subject.recordHelperConnectedIfNeeded()

        XCTAssertTrue(first)
        XCTAssertTrue(second, "already-recorded must read as recorded, not as a failure")
        let sent = await transport.payloads()
        XCTAssertEqual(sent.count, 1, "the latch must stop a second send")
        XCTAssertTrue(sent[0].helperConnected)
        XCTAssertTrue(store.helperConnectedReported)
        XCTAssertTrue(store.installReported, "any milestone also settles the install")
    }

    func test_costIsASeparateMilestoneFromProviderDetection() async {
        let store = FunnelStore()
        let transport = FunnelTransport()
        let subject = makeSubject(store: store, transport: transport)

        await subject.recordFirstProviderDetectedIfNeeded()
        let afterProvider = await transport.payloads()
        XCTAssertTrue(afterProvider[0].providerDetected)
        XCTAssertFalse(afterProvider[0].costShown,
                       "finding a CLI is not the same event as having a number to show")

        await subject.recordFirstCostIfNeeded()
        let afterCost = await transport.payloads()
        XCTAssertEqual(afterCost.count, 2)
        XCTAssertTrue(afterCost[1].costShown)
    }

    /// Every send carries the current state of ALL milestones, so one
    /// successful send backfills whatever earlier ones lost to a dead network.
    /// Without this the funnel would require the app to have been online at
    /// four separate moments.
    func test_aLaterSendCarriesTheMilestonesAlreadyReached() async {
        let store = FunnelStore()
        let transport = FunnelTransport()
        let subject = makeSubject(store: store, transport: transport)

        await subject.recordHelperConnectedIfNeeded()
        await subject.recordFirstProviderDetectedIfNeeded()
        await subject.recordFirstCostIfNeeded()

        let last = await transport.payloads().last!
        XCTAssertTrue(last.helperConnected)
        XCTAssertTrue(last.providerDetected)
        XCTAssertTrue(last.costShown)
    }

    /// The refusal path. A latch set on the ATTEMPT rather than the RESULT is
    /// the v1.45 activation defect; these milestones must not repeat it.
    func test_aRefusedSendDoesNotLatch() async {
        let store = FunnelStore()
        store.hasSeenDisclosure = false
        let transport = FunnelTransport()
        let subject = makeSubject(store: store, transport: transport)

        let refused = await subject.recordHelperConnectedIfNeeded()
        XCTAssertFalse(refused)
        XCTAssertFalse(store.helperConnectedReported, "a refusal must stay retryable")

        store.hasSeenDisclosure = true
        let accepted = await subject.recordHelperConnectedIfNeeded()
        XCTAssertTrue(accepted)
        XCTAssertTrue(store.helperConnectedReported)
    }

    func test_theSwitchStillGovernsTheNewMilestones() async {
        let store = FunnelStore()
        store.isEnabled = false
        let transport = FunnelTransport()
        let subject = makeSubject(store: store, transport: transport)

        await subject.recordHelperConnectedIfNeeded()
        await subject.recordFirstCostIfNeeded()

        let sent = await transport.payloads()
        XCTAssertTrue(sent.isEmpty, "off is off — not a reduced payload")
        XCTAssertFalse(store.helperConnectedReported)
        XCTAssertFalse(store.costReported)
    }

    /// CODEX REVIEW, 2026-08-30. The legacy fallback used to be treated as a
    /// full success: `send` did not throw, so the milestone latched — even
    /// though the legacy shape omits `p_helper_connected` entirely. The latch
    /// is PERSISTED, so once v0.76 landed the next launch would return early
    /// and the milestone was lost for the life of the install. Exactly the
    /// v1.45 activation defect (latch on attempt, not outcome) in a new
    /// disguise, in code whose own comments warn about it.
    func test_aLegacyFallbackDoesNotLatchTheV076Milestones() async {
        let store = FunnelStore()
        let transport = FunnelTransport(accepts: .legacy)
        let subject = makeSubject(store: store, transport: transport)

        let recorded = await subject.recordHelperConnectedIfNeeded()

        XCTAssertFalse(recorded, "a legacy send did not carry the milestone")
        XCTAssertFalse(store.helperConnectedReported,
                       "latching here loses the milestone permanently once v0.76 lands")
        // The install IS in the legacy shape, so that much is settled and the
        // next launch does not re-send it.
        XCTAssertTrue(store.installReported)

        let sent = await transport.payloads()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].wireVersion, .legacy)
    }

    /// …and the same send against a migrated server DOES latch, so the test
    /// above is about the wire shape and not about the milestone never
    /// latching at all.
    func test_aCurrentShapeSendDoesLatch() async {
        let store = FunnelStore()
        let subject = makeSubject(store: store, transport: FunnelTransport(accepts: .current))

        let recorded = await subject.recordHelperConnectedIfNeeded()

        XCTAssertTrue(recorded)
        XCTAssertTrue(store.helperConnectedReported)
    }

    /// Cost has the same shape-dependence, and is a separate latch.
    func test_costAlsoWaitsForAServerThatCanStoreIt() async {
        let store = FunnelStore()
        let subject = makeSubject(store: store, transport: FunnelTransport(accepts: .legacy))

        let recorded = await subject.recordFirstCostIfNeeded()

        XCTAssertFalse(recorded)
        XCTAssertFalse(store.costReported)
    }

    /// Activation IS carried by the v0.73 shape, so a legacy fallback still
    /// settles it — the fix must not over-correct into never latching.
    func test_activationStillLatchesOnALegacyFallback() async {
        let store = FunnelStore()
        let subject = makeSubject(store: store, transport: FunnelTransport(accepts: .legacy))

        let recorded = await subject.recordFirstProviderDetectedIfNeeded()

        XCTAssertTrue(recorded, "p_provider_detected exists in the legacy shape")
        XCTAssertTrue(store.activationReported)
    }

    // MARK: - UI language

    func test_theResolvedLanguageIsSent() async {
        let store = FunnelStore()
        let transport = FunnelTransport()
        await makeSubject(store: store, transport: transport, language: .zhHant)
            .recordInstallIfNeeded()
        let sent = await transport.payloads()
        XCTAssertEqual(sent[0].uiLanguage, .zhHant)
    }

    /// The set is closed because `migrate_v0.76` rejects anything outside it
    /// rather than storing it. A raw value that drifts from the SQL list makes
    /// the client silently unable to report at all.
    func test_theLanguageSetMatchesWhatTheMigrationAccepts() {
        XCTAssertEqual(
            Set(ReportedUILanguage.allCases.map(\.rawValue)),
            ["en", "es", "ja", "ko", "zh-Hans", "zh-Hant", "other"]
        )
    }

    /// Every catalogue the app ships must map to a case; an unshipped locale
    /// falls to `.other` because those users read English and the funnel needs
    /// to know they did.
    func test_everyShippedCatalogueHasACase() {
        for name in LocaleOverrideStore.shippedLocalizations {
            XCTAssertNotNil(ReportedUILanguage(rawValue: name), "\(name) has no case")
        }
        XCTAssertNil(ReportedUILanguage(rawValue: "fr"))
    }

    @MainActor
    func test_resolvedLocalizationFollowsTheOverride() {
        let saved = LocaleOverrideStore.shared.override
        defer { LocaleOverrideStore.shared.set(saved) }

        LocaleOverrideStore.shared.set("zh-Hans")
        XCTAssertEqual(LocaleOverrideStore.resolvedLocalization, "zh-Hans")
        XCTAssertEqual(ReportedUILanguage.current(), .zhHans)

        LocaleOverrideStore.shared.set("ko")
        XCTAssertEqual(ReportedUILanguage.current(), .ko)

        // An override that resolves to nothing must not be reported verbatim —
        // the server rejects it and the whole event is lost.
        LocaleOverrideStore.shared.set("fr")
        XCTAssertNotEqual(LocaleOverrideStore.resolvedLocalization, "fr")
    }

    // MARK: - Wire shaping

    /// PostgREST binds by the names present in the body, so ONE stray key is
    /// the difference between the pre-migration fallback working and 404-ing
    /// a second time.
    func test_legacyShapeOmitsExactlyTheV076Keys() throws {
        let payload = AnonymousInstallPayload(
            installID: UUID(), channel: .brew, appVersion: "1.53.0", osVersion: "15.2",
            providerDetected: true, helperConnected: true, costShown: true, uiLanguage: .ja
        )

        let current = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(payload)) as? [String: Any]
        let legacy = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(payload.legacyShaped())) as? [String: Any]

        XCTAssertEqual(Set((current ?? [:]).keys), [
            "p_install_id", "p_channel", "p_app_version", "p_os_version",
            "p_provider_detected", "p_helper_connected", "p_cost_shown", "p_ui_language",
            // v0.80 latches — see `migrate_v0.80_remote_control_usage_latches.sql`.
            "p_remote_lan", "p_remote_tailnet", "p_remote_delegate", "p_remote_nonclaude",
        ])
        XCTAssertEqual(Set((legacy ?? [:]).keys), [
            "p_install_id", "p_channel", "p_app_version", "p_os_version", "p_provider_detected",
        ])
        for key in AnonymousInstallPayload.v076OnlyKeys {
            XCTAssertNil(legacy?[key.rawValue], "\(key.rawValue) leaked into the legacy shape")
        }
    }

    /// The legacy shape must still carry the facts the old contract has room
    /// for — dropping to it is a narrowing, not a reset.
    func test_legacyShapeKeepsTheFieldsTheOldContractHas() {
        let id = UUID()
        let legacy = AnonymousInstallPayload(
            installID: id, channel: .mas, appVersion: "1.53.0", osVersion: "15.2",
            providerDetected: true, helperConnected: true, costShown: true, uiLanguage: .ja
        ).legacyShaped()

        XCTAssertEqual(legacy.installID, id)
        XCTAssertEqual(legacy.channel, .mas)
        XCTAssertTrue(legacy.providerDetected)
        XCTAssertEqual(legacy.wireVersion, .legacy)
        // Retained in the value, merely not encoded — so a caller can inspect
        // what was dropped, and the next launch re-sends it once v0.76 lands.
        XCTAssertTrue(legacy.helperConnected)
    }

    // MARK: - The helper-connected predicate

    /// `.registered` from HelperLifecycleManager would have been the easy
    /// signal and the wrong one: it means launchd accepted the plist, which is
    /// true in every failure mode this milestone exists to separate. Only
    /// `.running` / `.bundled` follow an answered `hello` over the socket.
    ///
    /// macOS-only, like `HelperInstaller` itself — there is no local helper on
    /// iOS or watchOS.
    #if os(macOS)
    @MainActor
    func test_onlyAnAnsweredHandshakeCountsAsConnected() {
        XCTAssertTrue(AnonymousTelemetryCoordinator.isHelperConnected(.running(version: "1.30.0")))
        XCTAssertTrue(AnonymousTelemetryCoordinator.isHelperConnected(.bundled(version: "1.53.0")))

        for state: HelperInstaller.State in [
            .checking, .notInstalled, .unreachable("socket missing"),
            .downloading(progress: 0.5), .installing,
            .updateAvailable(installed: "1.29.0", latest: "1.30.0"), .error("boom"),
        ] {
            XCTAssertFalse(AnonymousTelemetryCoordinator.isHelperConnected(state),
                           "\(state) is not an answered handshake")
        }
    }
    #endif
}

/// The transport's one retry, and the drift guard that keeps the client's
/// closed language set equal to the one `migrate_v0.76` accepts.
private final class SequencedProtocol: URLProtocol {
    /// Status per attempt, consumed in order; the last one repeats.
    nonisolated(unsafe) static var statuses: [Int] = []
    nonisolated(unsafe) static var bodies: [Data] = []
    /// Whether a 404 carries PostgREST's `PGRST202`. `false` simulates the
    /// other 404 — a mistyped project URL — which must NOT downgrade.
    nonisolated(unsafe) static var serveUnknownFunctionBody = true

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let size = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buffer.deallocate(); stream.close() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: size)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            body = data
        }
        Self.bodies.append(body ?? Data())

        let status = Self.statuses.count > 1 ? Self.statuses.removeFirst() : (Self.statuses.first ?? 204)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // A real PostgREST "no function with those parameter names" is a 404
        // whose BODY carries `PGRST202`. The transport keys off that code, not
        // off the status, so the stub has to serve it.
        if status == 404 && Self.serveUnknownFunctionBody {
            client?.urlProtocol(self, didLoad: Data(#"{"code":"PGRST202","message":"no function"}"#.utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class ActivationFunnelTransportTests: XCTestCase {

    private func makeTransport() -> SupabaseAnonymousTelemetryTransport {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SequencedProtocol.self]
        return SupabaseAnonymousTelemetryTransport(
            configuration: RuntimeCloudConfiguration(url: "https://example.invalid", anonKey: "k"),
            session: URLSession(configuration: config)
        )
    }

    private let payload = AnonymousInstallPayload(
        installID: UUID(uuidString: "12345678-1234-1234-1234-123456789012")!,
        channel: .devid, appVersion: "1.53.0", osVersion: "15.2",
        providerDetected: true, helperConnected: true, costShown: true, uiLanguage: .ko
    )

    override func setUp() {
        super.setUp()
        SequencedProtocol.statuses = [204]
        SequencedProtocol.bodies = []
        SequencedProtocol.serveUnknownFunctionBody = true
    }

    /// A database that has v0.76 but NOT v0.80 — the state every install is
    /// in until the owner applies the new migration — answers 404/PGRST202
    /// for the newest parameter set. The degrade is a ladder, so this must
    /// land on the v0.76 rung and keep reporting everything that rung can
    /// carry, rather than dropping all the way to legacy.
    func test_aPGRST202FallsBackOneRungToV076() async throws {
        SequencedProtocol.statuses = [404, 204]

        let accepted = try await makeTransport().send(payload)

        XCTAssertEqual(accepted, .v076,
                       "the caller must be told the v0.80 latches never landed — but v0.76's fields did")
        XCTAssertEqual(SequencedProtocol.bodies.count, 2, "one rung down, not a loop")
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: SequencedProtocol.bodies[0]) as? [String: Any])
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: SequencedProtocol.bodies[1]) as? [String: Any])
        XCTAssertNotNil(first["p_remote_lan"], "the first attempt must use the current contract")
        XCTAssertNil(second["p_remote_lan"], "the retry must drop every v0.80 key")
        XCTAssertNil(second["p_remote_tailnet"])
        XCTAssertNil(second["p_remote_delegate"])
        XCTAssertNil(second["p_remote_nonclaude"])
        XCTAssertNotNil(second["p_ui_language"], "…and must KEEP the v0.76 fields, which that database does know")
        XCTAssertEqual(second["p_install_id"] as? String, "12345678-1234-1234-1234-123456789012")
    }

    /// A database with NEITHER migration refuses twice, and the ladder walks
    /// all the way down rather than giving up after one rung. Two retries is
    /// the bound; a third refusal is a real error.
    func test_twoRefusalsWalkTheLadderToLegacy() async throws {
        SequencedProtocol.statuses = [404, 404, 204]

        let accepted = try await makeTransport().send(payload)

        XCTAssertEqual(accepted, .legacy)
        XCTAssertEqual(SequencedProtocol.bodies.count, 3, "two rungs down, then stop")
        let last = try XCTUnwrap(JSONSerialization.jsonObject(with: SequencedProtocol.bodies[2]) as? [String: Any])
        for k in ["p_remote_lan", "p_ui_language", "p_helper_connected", "p_cost_shown"] {
            XCTAssertNil(last[k], "the bottom rung must carry only v0.73's five parameters — \(k) leaked")
        }
        XCTAssertEqual(last.count, 5)
    }

    /// A 404 that is NOT `PGRST202` — a mistyped project URL, say — must
    /// propagate. Downgrading on it would silently reduce fidelity for a
    /// configuration bug instead of surfacing it. (Codex review, 2026-08-30:
    /// the first cut retried every 404.)
    func test_aPlain404DoesNotDowngrade() async {
        SequencedProtocol.statuses = [404, 204]
        SequencedProtocol.serveUnknownFunctionBody = false
        do {
            _ = try await makeTransport().send(payload)
            XCTFail("a 404 without PGRST202 must not be treated as a signature mismatch")
        } catch {
            XCTAssertEqual(SequencedProtocol.bodies.count, 1, "no retry on a plain 404")
        }
    }

    /// The retry is for an unknown-parameter 404 only. Anything else must
    /// propagate, or a broken key or a server outage would be silently
    /// downgraded into a lower-fidelity send that looks like success.
    func test_otherFailuresAreNotRetried() async {
        SequencedProtocol.statuses = [401, 204]
        do {
            try await makeTransport().send(payload)
            XCTFail("a 401 must not be swallowed")
        } catch {
            XCTAssertEqual(SequencedProtocol.bodies.count, 1, "no retry on a non-404")
        }
    }

    /// A payload already in `.legacy` shape must not retry — that would be an
    /// infinite regress dressed up as robustness.
    func test_aLegacyPayloadDoesNotRetry() async {
        SequencedProtocol.statuses = [404, 204]
        do {
            _ = try await makeTransport().send(payload.legacyShaped())
            XCTFail("a 404 on the legacy shape has no lower gear to drop into")
        } catch {
            XCTAssertEqual(SequencedProtocol.bodies.count, 1)
        }
    }

    /// DRIFT GUARD, and the only one covering these parameter names.
    ///
    /// `ci_check_rpc_contract.py` reports "no client currently calls
    /// record_anonymous_install" — measured, not assumed. Its Apple pattern
    /// wants a literal `/rest/v1/rpc/<name>` URL followed by a literal
    /// parameter block, and this call site has neither: the URL is built by
    /// interpolation in `SupabaseAnonymousTelemetryTransport` and the
    /// parameters come from an `Encodable`'s `CodingKeys`. So the repo-wide
    /// contract guard gives this RPC zero coverage, and PostgREST binds by
    /// name: one key that does not match a parameter is a 404, on the only
    /// write path anonymous users have.
    func test_theWireKeysMatchTheMigrationsParameterNames() throws {
        // The wire contract now spans TWO migrations: v0.76 declared eight
        // parameters, v0.80 re-declares them plus the four remote-control
        // latches. The NEWEST declaration is the one a current-shape call is
        // bound against, so that is the one to compare with.
        let sql = try String(contentsOf: Self.latestMigrationURL, encoding: .utf8)

        let marker = "create or replace function public.record_anonymous_install("
        let start = try XCTUnwrap(sql.range(of: marker), "the migration's function signature moved")
        let tail = sql[start.upperBound...]
        let block = try XCTUnwrap(tail.firstIndex(of: ")").map { String(tail[..<$0]) })

        let declared = Set(block.split(separator: "\n").compactMap { line -> String? in
            guard let token = line.trimmingCharacters(in: .whitespaces)
                .split(separator: " ").first.map(String.init),
                  token.hasPrefix("p_") else { return nil }
            return token
        })
        XCTAssertEqual(declared.count, 12, "parsed \(declared) — the parser is broken, not the SQL")

        let wire = Set(AnonymousInstallPayload.CodingKeys.allCases.map(\.rawValue))
        XCTAssertEqual(wire, declared,
                       "the payload's wire keys have drifted from the migration's parameter names")
    }

    /// DRIFT GUARD. The client coarsens to a closed set and `migrate_v0.76`
    /// REJECTS anything outside it — so a client that drifts does not degrade,
    /// it goes silent, which is the failure this whole feature exists to end.
    /// Same reasoning as the version-pattern drift test for v0.73.
    static let migrationURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CLIPulseCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // CLIPulseCore
        .deletingLastPathComponent()   // CLI Pulse Bar
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("backend/supabase/migrate_v0.76_activation_funnel.sql")

    /// The migration that declares the CURRENT wire contract. When a future
    /// migration adds parameters again, point this at it and the drift guard
    /// keeps working.
    static let latestMigrationURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("backend/supabase/migrate_v0.80_remote_control_usage_latches.sql")

    func test_theLanguageSetMatchesTheMigrationFile() throws {
        let sql = try String(contentsOf: Self.migrationURL, encoding: .utf8)

        let marker = "if v_language not in ("
        let start = try XCTUnwrap(sql.range(of: marker), "the migration's language check moved")
        let tail = sql[start.upperBound...]
        let list = try XCTUnwrap(tail.firstIndex(of: ")").map { String(tail[..<$0]) })

        let accepted = Set(
            list.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
        )
        XCTAssertEqual(accepted, Set(ReportedUILanguage.allCases.map(\.rawValue)),
                       "the client's language set has drifted from what the migration accepts")
    }
}

/// The telemetry disclosure is the consent basis for a switch that defaults ON.
/// Until v1.52.1 it was hardcoded English in two SwiftUI views, so a Spanish,
/// Korean or Japanese user was shown an English explanation of what the app
/// sends and then opted in by default. The app ships six catalogues; the one
/// screen that has to be understood was the one that ignored them.
final class TelemetryDisclosureLocalizationTests: XCTestCase {

    private static let shipped = ["en", "es", "ja", "ko", "zh-Hans", "zh-Hant"]

    private var saved: String?
    override func setUp() { super.setUp(); saved = LocaleOverrideStore.shared.override }
    override func tearDown() { LocaleOverrideStore.shared.set(saved); super.tearDown() }

    /// Every locale renders real copy — not the raw key, not English, not empty.
    func test_theDisclosureIsTranslatedInEveryShippedLocale() {
        var english: [String: String] = [:]
        LocaleOverrideStore.shared.set("en")
        english["body"] = L10n.telemetry.disclosureBody
        english["settings"] = L10n.telemetry.settingsBody
        english["notCollected"] = L10n.telemetry.notCollected

        for locale in Self.shipped {
            LocaleOverrideStore.shared.set(locale)
            let strings = [
                "title": L10n.telemetry.disclosureTitle,
                "body": L10n.telemetry.disclosureBody,
                "bodyLocalOnly": L10n.telemetry.disclosureBodyLocalOnly,
                "notCollected": L10n.telemetry.notCollected,
                "toggle": L10n.telemetry.toggle,
                "toggleLocalOnly": L10n.telemetry.toggleLocalOnly,
                "gotIt": L10n.telemetry.gotIt,
                "changeLater": L10n.telemetry.changeLater,
                "settings": L10n.telemetry.settingsBody,
            ]
            for (name, value) in strings {
                XCTAssertFalse(value.isEmpty, "\(locale).\(name) is empty")
                XCTAssertFalse(value.hasPrefix("telemetry."),
                               "\(locale).\(name) renders the raw key: \(value)")
            }
            guard locale != "en" else { continue }
            // The whole point: a non-English user must not be reading English.
            // Falling back would be the pre-v1.52.1 defect wearing the
            // fallback's clothes.
            for name in ["body", "settings", "notCollected"] {
                XCTAssertNotEqual(strings[name], english[name],
                                  "\(locale).\(name) is still the English string")
            }
        }
    }

    /// The consent text must name the milestones the payload actually carries.
    /// `check_telemetry_disclosure_claims.py` enforces this for English against
    /// the registry; this pins the two newest fields in the CJK catalogues,
    /// where a translator working from the older copy would silently drop them.
    func test_everyTranslationNamesTheNewMilestones() {
        let helperWord = ["es": "helper", "ja": "ヘルパー", "ko": "헬퍼",
                          "zh-Hans": "helper", "zh-Hant": "helper"]
        let costWord = ["es": "coste", "ja": "コスト", "ko": "비용",
                        "zh-Hans": "费用", "zh-Hant": "費用"]

        for (locale, needle) in helperWord {
            LocaleOverrideStore.shared.set(locale)
            XCTAssertTrue(L10n.telemetry.disclosureBody.contains(needle),
                          "\(locale) disclosure does not mention the helper milestone")
        }
        for (locale, needle) in costWord {
            LocaleOverrideStore.shared.set(locale)
            XCTAssertTrue(L10n.telemetry.disclosureBody.contains(needle),
                          "\(locale) disclosure does not mention the cost milestone")
        }
    }
}
