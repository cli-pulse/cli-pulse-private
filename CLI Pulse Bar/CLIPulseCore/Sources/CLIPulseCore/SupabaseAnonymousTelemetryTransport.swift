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
    public enum TransportError: Error, Equatable {
        case notConfigured
        case rejected(status: Int)
        /// PostgREST could not find a function matching the parameter names in
        /// the body — `PGRST202`, served as HTTP 404.
        ///
        /// Distinguished from a plain 404 on purpose. A mistyped project URL
        /// is also a 404, and downgrading to the legacy shape on that would
        /// silently reduce fidelity for a configuration bug rather than
        /// surfacing it. Only the code PostgREST uses for "no such function"
        /// justifies the retry.
        case unknownFunctionSignature
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

    /// Sends, and retries ONCE in the pre-v0.76 shape if the server does not
    /// know the new parameters.
    ///
    /// `migrate_v0.76` is owner-gated and deploys independently of the app, so
    /// a build carrying the new fields can meet a database that has not had it
    /// applied. PostgREST answers an unrecognised parameter set with 404 and
    /// `PGRST202`; without this retry every install would go silent until
    /// someone applied the migration — and silent here is indistinguishable
    /// from "nobody installed the app", which is the exact confusion this
    /// telemetry exists to end.
    ///
    /// One retry, not a loop, and only from `.current` to `.legacy`. The
    /// milestone latches are set from the RESULT, so a legacy send simply
    /// leaves the new milestones unreported and the next launch tries again.
    @discardableResult
    public func send(_ payload: AnonymousInstallPayload) async throws -> AnonymousInstallPayload.WireVersion {
        do {
            try await post(payload)
            return payload.wireVersion
        } catch TransportError.unknownFunctionSignature where payload.wireVersion == .current {
            try await post(payload.legacyShaped())
            // The caller MUST see which shape landed. A legacy send omits
            // `p_helper_connected`, `p_cost_shown` and `p_ui_language`
            // entirely, so a caller that treated this as a full success would
            // latch milestones the server never received — and the latch is
            // persisted, so the next launch would return early and the
            // milestone would be lost for the life of the install.
            return .legacy
        }
    }

    private func post(_ payload: AnonymousInstallPayload) async throws {
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

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TransportError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 404, Self.isUnknownFunctionSignature(data) {
                throw TransportError.unknownFunctionSignature
            }
            throw TransportError.rejected(status: http.statusCode)
        }
    }
}

extension SupabaseAnonymousTelemetryTransport {
    /// `{"code":"PGRST202", ...}` — PostgREST's "could not find the function
    /// with those parameter names". Parsed rather than assumed from the 404,
    /// so a wrong URL stays a wrong URL instead of becoming a silent
    /// downgrade.
    static func isUnknownFunctionSignature(_ body: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let code = json["code"] as? String else { return false }
        return code == "PGRST202"
    }
}

extension SupabaseAnonymousTelemetryTransport.TransportError {
    static var invalidResponse: SupabaseAnonymousTelemetryTransport.TransportError {
        .rejected(status: -1)
    }
}
