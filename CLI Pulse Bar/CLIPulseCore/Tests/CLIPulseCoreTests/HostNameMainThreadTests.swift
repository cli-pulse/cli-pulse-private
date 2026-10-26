// 59-04 (1.59): the host name is never read on the main thread.
//
// Sentry APPLE-MACOS-4 (last seen on 1.56.0): the menu bar
// froze in `DataRefreshManager.refreshAll` → `ProcessInfo.hostName.getter` →
// `-[NSHost blockingResolveUntil:]`, a DNS wait on the main thread. Three
// checks keep it from coming back:
//
//   1. both refresh routes, given a host-name provider that takes 2 s and
//      records its thread, never call it on the main thread, and the main
//      thread answers within 100 ms while it runs;
//   2. a scan of every app target's source finds each host-name call and
//      holds it to an allowlist, each entry with its reason;
//   3. the allowlist's reason for `Host.current().localizedName` (it does not
//      resolve) is measured here, on whatever macOS runs the tests.
//
// macOS-gated: every call site is macOS-only.

#if os(macOS)
import Foundation
import ObjectiveC
import XCTest
@testable import CLIPulseCore

// MARK: - HostIdentity

final class HostIdentityTests: XCTestCase {

    func testTheFirstCallWaitsForTheNameAndLaterOnesUseIt() async {
        let probe = HostNameProbe(name: "mac-one.local", delay: 0.2)
        let identity = HostIdentity(provider: probe.provider)

        let first = await identity.hostName()
        let second = await identity.hostName()

        XCTAssertEqual(first, "mac-one.local", "the first caller must get the real name, never a placeholder")
        XCTAssertEqual(second, "mac-one.local")
        XCTAssertEqual(probe.threads.count, 1, "the name is cached")
    }

    func testCallersThatArriveTogetherShareOneRead() async {
        let probe = HostNameProbe(name: "mac-two.local", delay: 0.3)
        let identity = HostIdentity(provider: probe.provider)

        async let a = identity.hostName()
        async let b = identity.hostName()
        async let c = identity.hostName()
        let names = await [a, b, c]

        XCTAssertEqual(names, ["mac-two.local", "mac-two.local", "mac-two.local"])
        XCTAssertEqual(probe.threads.count, 1)
    }

    /// A name older than `maxAge` is still served at once, and read again in
    /// the background: the Mac's name can change while the app runs.
    func testAnOldNameIsServedWhileItIsReadAgain() async throws {
        let clock = TestClock()
        let probe = HostNameProbe(names: ["before.local", "after.local"], delay: 0)
        let identity = HostIdentity(provider: probe.provider, maxAge: 60, now: { clock.now })

        let first = await identity.hostName()
        XCTAssertEqual(first, "before.local")
        clock.advance(61)
        let stale = await identity.hostName()
        XCTAssertEqual(stale, "before.local", "an old name must not make the caller wait")

        let deadline = Date().addingTimeInterval(5)
        var renewed = stale
        while renewed != "after.local", Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
            renewed = await identity.hostName()
        }
        XCTAssertEqual(renewed, "after.local", "the background read never landed")
        XCTAssertEqual(probe.threads.count, 2)
    }

    @MainActor
    func testTheProviderNeverRunsOnTheMainThreadEvenWhenAskedFromIt() async {
        XCTAssertTrue(Thread.isMainThread)
        let probe = HostNameProbe(name: "mac.local", delay: 0)
        _ = await HostIdentity(provider: probe.provider).hostName()
        XCTAssertEqual(probe.threads, [false])
    }

    /// The live provider is exactly the old call: the value names this Mac's
    /// rows, and must not change.
    func testTheLiveProviderIsTheOldCall() async {
        let read = await HostIdentity().hostName()
        XCTAssertEqual(read, ProcessInfo.processInfo.hostName)
    }
}

// MARK: - Both refresh routes

@MainActor
final class RefreshHostNameThreadTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UploadOutcomeStubProtocol.reset()
    }

    override func tearDown() {
        UploadOutcomeStubProtocol.reset()
        super.tearDown()
    }

    func testTheLocalRouteReadsTheNameOffTheMainThread() async throws {
        let probe = HostNameProbe(name: "slow-mac.local", delay: 2)
        var payload: DataRefreshManager.RefreshPayload?
        let manager = await Self.manager(probe: probe)

        await manager.refreshAll(
            context: RefreshUploadOutcomeTests.context(isAuthenticated: true, isPaired: false),
            callbacks: Self.callbacks(applyPayload: { payload = $0 })
        )

        try Self.assertOffTheMainThread(probe)
        XCTAssertEqual(payload?.devices.first?.name, "slow-mac.local",
                       "the local device row must carry the provider's name, unchanged")
    }

    func testTheCloudRouteReadsTheNameOffTheMainThread() async throws {
        RefreshUploadOutcomeTests.answerCloudReads()
        let probe = HostNameProbe(name: "slow-mac.local", delay: 2)
        var applied = false
        let manager = await Self.manager(probe: probe)

        await manager.refreshAll(
            context: RefreshUploadOutcomeTests.context(isAuthenticated: true, isPaired: true),
            callbacks: Self.callbacks(applyPayload: { _ in applied = true })
        )

        XCTAssertTrue(applied, "the cloud refresh did not reach its payload")
        try Self.assertOffTheMainThread(probe)
    }

    /// The provider was asked once, never on the main thread, and a hop to
    /// the main queue made while it slept ran within 100 ms. Called on the
    /// main thread, the provider would hold that hop for its whole 2 s.
    static func assertOffTheMainThread(
        _ probe: HostNameProbe, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertEqual(probe.threads, [false],
                       "the host name was read on the main thread, or not through HostIdentity",
                       file: file, line: line)
        let hop = try XCTUnwrap(probe.mainHopLatencies.first,
                                "the main queue never answered while the name was read", file: file, line: line)
        XCTAssertLessThan(hop, 0.1, "the main thread was blocked for \(hop) s", file: file, line: line)
    }

    static func manager(probe: HostNameProbe) async -> DataRefreshManager {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UploadOutcomeStubProtocol.self]
        let api = APIClient(
            supabaseURL: "https://host-name.test",
            supabaseAnonKey: "anon",
            session: URLSession(configuration: config),
            providerAccountFlags: .init(readV2: false, writeV2: false)
        )
        _ = await api.beginExternalAuthorizationTransition(generation: 1)
        _ = await api.installExternalAuthenticatedSession(
            accessToken: "token-a", refreshToken: "refresh-a",
            userID: "user-a", transitionGeneration: 1)
        return DataRefreshManager(
            api: api,
            localRuntime: .outcomeTest(),
            hostIdentity: HostIdentity(provider: probe.provider),
            uploadOutcomes: UploadOutcomeTracker(
                reporter: RecordingUploadReporter(),
                defaults: UploadOutcomeTests.freshDefaults(),
                log: { _ in }
            )
        )
    }

    static func callbacks(
        applyPayload: @escaping (DataRefreshManager.RefreshPayload) -> Void
    ) -> DataRefreshManager.Callbacks {
        DataRefreshManager.Callbacks(
            isAuthenticated: { true },
            setLoading: { _ in },
            setLastError: { _ in },
            setServerOnline: { _ in },
            applyPayload: applyPayload,
            sendNotification: { _ in },
            afterRefresh: {},
            handleTokenExpired: { _ in },
            activeSuppressedAlertIDs: { [] },
            setNeedsFolderAccess: { _ in },
            setCollectorOutcomes: { _ in }
        )
    }
}

// MARK: - Every host-name call in the app targets

final class HostNameSourceScanTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CLIPulseCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // CLIPulseCore
        .deletingLastPathComponent()   // CLI Pulse Bar
        .deletingLastPathComponent()   // repository root

    /// Every Swift source an app, extension, login item or helper is built
    /// from. Tests and the two image-generating scripts are not shipped.
    private static let scannedRoots = [
        "CLI Pulse Bar/CLI Pulse Bar",
        "CLI Pulse Bar/CLI Pulse Bar iOS",
        "CLI Pulse Bar/CLI Pulse Bar Watch",
        "CLI Pulse Bar/CLI Pulse Widgets",
        "CLI Pulse Bar/CLIPulseHelper",
        "CLI Pulse Bar/CLIPulseCore/Sources",
        "HelperSwift/Sources",
        "MachineRootHelper/Sources",
        "SensorProbe/Sources",
    ]

    /// The calls that can wait on the resolver: `ProcessInfo.hostName` (or any
    /// `.hostName` property read), `Host.current()`, `Host(name:)` /
    /// `Host(address:)`, and anything spelled `NSHost` (not `NSHosting…`).
    /// `HostIdentity.hostName()` is a method call and is what to use instead.
    static let patterns: [NSRegularExpression] = [
        #"\.hostName\b(?!\s*\()"#,
        #"\bHost\.current\s*\("#,
        #"(?<![\w.])Host\s*\("#,
        #"\bNSHost\b"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    struct Allowed: Hashable {
        let file: String
        let code: String
    }

    /// Each remaining call, with why it may stay.
    static let allowlist: [Allowed: String] = [
        Allowed(file: "CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/HostIdentity.swift",
                code: "ProcessInfo.processInfo.hostName"):
            "The one reader. It runs on HostIdentity's own queue, never the main thread.",
        Allowed(file: "CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/LocalScanner.swift",
                code: "let hostName = ProcessInfo.processInfo.hostName"):
            "In LocalScanner.scan(): the app calls it in Task.detached (LocalRefreshRuntime.live.scanLocal); "
            + "the login item has no UI.",
        Allowed(file: "CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/AlertGenerator.swift",
                code: "deviceID: String = ProcessInfo.processInfo.hostName,"):
            "A default argument no production caller uses: HelperDaemon passes the device id.",
        Allowed(file: "CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/LANLinkAgent.swift",
                code: #"displayName: String = Host.current().localizedName ?? "Mac","#):
            "localizedName makes no resolving NSHost call: testLocalizedNameMakesNoResolvingCall.",
        Allowed(file: "CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/HelperConfig.swift",
                code: #"deviceName: json["device_name"] as? String ?? Host.current().localizedName ?? "Mac","#):
            "localizedName makes no resolving NSHost call: testLocalizedNameMakesNoResolvingCall.",
        Allowed(file: "CLI Pulse Bar/CLI Pulse Bar/PairingSection.swift",
                code: #"let deviceName = Host.current().localizedName ?? "Mac""#):
            "localizedName makes no resolving NSHost call: testLocalizedNameMakesNoResolvingCall.",
    ]

    /// The code lines in `source` that make one of the calls, comments
    /// removed and whitespace trimmed.
    ///
    /// Known gap: a line is cut at its first `//`, even inside a string
    /// literal, so a call after a URL on the same line
    /// (`let u = "https://…"; let h = ProcessInfo.processInfo.hostName`) is
    /// missed. No such line exists; keep calls on lines of their own.
    static func hostNameCalls(in source: String) -> [String] {
        source.split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw in
            var line = Substring(raw)
            if let comment = line.range(of: "//") { line = line[..<comment.lowerBound] }
            let code = line.trimmingCharacters(in: .whitespaces)
            guard !code.isEmpty else { return nil }
            let range = NSRange(code.startIndex..., in: code)
            return patterns.contains { $0.firstMatch(in: code, range: range) != nil } ? code : nil
        }
    }

    /// Every call not on the allowlist, and every allowlist entry that no
    /// longer matches a call (a stale entry would allow its next occupant).
    static func problems(found: [Allowed]) -> [String] {
        var problems: [String] = []
        for call in found where allowlist[call] == nil {
            problems.append("not allowed: \(call.file): \(call.code)")
        }
        for entry in allowlist.keys where !found.contains(entry) {
            problems.append("stale allowlist entry: \(entry.file): \(entry.code)")
        }
        return problems.sorted()
    }

    func testEveryHostNameCallIsOnTheAllowlist() throws {
        var found: [Allowed] = []
        var scannedFiles = 0
        for root in Self.scannedRoots {
            let base = Self.repoRoot.appendingPathComponent(root)
            guard let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else {
                XCTFail("cannot read \(root)")
                continue
            }
            for case let file as URL in files where file.pathExtension == "swift" {
                if file.path.contains("/.build/") { continue }
                scannedFiles += 1
                let source = try String(contentsOf: file, encoding: .utf8)
                let relative = String(file.path.dropFirst(Self.repoRoot.path.count + 1))
                found += Self.hostNameCalls(in: source).map { Allowed(file: relative, code: $0) }
            }
        }
        XCTAssertGreaterThan(scannedFiles, 300, "the scan did not reach the app sources")
        XCTAssertEqual(Self.problems(found: found), [],
                       "route the host name through HostIdentity, or add the call to the allowlist with its reason")
    }

    /// Negative control: the calls this exists for are found, comments are
    /// not, and the replacement API is not.
    func testTheScanFindsWhatItIsFor() {
        let source = """
        // ProcessInfo.processInfo.hostName in a comment is not a call
        let a = ProcessInfo.processInfo.hostName
        let b = Host.current().name
        let c = NSHost.current().localizedName
        let d = Host(name: "example.com").address
        let e = await hostIdentity.hostName()
        let f = NWEndpoint.Host("10.0.0.1")
        let g = NSHostingView(rootView: view)
        """
        XCTAssertEqual(Self.hostNameCalls(in: source), [
            "let a = ProcessInfo.processInfo.hostName",
            "let b = Host.current().name",
            "let c = NSHost.current().localizedName",
            #"let d = Host(name: "example.com").address"#,
        ])

        let added = Allowed(file: "CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/DataRefreshManager.swift",
                            code: "deviceName: ProcessInfo.processInfo.hostName,")
        let problems = Self.problems(found: Array(Self.allowlist.keys) + [added])
        XCTAssertEqual(problems, ["not allowed: \(added.file): \(added.code)"])

        let withoutOne = Array(Self.allowlist.keys.dropFirst())
        XCTAssertEqual(Self.problems(found: withoutOne).count, 1, "a stale entry was not reported")
    }

    // MARK: - The measured reason for localizedName

    /// `Host.current().localizedName` is the Sharing name. This counts the
    /// calls it makes to the four `NSHost` methods that resolve (`name`,
    /// `names`, `address`, `addresses`; `ProcessInfo.hostName` is `name`),
    /// on whatever macOS the tests run on, CI's included. The control,
    /// `Host.current().name`, must be counted, or the count proves nothing.
    /// The swizzle is process-wide, so only this test's own thread is
    /// counted: a call another thread makes meanwhile (a `HostIdentity`
    /// renewal, a scan in `Task.detached`) is not `localizedName`'s.
    func testLocalizedNameMakesNoResolvingCall() throws {
        let host: AnyClass = try XCTUnwrap(NSClassFromString("NSHost"))
        let counter = ResolveCounter(countingOnly: Thread.current)
        var restore: [(Method, IMP)] = []
        defer { for (method, original) in restore { method_setImplementation(method, original) } }

        for name in ["name", "names", "address", "addresses"] {
            let selector = NSSelectorFromString(name)
            guard let method = class_getInstanceMethod(host, selector) else { continue }
            let original = method_getImplementation(method)
            typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
            let forward = unsafeBitCast(original, to: Getter.self)
            // Unmanaged both ways: the object is handed through untouched, at
            // the retain count the original returns it with.
            let counting: @convention(block) (AnyObject) -> Unmanaged<AnyObject>? = { receiver in
                counter.record(name)
                return forward(receiver, selector)
            }
            method_setImplementation(method, imp_implementationWithBlock(counting))
            restore.append((method, original))
        }
        XCTAssertFalse(restore.isEmpty, "no resolving NSHost method found to count")

        let elsewhere = DispatchSemaphore(value: 0)
        Thread { counter.record("name"); elsewhere.signal() }.start()
        elsewhere.wait()
        XCTAssertEqual(counter.calls, [], "control: a call from another thread was counted")

        let localized = Host.current().localizedName
        XCTAssertEqual(counter.calls, [], "Host.current().localizedName resolved: \(counter.calls)")
        XCTAssertNotNil(localized)

        _ = Host.current().name
        XCTAssertTrue(counter.calls.contains("name"), "control: the counter did not see -[NSHost name]")
    }
}

// MARK: - Helpers

/// A host-name provider that records the thread it ran on, hops to the main
/// queue at once and records how long the hop took, then takes `delay`.
final class HostNameProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String]
    private let delay: TimeInterval
    private var storedThreads: [Bool] = []
    private var storedHops: [TimeInterval] = []

    init(name: String, delay: TimeInterval) {
        self.names = [name]
        self.delay = delay
    }

    init(names: [String], delay: TimeInterval) {
        self.names = names
        self.delay = delay
    }

    var threads: [Bool] { lock.lock(); defer { lock.unlock() }; return storedThreads }
    var mainHopLatencies: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return storedHops }

    var provider: HostIdentity.Provider {
        { [self] in
            let start = Date()
            lock.lock()
            storedThreads.append(Thread.isMainThread)
            let name = names.count > 1 ? names.removeFirst() : names[0]
            lock.unlock()
            DispatchQueue.main.async { [self] in
                let latency = Date().timeIntervalSince(start)
                lock.lock(); storedHops.append(latency); lock.unlock()
            }
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            return name
        }
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) { lock.lock(); current += seconds; lock.unlock() }
}

final class ResolveCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    private let thread: Thread
    init(countingOnly thread: Thread) { self.thread = thread }
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    /// Ignored unless it comes from the thread being counted.
    func record(_ name: String) {
        guard Thread.current === thread else { return }
        lock.lock(); stored.append(name); lock.unlock()
    }
}
#endif
