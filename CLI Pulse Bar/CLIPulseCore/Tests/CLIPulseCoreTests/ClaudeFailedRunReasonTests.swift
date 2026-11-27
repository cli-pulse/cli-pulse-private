#if os(macOS)
import Security
import XCTest
@testable import CLIPulseCore

/// 1.63.3: a Claude run that failed because Claude Code's own login cannot be
/// used says so, instead of "Check failed — This one is on us".
///
/// Seen on the owner's Mac on 1.63.2: Claude Code's keychain login was refused
/// (OAuth 401), the keychain read went on cooldown, the `claude` binary was
/// there, so the CLI probe ran and failed on the same login, and the row said
/// the failure was ours. `ClaudeStrategyError` was unknown to `categorize`
/// (everything Claude threw was `.other`), and the resolver threw the LAST
/// strategy's failure, not the refused token.
///
/// Every strategy here is a stub and the snapshot cache is injected: nothing
/// this Mac has (Claude Code's login, its credentials file, a snapshot or
/// account file its helper wrote) decides a result. The resolver's DEBUG log
/// line still describes the helper's snapshot files; it reads, never decides.
final class ClaudeFailedRunReasonTests: XCTestCase {

    private var ownerSuite: String!
    private var ownerDefaults: UserDefaults!
    private var originalOwnerDefaults: UserDefaults?
    private var originalSynchronize: ((UserDefaults) -> Bool)!
    private var originalMutationLock: GeminiCredentialMutationLock!
    private var mutationLockPath: String!

    private let accountID = UUID(uuidString: "5E5E5E5E-0000-4000-8000-000000001633")!
    private var config: ProviderConfig { ProviderConfig(kind: .claude, accountID: accountID) }

    override func setUp() {
        super.setUp()
        // `resolveTokenDetails` claims the machine's login for the entry
        // before it reads anything; keep that claim out of the real app group.
        originalOwnerDefaults = ProviderSharedCredentialOwner.defaults
        originalSynchronize = ProviderSharedCredentialOwner.synchronizeDefaults
        originalMutationLock = ProviderSharedCredentialOwner.mutationLock
        ownerSuite = "test.claude-failed-run.owner.\(UUID().uuidString)"
        ownerDefaults = UserDefaults(suiteName: ownerSuite)!
        ProviderSharedCredentialOwner.defaults = ownerDefaults
        ProviderSharedCredentialOwner.synchronizeDefaults = { _ in true }
        mutationLockPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(ownerSuite!).lock").path
        ProviderSharedCredentialOwner.mutationLock = GeminiCredentialMutationLock(lockFilePath: mutationLockPath)
    }

    override func tearDown() {
        ProviderSharedCredentialOwner.defaults = originalOwnerDefaults
        ProviderSharedCredentialOwner.synchronizeDefaults = originalSynchronize
        ProviderSharedCredentialOwner.mutationLock = originalMutationLock
        ownerDefaults.removePersistentDomain(forName: ownerSuite)
        try? FileManager.default.removeItem(atPath: mutationLockPath)
        super.tearDown()
    }

    // MARK: - Stubs

    /// Decides availability as `ClaudeOAuthStrategy` does (a token from
    /// `resolveTokenDetails`), from an injected keychain answer, so the
    /// resolver notes the absence in the log `collect` binds.
    private struct TokenlessOAuth: ClaudeSourceStrategy {
        let sourceLabel = "oauth"
        let sourceType: SourceType = .oauth
        let keychain: ClaudeKeychainLookup
        func isAvailable(config: ProviderConfig) -> Bool {
            let lookup = keychain
            return !ClaudeCredentials.resolveTokenDetails(
                config: config, environment: [:], credentialsFile: { nil }, keychain: { lookup }
            ).token.isEmpty
        }
        func fetch(config: ProviderConfig) async throws -> ClaudeSnapshot {
            throw ClaudeStrategyError.noToken
        }
    }

    /// What `ClaudeOAuthStrategy` does when Anthropic refuses the token it
    /// read from Claude Code's keychain item: arms the cooldown (not here),
    /// notes the absence the next run will meet, throws the 401.
    private struct RefusedOAuth: ClaudeSourceStrategy {
        let sourceLabel = "oauth"
        let sourceType: SourceType = .oauth
        func isAvailable(config: ProviderConfig) -> Bool { true }
        func fetch(config: ProviderConfig) async throws -> ClaudeSnapshot {
            ClaudeTokenResolutionLog.note(.keychain(.onCooldown(.rejectedToken)))
            throw ClaudeStrategyError.httpError(status: 401, provider: "Claude")
        }
    }

    private struct Failing: ClaudeSourceStrategy {
        let sourceLabel: String
        let sourceType: SourceType
        let error: ClaudeStrategyError
        init(_ sourceType: SourceType, _ error: ClaudeStrategyError) {
            self.sourceType = sourceType
            self.sourceLabel = sourceType.rawValue
            self.error = error
        }
        func isAvailable(config: ProviderConfig) -> Bool { true }
        func fetch(config: ProviderConfig) async throws -> ClaudeSnapshot { throw error }
    }

    private func resolver(_ strategies: [any ClaudeSourceStrategy]) -> ClaudeSourceResolver {
        ClaudeSourceResolver(strategies: strategies, cachedSnapshot: { nil })
    }

    /// What the row shows after `collect` with these strategies, and what it threw.
    private func run(_ strategies: [any ClaudeSourceStrategy]) async -> (outcome: CollectorOutcome, error: Error?) {
        do {
            _ = try await ClaudeCollector(resolver: resolver(strategies)).collect(config: config)
            return (.producedData, nil)
        } catch {
            return (CollectorRunner.failureOutcome(error, strictPrivacySkips: []), error)
        }
    }

    private static let cliCannotRead = ClaudeStrategyError.parseFailed("no usage percentages found in CLI output")

    // MARK: - Claude Code's login cannot be used: say so

    func test_refusedLoginOnCooldown_andClaudeCodeHangsOrExits_isNotSignedIn() async throws {
        for cliError in [ClaudeStrategyError.timedOut, .processExited] {
            let (outcome, error) = await run([
                TokenlessOAuth(keychain: .missing(.onCooldown(.rejectedToken))),
                Failing(.cli, cliError),
            ])
            XCTAssertEqual(outcome, .notReady(.missingCredentials), "\(cliError)")
            let failure = try XCTUnwrap(error as? CollectorNotReadyFailure)
            XCTAssertEqual((failure.underlying as? ClaudeStrategyError)?.errorDescription, cliError.errorDescription,
                           "the run's own failure is kept for the log")
        }
    }

    func test_refusedLogin_withoutAnyOtherSource_isNotSignedIn() async {
        // The `claude` binary is not there; the web strategy had no cookie.
        let (outcome, _) = await run([
            TokenlessOAuth(keychain: .missing(.onCooldown(.rejectedToken))),
            Failing(.web, .noSessionKey),
        ])
        XCTAssertEqual(outcome, .notReady(.missingCredentials))
    }

    func test_aCLIProbeThatPrintedSomethingElse_keepsItsOwnFailure() async {
        // A throttled probe, or Claude Code printing a screen the parser does
        // not know: the login may well be fine, so "Not signed in" could be
        // false. The owner's own run on 1.63.2 ended with the web cookie
        // refused, which is reported as such ("Authentication failed").
        let alone = await run([
            TokenlessOAuth(keychain: .missing(.onCooldown(.rejectedToken))),
            Failing(.cli, Self.cliCannotRead),
        ])
        XCTAssertEqual(alone.outcome, .failed(.other))
        let withRefusedCookie = await run([
            TokenlessOAuth(keychain: .missing(.onCooldown(.rejectedToken))),
            Failing(.cli, .parseFailed("cli-pty probe throttled (~60s backoff remaining); skipping PTY spawn")),
            Failing(.web, .unauthorized),
        ])
        XCTAssertEqual(withRefusedCookie.outcome, .failed(.auth))
    }

    func test_theRunWhereTheTokenIsRefused_saysTheSameAsTheRunsAfterIt() async {
        let (outcome, _) = await run([RefusedOAuth(), Failing(.cli, .timedOut)])
        XCTAssertEqual(outcome, .notReady(.missingCredentials),
                       "the first run said 'Authentication failed', every later one 'Not signed in'")
    }

    func test_expiredLogin_isNotSignedIn() async {
        let (outcome, _) = await run([
            TokenlessOAuth(keychain: .missing(.expiredLogin)),
            Failing(.cli, .timedOut),
        ])
        XCTAssertEqual(outcome, .notReady(.missingCredentials))
    }

    func test_declinedKeychainDialog_isKeychainDenied() async {
        for miss in [ClaudeKeychainMiss.status(errSecAuthFailed), .status(errSecUserCanceled), .onCooldown(.declined)] {
            let (outcome, _) = await run([
                TokenlessOAuth(keychain: .missing(miss)),
                Failing(.cli, .processExited),
            ])
            XCTAssertEqual(outcome, .notReady(.keychainDenied), "\(miss)")
        }
    }

    func test_aWebStrategyWithNoCookie_orARefusedOne_doesNotChangeIt() async {
        for webError in [ClaudeStrategyError.noSessionKey, .unauthorized,
                         .httpError(status: 401, provider: "Claude Web"),
                         .httpError(status: 403, provider: "Claude Web")] {
            let (outcome, _) = await run([
                TokenlessOAuth(keychain: .missing(.onCooldown(.rejectedToken))),
                Failing(.cli, .processExited),
                Failing(.web, webError),
            ])
            XCTAssertEqual(outcome, .notReady(.missingCredentials), "\(webError)")
        }
    }

    // MARK: - Something else failed: report that

    func test_aWebCookieThatWorked_keepsItsOwnFailure() async {
        // The cookie is a credential of its own. When it got an answer and the
        // answer could not be read, or was a 429, that is what to report.
        let unreadable = await run([
            TokenlessOAuth(keychain: .missing(.onCooldown(.rejectedToken))),
            Failing(.web, .parseFailed("usage response not a dictionary")),
        ])
        XCTAssertEqual(unreadable.outcome, .failed(.other))
        XCTAssertTrue(unreadable.error is ClaudeStrategyError, "\(String(describing: unreadable.error))")

        let rateLimited = await run([
            TokenlessOAuth(keychain: .missing(.onCooldown(.rejectedToken))),
            Failing(.cli, .timedOut),
            Failing(.web, .httpError(status: 429, provider: "Claude Web")),
        ])
        XCTAssertEqual(rateLimited.outcome, .failed(.http))
    }

    func test_theRunWhereTheTokenIsRefused_withACookieThatFailedOtherwise_saysAuthenticationFailed() async {
        // Both are true in that run; the refusal is the one that needs the
        // user, so the resolver ranks it first. Later runs no longer send the
        // token (cooldown) and report the cookie's own failure.
        let (outcome, _) = await run([
            RefusedOAuth(),
            Failing(.web, .httpError(status: 429, provider: "Claude Web")),
        ])
        XCTAssertEqual(outcome, .failed(.auth))
    }

    func test_noClaudeCodeLoginAtAll_keepsTheFailure() async {
        // No item: the run failed in whatever the user did set up.
        let (outcome, error) = await run([
            TokenlessOAuth(keychain: .missing(.status(errSecItemNotFound))),
            Failing(.cli, .timedOut),
        ])
        XCTAssertEqual(outcome, .failed(.other))
        XCTAssertFalse(error is CollectorNotReadyFailure)
    }

    func test_privacySwitches_aLockedScreen_andAnUnreadableItem_keepTheFailure() async {
        for miss in [ClaudeKeychainMiss.skipped(.skippedBySetting), .skipped(.skippedStrictPrivacyMode),
                     .skipped(.skippedAwaitingApp), .status(errSecInteractionNotAllowed), .unreadable] {
            let (outcome, error) = await run([
                TokenlessOAuth(keychain: .missing(miss)),
                Failing(.cli, .timedOut),
            ])
            XCTAssertEqual(outcome, .failed(.other), "\(miss)")
            guard case .timedOut? = error as? ClaudeStrategyError else {
                return XCTFail("\(miss): the run's own failure is reported, got \(String(describing: error))")
            }
        }
    }

    func test_aRefusedTokenThatIsNotClaudeCodes_isAuthenticationFailed() async {
        // A token of the entry's own (or from the credentials file) arms no
        // cooldown and notes nothing: its 401 is reported as itself, ahead of
        // the CLI probe's failure that came after it.
        let (outcome, _) = await run([
            Failing(.oauth, .httpError(status: 401, provider: "Claude")),
            Failing(.cli, Self.cliCannotRead),
        ])
        XCTAssertEqual(outcome, .failed(.auth))
    }

    func test_aCachedSnapshotStillAnswers() async throws {
        let snapshot = ClaudeSnapshot(sessionUsed: 10, weeklyUsed: 20, sourceLabel: "cache")
        // No strategy here resolves a token, so the entry claims no shared
        // login and the resolver reads no account file of this Mac's.
        let collector = ClaudeCollector(resolver: ClaudeSourceResolver(
            strategies: [Failing(.cli, .timedOut)],
            cachedSnapshot: { snapshot }))
        _ = try await collector.collect(config: config)
    }

    // MARK: - The resolver throws the most actionable failure

    private func thrown(by strategies: [any ClaudeSourceStrategy]) async -> Error? {
        do {
            _ = try await resolver(strategies).resolve(config: config)
            return nil
        } catch {
            return error
        }
    }

    func test_resolve_throwsTheRefusedCredential_notTheLastFailure() async {
        let error = await thrown(by: [
            Failing(.oauth, .httpError(status: 401, provider: "Claude")),
            Failing(.cli, Self.cliCannotRead),
            Failing(.web, .noSessionKey),
        ])
        guard case .httpError(401, _)? = error as? ClaudeStrategyError else {
            return XCTFail("\(String(describing: error))")
        }
    }

    func test_resolve_withoutARefusal_throwsAnErrorStatusAheadOfTheRest() async {
        let error = await thrown(by: [
            Failing(.oauth, .rateLimitBackoff(remaining: 120)),
            Failing(.cli, .timedOut),
        ])
        guard case .rateLimitBackoff? = error as? ClaudeStrategyError else {
            return XCTFail("\(String(describing: error))")
        }
    }

    func test_resolve_otherwiseThrowsTheLastFailure_asBefore() async {
        let error = await thrown(by: [Failing(.cli, .timedOut), Failing(.web, .noSessionKey)])
        guard case .noSessionKey? = error as? ClaudeStrategyError else {
            return XCTFail("\(String(describing: error))")
        }
    }

    func test_resolve_neverLeaksTheInternalAggregate() async {
        let error = await thrown(by: [Failing(.cli, .timedOut)])
        XCTAssertFalse(error is ClaudeStrategiesExhausted)
        XCTAssertTrue(error is ClaudeStrategyError)
    }

    // MARK: - Categories, the outcome, the Test button, the log

    func test_categorize_knowsClaudesErrors() {
        let cases: [(ClaudeStrategyError, CollectorFailureCategory)] = [
            (.httpError(status: 401, provider: "Claude"), .auth),
            (.httpError(status: 403, provider: "Claude"), .auth),
            (.unauthorized, .auth),
            (.httpError(status: 429, provider: "Claude"), .http),
            (.httpError(status: 500, provider: "Claude"), .http),
            (.rateLimitBackoff(remaining: 60), .http),
            // Not a format change every time it is thrown (a throttled probe,
            // a failed openpty, a non-HTTP response), so not `.parse`.
            (.parseFailed("cli-pty probe throttled"), .other),
            (.noToken, .other),
            (.noSessionKey, .other),
            (.noBinary, .other),
            (.timedOut, .other),
            (.processExited, .other),
        ]
        for (error, expected) in cases {
            XCTAssertEqual(CollectorFailureCategory.categorize(error), expected, "\(error)")
        }
    }

    func test_theNotReadyFailure_isReportedAsNotReady_andTheTestButtonSaysWhatTheRowSays() {
        let failure = CollectorNotReadyFailure(
            reason: .missingCredentials, providerName: "Claude", underlying: Self.cliCannotRead)
        XCTAssertEqual(CollectorRunner.failureOutcome(failure, strictPrivacySkips: []),
                       .notReady(.missingCredentials))
        let row = CollectorOutcomePresentation.of(.notReady(.missingCredentials), providerName: "Claude")
        XCTAssertEqual(failure.localizedDescription, row.nextStep)
        XCTAssertNil(CollectorRunner.strictPrivacySkip(causing: failure, strictPrivacySkips: []))
    }

    func test_theLogKeepsTheReason_andTheFailureTheRunEndedWith() {
        let failure = CollectorNotReadyFailure(
            reason: .missingCredentials, providerName: "Claude",
            underlying: ClaudeStrategyError.httpError(status: 401, provider: "Claude"))
        let line = CollectorError.logText(for: failure)
        XCTAssertTrue(line.contains("missing_credentials"), line)
        XCTAssertTrue(line.contains("401"), line)
    }

    func test_theOAuthStrategyNotesTheRefusal_whereItArmsTheCooldown() throws {
        // The first run reports the same as later ones only because the real
        // 401 branch notes the absence. Its network call cannot be stubbed
        // here (`CredentialedURLSession.shared`), so the placement is pinned:
        // inside the branch that drops Claude Code's copy and arms the
        // cooldown, before the 401 is thrown.
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/CLIPulseCore/Collectors/Claude/ClaudeOAuthStrategy.swift"),
            encoding: .utf8)
        let drop = try XCTUnwrap(source.range(of: "ClaudeCredentials.dropRejectedKeychainCopy(token: token)"))
        let arm = try XCTUnwrap(source.range(of: "ClaudeCredentials.installKeychainReadCooldown(cause: .rejectedToken)"))
        let note = try XCTUnwrap(source.range(of: "ClaudeTokenResolutionLog.note(.keychain(.onCooldown(.rejectedToken)))"))
        let rethrow = try XCTUnwrap(source.range(
            of: "throw ClaudeStrategyError.httpError(status: status, provider: \"Claude\")", range: note.upperBound..<source.endIndex))
        XCTAssertTrue(drop.upperBound < arm.lowerBound && arm.upperBound < note.lowerBound
                      && note.upperBound < rethrow.lowerBound)
        let between = source[arm.upperBound..<note.lowerBound]
        XCTAssertFalse(between.contains("}\n        } catch"), "the note left the 401 branch")
    }
}
#endif
