import Foundation
import XCTest
@testable import CLIPulseCore

@MainActor
final class AppStateProviderAccountSyncTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var storageKey: String!

    override func setUp() {
        super.setUp()
        suiteName =
            "AppStateProviderAccountSyncTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        storageKey =
            "provider-account-deletion-outbox-\(UUID().uuidString)"
        AppStateProviderAccountStubProtocol.reset()
    }

    override func tearDown() {
        AppStateProviderAccountStubProtocol.reset()
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        storageKey = nil
        super.tearDown()
    }

    func testFailedDeleteSurvivesStateAndOutboxRecreationUntilRetrySucceeds()
        async throws
    {
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "11111111-1111-4111-8111-111111111111"
            )
        )
        AppStateProviderAccountStubProtocol.configure(
            responses: [
                .json(#"{"message":"transient"}"#, status: 500),
                .json(
                    #"{"accounts_deleted":1,"tombstones_persisted":1}"#
                ),
            ]
        )
        let api = await makeAuthenticatedAPI()
        let firstOutbox = makeOutbox()
        firstOutbox.enqueue(
            userID: "user-a",
            accountID: accountID,
            provider: .claude
        )
        let firstState = makeState(
            api: api,
            outbox: firstOutbox,
            userID: "user-a"
        )

        await firstState.flushPendingProviderAccountDeletions(
            for: "user-a"
        )

        XCTAssertEqual(
            firstOutbox.pendingAccountIDs(for: "user-a"),
            [accountID],
            "a failed server acknowledgement must retain the tombstone"
        )
        XCTAssertEqual(
            AppStateProviderAccountStubProtocol.recordedRequests()
                .count,
            1
        )

        let restoredOutbox = makeOutbox()
        let restoredState = makeState(
            api: api,
            outbox: restoredOutbox,
            userID: "user-a"
        )

        await restoredState.flushPendingProviderAccountDeletions(
            for: "user-a"
        )

        XCTAssertTrue(
            restoredOutbox.pendingAccountIDs(for: "user-a")
                .isEmpty,
            "a later acknowledged retry must clear the durable tombstone"
        )
        XCTAssertEqual(
            AppStateProviderAccountStubProtocol.recordedRequests()
                .count,
            2
        )
    }

    func testProviderlessLegacyIntentsDoNotStarveTypedDeletion()
        async throws
    {
        let typedAccountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "ffffffff-ffff-4fff-8fff-ffffffffffff"
            )
        )
        let providerless = try (1...10).map { index in
            ProviderAccountDeletionOutbox.Intent(
                userID: "user-a",
                accountID: try XCTUnwrap(
                    UUID(
                        uuidString: String(
                            format:
                                "00000000-0000-4000-8000-%012d",
                            index
                        )
                    )
                ),
                provider: nil
            )
        }
        let typed = ProviderAccountDeletionOutbox.Intent(
            userID: "user-a",
            accountID: typedAccountID,
            provider: .claude
        )
        defaults.set(
            try JSONEncoder().encode(providerless + [typed]),
            forKey: storageKey
        )
        AppStateProviderAccountStubProtocol.configure(
            responses: [
                .json(
                    #"{"accounts_deleted":1,"tombstones_persisted":1}"#
                ),
            ]
        )
        let outbox = makeOutbox()
        let state = makeState(
            api: await makeAuthenticatedAPI(),
            outbox: outbox,
            userID: "user-a"
        )

        await state.flushPendingProviderAccountDeletions(
            for: "user-a"
        )

        XCTAssertEqual(
            AppStateProviderAccountStubProtocol.recordedRequests()
                .count,
            1,
            "typed deletes must run even when ten old providerless records sort first"
        )
        XCTAssertFalse(
            outbox.pendingAccountIDs(for: "user-a")
                .contains(typedAccountID)
        )
        XCTAssertEqual(
            outbox.pendingAccountIDs(for: "user-a").count,
            10,
            "untyped development records stay quarantined for safe metadata recovery"
        )
    }

    func testAccountSwitchBeforeFlushDoesNotConsumePreviousOwnersDeletion()
        async throws
    {
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "22222222-2222-4222-8222-222222222222"
            )
        )
        AppStateProviderAccountStubProtocol.configure(
            responses: [
                .json(
                    #"{"accounts_deleted":1,"tombstones_persisted":1}"#
                ),
            ]
        )
        let api = await makeAuthenticatedAPI(
            userID: "user-b",
            accessToken: "user-b-access"
        )
        let outbox = makeOutbox()
        outbox.enqueue(
            userID: "user-a",
            accountID: accountID,
            provider: .claude
        )
        let state = makeState(
            api: api,
            outbox: outbox,
            userID: "user-b"
        )

        await state.flushPendingProviderAccountDeletions(
            for: "user-a"
        )

        XCTAssertTrue(
            AppStateProviderAccountStubProtocol.recordedRequests()
                .isEmpty
        )
        XCTAssertEqual(
            outbox.pendingAccountIDs(for: "user-a"),
            [accountID]
        )
    }

    func testAccountSwitchDuringRejectedDeleteDoesNotRetryWithNewSessionOrClearTombstone()
        async throws
    {
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "33333333-3333-4333-8333-333333333333"
            )
        )
        let requestStarted = expectation(
            description: "user A delete request started"
        )
        let responseGate = DispatchSemaphore(value: 0)
        AppStateProviderAccountStubProtocol.configure(
            responses: [
                .json(
                    #"{"message":"expired"}"#,
                    status: 401,
                    responseGate: responseGate
                ),
            ],
            onRequest: { _ in requestStarted.fulfill() }
        )
        let api = await makeAuthenticatedAPI()
        let outbox = makeOutbox()
        outbox.enqueue(
            userID: "user-a",
            accountID: accountID,
            provider: .claude
        )
        let state = makeState(
            api: api,
            outbox: outbox,
            userID: "user-a"
        )

        let flush = Task { @MainActor in
            await state.flushPendingProviderAccountDeletions(
                for: "user-a"
            )
        }
        await fulfillment(of: [requestStarted], timeout: 3)
        await switchSession(
            api: api,
            state: state,
            userID: "user-b",
            accessToken: "user-b-access"
        )
        responseGate.signal()
        await flush.value

        let requests =
            AppStateProviderAccountStubProtocol.recordedRequests()
        XCTAssertEqual(
            requests.count,
            1,
            "a stale delete must not retry with the new session"
        )
        XCTAssertEqual(
            requests.first?.value(
                forHTTPHeaderField: "Authorization"
            ),
            "Bearer user-a-access"
        )
        XCTAssertEqual(
            outbox.pendingAccountIDs(for: "user-a"),
            [accountID],
            "the old owner's tombstone must survive a stale rejection"
        )
        XCTAssertTrue(
            outbox.pendingAccountIDs(for: "user-b").isEmpty
        )
    }

    func testStatusSyncFiltersCurrentOwnerAndDoesNotRetryStaleLeaseWithNewSession()
        async throws
    {
        let userAAccountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "44444444-4444-4444-8444-444444444444"
            )
        )
        let userBAccountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "55555555-5555-4555-8555-555555555555"
            )
        )
        let requestStarted = expectation(
            description: "user A status request started"
        )
        let responseGate = DispatchSemaphore(value: 0)
        AppStateProviderAccountStubProtocol.configure(
            responses: [
                .json(
                    #"{"message":"expired"}"#,
                    status: 401,
                    responseGate: responseGate
                ),
            ],
            onRequest: { _ in requestStarted.fulfill() }
        )
        let api = await makeAuthenticatedAPI()
        let state = makeState(
            api: api,
            outbox: makeOutbox(),
            userID: "user-a"
        )
        state.providerConfigs = [
            ProviderConfig(
                kind: .claude,
                accountID: userAAccountID,
                isEnabled: false,
                syncOwnerUserID: "user-a"
            ),
            ProviderConfig(
                kind: .codex,
                accountID: userBAccountID,
                isEnabled: true,
                syncOwnerUserID: "user-b"
            ),
        ]

        let sync = Task { @MainActor in
            await state.syncCurrentProviderAccountStatuses()
        }
        await fulfillment(of: [requestStarted], timeout: 3)
        await switchSession(
            api: api,
            state: state,
            userID: "user-b",
            accessToken: "user-b-access"
        )
        responseGate.signal()
        await sync.value

        let requests =
            AppStateProviderAccountStubProtocol.recordedRequests()
        XCTAssertEqual(
            requests.count,
            1,
            "a stale status write must not retry with the new session"
        )
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer user-a-access"
        )
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body)
                as? [String: Any]
        )
        let rows = try XCTUnwrap(
            object["p_rows"] as? [[String: Any]]
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(
            rows.first?["account_id"] as? String,
            userAAccountID.uuidString.lowercased()
        )
        XCTAssertEqual(
            rows.first?["status"] as? String,
            "disabled"
        )
        XCTAssertFalse(
            String(decoding: body, as: UTF8.self)
                .contains(userBAccountID.uuidString.lowercased())
        )
    }

    private func makeOutbox()
        -> ProviderAccountDeletionOutbox
    {
        ProviderAccountDeletionOutbox(
            defaults: defaults,
            storageKey: storageKey
        )
    }

    private func makeState(
        api: APIClient,
        outbox: ProviderAccountDeletionOutbox,
        userID: String
    ) -> AppState {
        let state = AppState(
            api: api,
            providerAccountDeletionOutbox: outbox,
            performLaunchSetup: false
        )
        state.isAuthenticated = true
        state.userId = userID
        return state
    }

    private func makeAuthenticatedAPI(
        userID: String = "user-a",
        accessToken: String = "user-a-access"
    ) async -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            AppStateProviderAccountStubProtocol.self,
        ]
        let api = APIClient(
            supabaseURL: "https://app-state-provider.test",
            supabaseAnonKey: "anon",
            session: URLSession(configuration: configuration),
            providerAccountFlags: .init(
                readV2: true,
                writeV2: true
            )
        )
        let began = await api.beginExternalAuthorizationTransition(
            generation: 1
        )
        let installed =
            await api.installExternalAuthenticatedSession(
                accessToken: accessToken,
                refreshToken: "refresh-\(userID)",
                userID: userID,
                transitionGeneration: 1
            )
        XCTAssertTrue(began)
        XCTAssertTrue(installed)
        return api
    }

    private func switchSession(
        api: APIClient,
        state: AppState,
        userID: String,
        accessToken: String
    ) async {
        let began = await api.beginExternalAuthorizationTransition(
            generation: 2
        )
        let installed =
            await api.installExternalAuthenticatedSession(
                accessToken: accessToken,
                refreshToken: "refresh-\(userID)",
                userID: userID,
                transitionGeneration: 2
            )
        XCTAssertTrue(began)
        XCTAssertTrue(installed)
        state.userId = userID
        state.isAuthenticated = true
    }
}

private final class AppStateProviderAccountStubProtocol:
    URLProtocol
{
    struct StubResponse {
        let status: Int
        let body: Data
        let responseGate: DispatchSemaphore?

        static func json(
            _ text: String,
            status: Int = 200,
            responseGate: DispatchSemaphore? = nil
        ) -> StubResponse {
            StubResponse(
                status: status,
                body: Data(text.utf8),
                responseGate: responseGate
            )
        }
    }

    nonisolated(unsafe) private static var responses:
        [StubResponse] = []
    nonisolated(unsafe) private static var requests:
        [URLRequest] = []
    nonisolated(unsafe) private static var onRequest:
        (@Sendable (URLRequest) -> Void)?
    private static let lock = NSLock()

    static func configure(
        responses: [StubResponse],
        onRequest: (@Sendable (URLRequest) -> Void)? = nil
    ) {
        lock.lock()
        self.responses = responses
        self.requests = []
        self.onRequest = onRequest
        lock.unlock()
    }

    static func reset() {
        configure(responses: [])
    }

    static func recordedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(
        with request: URLRequest
    ) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        let recordedRequest =
            Self.requestWithMaterializedBody(request)
        let response: StubResponse?
        let observer: (@Sendable (URLRequest) -> Void)?
        Self.lock.lock()
        Self.requests.append(recordedRequest)
        response = Self.responses.isEmpty
            ? nil
            : Self.responses.removeFirst()
        observer = Self.onRequest
        Self.lock.unlock()

        observer?(recordedRequest)
        guard let response else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }
        response.responseGate?.wait()
        guard
            let url = request.url,
            let http = HTTPURLResponse(
                url: url,
                statusCode: response.status,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "application/json",
                ]
            )
        else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }
        client?.urlProtocol(
            self,
            didReceive: http,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func requestWithMaterializedBody(
        _ request: URLRequest
    ) -> URLRequest {
        guard
            request.httpBody == nil,
            let stream = request.httpBodyStream
        else {
            return request
        }

        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(
                &buffer,
                maxLength: buffer.count
            )
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        var copy = request
        copy.httpBodyStream = nil
        copy.httpBody = data
        return copy
    }
}
