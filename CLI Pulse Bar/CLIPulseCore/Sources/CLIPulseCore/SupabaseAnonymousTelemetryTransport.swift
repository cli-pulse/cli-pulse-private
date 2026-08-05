import Foundation

/// Posts the anonymous install row, and nothing else.
///
/// WHY THIS IS NOT A METHOD ON `APIClient`
/// ---------------------------------------
/// `APIClient` attaches the signed-in user's JWT to every request. Reusing it
/// here would stamp each "anonymous" row with an account server-side — the row
/// would still contain no user column, and the association would exist anyway,
/// in the request. The feature would then be anonymous in the schema and not in
/// fact, which is worse than not shipping it, because the privacy claim in the
/// disclosure and in the App Store nutrition label would be untrue.
///
/// So this type holds no token, has no way to obtain one, and sends the anon
/// key only. `AnonymousTelemetryTransportTests` asserts there is no
/// Authorization header carrying anything else.
public struct SupabaseAnonymousTelemetryTransport: AnonymousTelemetryTransport {
    public enum TransportError: Error {
        case notConfigured
        case rejected(status: Int)
    }

    private let endpoint: URL?
    private let anonKey: String
    private let session: URLSession

    /// Resolved through the same `RuntimeCloudConfiguration` path as everything
    /// else, so a QA or quarantine build points at the invalid local URL and
    /// cannot reach production. A telemetry sender that bypassed that gate
    /// would quietly poison the very numbers it exists to produce — and the QA
    /// runtime landed only two days ago, so this is a live hazard, not a
    /// theoretical one.
    init(configuration: RuntimeCloudConfiguration, session: URLSession = .shared) {
        self.endpoint = URL(string: "\(configuration.url)/rest/v1/rpc/record_anonymous_install")
        self.anonKey = configuration.anonKey
        self.session = session
    }

    public init(runtimeEnvironment: CLIPulseRuntimeEnvironment) {
        self.init(
            configuration: RuntimeCloudConfiguration.resolve(
                runtimeEnvironment: runtimeEnvironment,
                explicitURL: nil,
                explicitAnonKey: nil,
                infoDictionary: Bundle.main.infoDictionary ?? [:],
                environment: ProcessInfo.processInfo.environment
            )
        )
    }

    public func send(_ payload: AnonymousInstallPayload) async throws {
        guard let endpoint, !anonKey.isEmpty else { throw TransportError.notConfigured }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The anon key, and only the anon key. No user JWT is available to this
        // type by construction.
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        // The RPC returns void; asking for no body back keeps the response
        // empty rather than a JSON null we would have to parse.
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONEncoder().encode(payload)
        // Short. This runs at launch and must never be something a user can
        // perceive, so a slow network drops the event rather than the app
        // waiting on it.
        request.timeoutInterval = 10

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TransportError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw TransportError.rejected(status: http.statusCode)
        }
    }
}

extension SupabaseAnonymousTelemetryTransport.TransportError {
    static var invalidResponse: SupabaseAnonymousTelemetryTransport.TransportError {
        .rejected(status: -1)
    }
}
