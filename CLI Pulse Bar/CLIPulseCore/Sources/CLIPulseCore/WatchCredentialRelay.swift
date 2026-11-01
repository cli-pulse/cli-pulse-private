import Foundation
import CryptoKit

// MARK: - 1.61 (B1): one refresher per session
//
// Supabase refresh tokens are single-use. Up to 1.60 the iPhone handed the
// Watch its access AND refresh token, and both then refreshed on their own
// with that one chain: whichever side refreshed second was refused (and, by
// Supabase's reuse detection, could take the whole session down with it).
//
// Now a session has exactly one refresher:
// - a session the Watch got from the iPhone is renewed by the iPhone. The
//   Watch never holds its refresh token; when its access token expires (or is
//   refused) it asks the iPhone for the current one, and the iPhone also sends
//   each access token its own refreshes produce;
// - a session the Watch signed in to on its own (a code sent by email) is its
//   own, and the Watch refreshes it as before.

/// Where the Watch's session came from, which decides who renews it. Kept in
/// the Watch's Keychain next to the token (`WatchSessionRecord`).
public enum WatchSessionSource: String, Sendable, Codable {
    /// Installed from the iPhone's sign-in. The iPhone owns the refresh token.
    case phone
    /// Signed in on the Watch with a code. The Watch owns the refresh token.
    case watch

    /// Whether the Watch refreshes this session with a refresh token of its own.
    public var renewsItself: Bool { self == .watch }
}

/// The Watch's record of its session, saved in its Keychain with the token:
/// who renews it, and whose it is, so a session from the iPhone can be shown
/// (from the last data the iPhone sent) while the iPhone cannot be reached,
/// instead of reading as signed out.
public struct WatchSessionRecord: Equatable, Sendable, Codable {
    public static let keychainKey = "cli_pulse_watch_session_record"

    public let source: WatchSessionSource
    public let userID: String
    public let name: String
    public let email: String

    public init(source: WatchSessionSource, userID: String, name: String = "", email: String = "") {
        self.source = source
        self.userID = userID
        self.name = name
        self.email = email
    }

    public var encoded: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The record a stored session has, as written by 1.61 and later.
    public static func stored(_ raw: String?) -> WatchSessionRecord? {
        guard
            let raw, !raw.isEmpty,
            let record = try? JSONDecoder().decode(WatchSessionRecord.self, from: Data(raw.utf8)),
            !record.userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return record
    }

    /// Who renews a stored session; `.watch` when nothing was recorded.
    public static func source(of record: WatchSessionRecord?) -> WatchSessionSource {
        record?.source ?? .watch
    }

    /// The record for the session stored at launch. A session stored before
    /// 1.61 has none written. It is the iPhone's when its token belongs to the
    /// account whose data the iPhone last sent this Watch (`lastPhoneUserID`,
    /// the owner of the snapshot the Watch kept): the iPhone's sign-in
    /// installs over any other session, and its sign-out ends any session of
    /// that account, so that session is the iPhone's to renew. Otherwise
    /// (no iPhone account, another one, a token whose account cannot be read)
    /// it is the Watch's own and refreshes itself, as before.
    public static func resolve(
        stored raw: String?,
        accessToken: String,
        lastPhoneUserID: String?
    ) -> WatchSessionRecord? {
        if let record = stored(raw) { return record }
        guard
            let phoneUser = lastPhoneUserID,
            let tokenUser = APIClient.jwtSubject(accessToken),
            WatchCredentialRelay.sameUser(phoneUser, tokenUser)
        else {
            return nil
        }
        return WatchSessionRecord(source: .phone, userID: tokenUser)
    }
}

/// The Watch's question to the iPhone and the iPhone's answer, as
/// WatchConnectivity dictionaries. The answer carries the access token only:
/// the iPhone's refresh token never goes to the Watch in it, so the Watch can
/// never spend it.
public enum WatchCredentialRelay {
    public static let requestKey = "cli_pulse_credentials_request"
    public static let answerKey = "cli_pulse_credentials"

    static let statusKey = "status"
    static let accessTokenKey = "access_token"
    static let userIDKey = "user_id"

    /// What the iPhone says.
    public enum Answer: Equatable, Sendable {
        /// Its current access token for this account.
        case accessToken(String, userID: String)
        /// It is signed out: no session, and none stored to restore.
        case signedOut
        /// No answer that can be acted on now: not reached, still restoring
        /// its session, a refresh that failed, another account, a malformed
        /// reply. The Watch keeps its session and asks again later.
        case unavailable
    }

    /// The iPhone's side, as it is when asked.
    public enum PhoneState: Equatable, Sendable {
        /// Signed in, with this access token.
        case signedIn(userID: String, accessToken: String)
        /// Not signed in, but a stored session is still being restored (a
        /// launch without network, a restore deferred until it can check).
        case restoring
        /// Not signed in and nothing stored. Demo mode with no stored session
        /// is this too.
        case signedOut
    }

    // MARK: Request

    /// `heldToken` (1.61): the access token the Watch holds now. Only its
    /// fingerprint goes into the request. An iPhone whose current token is
    /// that one knows the Watch has it already, most likely because the server
    /// refused it, and refreshes instead of handing it back
    /// (`phoneRenewal(…, watchHoldsIt:)`).
    public static func request(userID: String, heldToken: String? = nil) -> [String: Any] {
        var request: [String: Any] = [requestKey: true, userIDKey: userID]
        if let heldToken, !heldToken.isEmpty {
            request[heldTokenKey] = fingerprint(heldToken)
        }
        return request
    }

    static let heldTokenKey = "held_token_fingerprint"

    /// 1.61: the fingerprint of the token the Watch said it holds, if any.
    public static func heldTokenFingerprint(in message: [String: Any]) -> String? {
        guard message[requestKey] as? Bool == true else { return nil }
        return message[heldTokenKey] as? String
    }

    /// 1.61: a token's fingerprint, to tell whether two sides hold the same
    /// one without sending it back (the first 16 bytes of its SHA-256, hex).
    public static func fingerprint(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The account a request asks about, or nil when the message is not a
    /// request. An empty string when the request names none.
    public static func requestedUserID(in message: [String: Any]) -> String? {
        guard message[requestKey] as? Bool == true else { return nil }
        return (message[userIDKey] as? String) ?? ""
    }

    // MARK: The iPhone's answer

    /// What the iPhone answers a request about `requestedUserID` (empty: any).
    public static func answer(for state: PhoneState, requestedUserID: String) -> Answer {
        switch state {
        case let .signedIn(userID, accessToken):
            guard !accessToken.isEmpty, !userID.isEmpty, tokenBelongs(accessToken, to: userID) else {
                return .unavailable
            }
            if !requestedUserID.isEmpty, !sameUser(requestedUserID, userID) {
                // Another account. Its own sign-in already went to the Watch.
                return .unavailable
            }
            return .accessToken(accessToken, userID: userID)
        case .restoring:
            return .unavailable
        case .signedOut:
            return .signedOut
        }
    }

    /// What the iPhone does with its token before answering.
    public enum PhoneRenewal: Equatable, Sendable {
        /// Hand it over as it is.
        case sendAsIs
        /// Refresh first: it has expired, or will within the margin, so
        /// handing it over would only send the Watch straight back.
        case renewFirst
        /// No answer now: it has expired and a refresh could not be saved.
        case noAnswer
    }

    /// `canPersist`: whether a refresh's new tokens can be written to the
    /// Keychain (`UIApplication.isProtectedDataAvailable` on the iPhone). A
    /// refresh on a locked iPhone spends the stored refresh token and fails to
    /// write the new one, and its next launch is refused; so a locked iPhone
    /// never refreshes for the Watch. It hands over a token still valid, and
    /// otherwise answers nothing until it is unlocked. A token whose expiry
    /// cannot be read is sent as it is.
    ///
    /// `watchHoldsIt` (1.61): the Watch asked while holding this very token.
    /// Handing it back would only send the Watch round again (a 401 loop that
    /// woke the iPhone every tick), so it is refreshed, or, locked, no answer.
    public static func phoneRenewal(
        accessToken: String,
        now: Date = Date(),
        canPersist: Bool,
        margin: TimeInterval = 300,
        watchHoldsIt: Bool = false
    ) -> PhoneRenewal {
        if watchHoldsIt { return canPersist ? .renewFirst : .noAnswer }
        guard let expiry = APIClient.jwtExpiry(accessToken) else { return .sendAsIs }
        if expiry.timeIntervalSince(now) > margin { return .sendAsIs }
        if canPersist { return .renewFirst }
        return expiry > now ? .sendAsIs : .noAnswer
    }

    // MARK: Tokens the iPhone delivered (1.61)

    /// Of the token the Watch kept from the iPhone and one just delivered, the
    /// one to keep for `userID`: never another account's, and never one that
    /// expires earlier (queued transfers arrive out of order).
    public static func newerDelivered(_ incoming: String, than kept: String?, userID: String) -> String? {
        guard !incoming.isEmpty, tokenBelongs(incoming, to: userID) else { return kept }
        guard let kept, tokenBelongs(kept, to: userID) else { return incoming }
        guard let new = APIClient.jwtExpiry(incoming), let old = APIClient.jwtExpiry(kept) else { return incoming }
        return new > old ? incoming : kept
    }

    /// A kept token the Watch can use instead of asking the iPhone: this
    /// account's, valid for at least `margin` more seconds, and not the one it
    /// holds (that one is why it is asking).
    public static func usableDelivered(
        _ kept: String?,
        userID: String,
        holding held: String?,
        now: Date = Date(),
        margin: TimeInterval = 60
    ) -> String? {
        guard
            let kept, !kept.isEmpty, kept != held,
            tokenBelongs(kept, to: userID),
            let expiry = APIClient.jwtExpiry(kept),
            expiry.timeIntervalSince(now) > margin
        else { return nil }
        return kept
    }

    /// Whether a token can be this account's: its `sub` is the account, or it
    /// has no readable `sub` (then nothing can be told from it).
    public static func tokenBelongs(_ token: String, to userID: String) -> Bool {
        guard let subject = APIClient.jwtSubject(token) else { return true }
        return sameUser(subject, userID)
    }

    /// Whether two user ids name one account (`WatchSessionIdentity`'s
    /// normalization).
    public static func sameUser(_ lhs: String, _ rhs: String) -> Bool {
        let l = normalized(lhs)
        return !l.isEmpty && l == normalized(rhs)
    }

    /// The answer as a dictionary, for a reply or a queued transfer. Never
    /// holds a refresh token.
    public static func message(for answer: Answer, identity: WatchSessionIdentity? = nil) -> [String: Any] {
        var message: [String: Any] = [answerKey: true]
        switch answer {
        case let .accessToken(token, userID):
            message[statusKey] = "ok"
            message[accessTokenKey] = token
            message[userIDKey] = userID
        case .signedOut:
            message[statusKey] = "signed_out"
        case .unavailable:
            message[statusKey] = "unavailable"
        }
        if let identity {
            message["session_epoch"] = String(identity.epoch)
            if message[userIDKey] == nil { message[userIDKey] = identity.userID }
        }
        return message
    }

    /// Reads an answer. Anything that is not a well-formed answer is
    /// `.unavailable`, never `.signedOut`: only the iPhone saying so ends the
    /// Watch's session.
    public static func answer(from message: [String: Any]) -> Answer {
        guard message[answerKey] as? Bool == true else { return .unavailable }
        switch message[statusKey] as? String {
        case "ok":
            guard
                let token = message[accessTokenKey] as? String, !token.isEmpty,
                let userID = message[userIDKey] as? String, !userID.isEmpty
            else {
                return .unavailable
            }
            return .accessToken(token, userID: userID)
        case "signed_out":
            return .signedOut
        default:
            return .unavailable
        }
    }

    // MARK: The Watch's side

    /// What the Watch does with an answer about its session for `currentUserID`.
    public enum WatchAction: Equatable, Sendable {
        /// Use this access token in place of the old one.
        case install(accessToken: String)
        /// The iPhone is signed out: the session ends, tokens and all.
        case signOut
        /// Keep the session and the tokens, show the last data as stale, and
        /// ask again when the iPhone can be reached.
        case wait
    }

    public static func watchAction(for answer: Answer, currentUserID: String) -> WatchAction {
        switch answer {
        case let .accessToken(token, userID):
            guard sameUser(userID, currentUserID), tokenBelongs(token, to: currentUserID) else {
                return .wait
            }
            return .install(accessToken: token)
        case .signedOut:
            return .signOut
        case .unavailable:
            return .wait
        }
    }

    /// What a Watch session restore that failed does.
    public enum RestoreFailureAction: Equatable, Sendable {
        /// Signed in from the record, showing the last data the iPhone sent,
        /// and asking again.
        case showOffline
        /// The server refused the Watch's own session: its tokens go.
        case deleteCredentials
        /// Not signed in, the tokens kept for the next try (as before).
        case keepCredentials
    }

    /// A session from the iPhone is never ended by its restore: only the
    /// iPhone's "signed out" (which signs the Watch out before the restore
    /// sees an error) or its sign-out message does. Even a token the server
    /// refuses is the iPhone's to replace. The Watch's own session follows
    /// `WatchSessionRestoreCredentialPolicy`, as before.
    public static func restoreFailureAction(source: WatchSessionSource, error: Error) -> RestoreFailureAction {
        if source == .phone { return .showOffline }
        if let apiError = error as? APIError,
           WatchSessionRestoreCredentialPolicy.shouldDeletePersistedCredentials(after: apiError) {
            return .deleteCredentials
        }
        return .keepCredentials
    }

    private static func normalized(_ userID: String) -> String {
        userID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// A renewal the iPhone could not give now. The session and its tokens stay;
/// the Watch shows its last data and asks again.
public enum WatchCredentialRelayError: LocalizedError, Equatable {
    case waitingForPhone

    public var errorDescription: String? {
        switch self {
        case .waitingForPhone: return L10n.watch.waitingForPhone
        }
    }
}
