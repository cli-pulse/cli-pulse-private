import Foundation

/// The URL session for every request that carries a credential: an
/// `Authorization`, `Cookie` or API-key header, or a token in the body or the
/// URL. It keeps nothing: no URL cache, no cookie jar, no credential store.
///
/// Why not `URLSession.shared`, or a session made from
/// `URLSessionConfiguration.default`: both write every cacheable exchange to
/// the app's `Cache.db` (`~/Library/Caches/<bundle id>/`, or the container's
/// Caches on the App Store build): the request with its headers and body, and
/// the response body. A request's cache policy only governs whether a cached
/// answer is *read*; it never stops one being stored, and neither do POSTs
/// or a server that sends no `Cache-Control`. Up to 1.56 that Cache.db held,
/// on a real Mac (read by header and field names only): the Codex
/// `/wham/usage` and Claude OAuth usage requests with their bearer tokens (in
/// the app's and in the LoginItem helper's), Gemini's and Vertex AI's with
/// theirs, the account's Supabase requests with its access token, and the
/// sign-in POSTs to `/auth/v1/token` with the password or refresh token in
/// their body and the new tokens in their answer.
///
/// No cookie jar either. The collectors that sign in with a browser cookie set
/// it on the request as a `Cookie` header, which this session sends as it is;
/// none relies on a cookie the server set on an earlier answer. With a jar,
/// each `Set-Cookie` a provider answers with would be written to the app's
/// cookie file.
///
/// `CredentialedRequestsNoStoreTests` keeps every caller that sends a
/// credential on this session (or, for `APIClient`, on its configuration).
public enum CredentialedURLSession {

    /// The configuration `shared` is made from. `APIClient` makes its own
    /// session from it, because it needs its own timeouts and waits for
    /// connectivity; nothing else should need to.
    public static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return configuration
    }

    /// The one session for credentialed requests.
    public static let shared: URLSession = {
        let configuration = makeConfiguration()
        let interceptors = state.withLock { state -> [AnyClass] in
            state.sharedWasMade = true
            return state.interceptors
        }
        if !interceptors.isEmpty {
            configuration.protocolClasses = interceptors + (configuration.protocolClasses ?? [])
        }
        return URLSession(configuration: configuration)
    }()

    // MARK: - The QA renderer's refuser

    private struct State {
        var interceptors: [AnyClass] = []
        var sharedWasMade = false
    }

    private static let state = LockedState(State())

    /// Hands the QA renderer's request refuser to `shared`.
    /// `URLProtocol.registerClass` reaches `URLSession.shared` only, never a
    /// session made from its own configuration, so without this the requests
    /// the collectors make here would pass the renderer's refuser by. Only the
    /// renderer calls it, before anything has used `shared`; false when that
    /// is too late.
    @discardableResult
    public static func installInterceptor(_ protocolClass: AnyClass) -> Bool {
        state.withLock { state in
            guard !state.sharedWasMade else { return false }
            state.interceptors.append(protocolClass)
            return true
        }
    }

    // MARK: - What earlier versions left on disk

    /// This process's own defaults record that the purge ran, as a version
    /// number, so a later release can ask for another. Deliberately not under
    /// an app-owned prefix (`UnsandboxedDataMigration.appOwnedKeyPrefixes`):
    /// the move from the App Store build to the Developer ID one must not
    /// carry it over, because the two keep their caches in different places
    /// and each must empty its own; and the first-run check ignores it.
    public static let purgeDoneKey = "CLIPulse.credentialedCachePurge"
    static let purgeVersion = 1

    /// Removes, once per install of a version with this session, what earlier
    /// versions left in this process's URL cache and cookie jar.
    ///
    /// All of it, not the credentialed entries alone: `URLCache` cannot list
    /// its entries or remove them by host, and removing one needs the request
    /// it was stored for (headers and body included), which only the run
    /// that sent it had. Everything else in there is a copy of something public
    /// (release manifests and downloads, exchange rates), fetched again when
    /// next needed; nothing in the app reads a warm cache. Measured with a
    /// throwaway cache: after `removeAllCachedResponses()` neither a header
    /// value, a request body nor a response body is left in `Cache.db`, its
    /// `-wal` or `fsCachedData`, also when an earlier process had stored them.
    ///
    /// The cookie jar: from now on only the unauthenticated fetches use the
    /// shared session, so nothing reads it; what it holds came from provider
    /// APIs' answers to credentialed requests (on a real Mac: OpenAI's
    /// sign-in host and chatgpt.com).
    ///
    /// Returns whether it purged.
    @discardableResult
    public static func purgeLegacyStorageIfNeeded(
        defaults: UserDefaults = .standard,
        cache: URLCache = .shared,
        cookies: HTTPCookieStorage = .shared
    ) -> Bool {
        guard defaults.integer(forKey: purgeDoneKey) < purgeVersion else { return false }
        cache.removeAllCachedResponses()
        cookies.removeCookies(since: .distantPast)
        defaults.set(purgeVersion, forKey: purgeDoneKey)
        return true
    }
}

/// A value behind a lock, for the two statics above.
private final class LockedState<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
