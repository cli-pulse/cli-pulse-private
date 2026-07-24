import Foundation

/// The only filesystem capabilities available to passive Agent discovery.
/// This deliberately has no process execution, Keychain, browser, bookmark
/// resolution, or networking API. Interactive connection belongs to the
/// user-initiated connection flow, not this service.
public protocol ProviderDiscoveryFileInspecting {
    func fileExists(atPath path: String) -> Bool
    func isExecutableFile(atPath path: String) -> Bool
}

public struct FileManagerProviderDiscoveryInspector:
    ProviderDiscoveryFileInspecting
{
    public init() {}

    public func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func isExecutableFile(atPath path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }
}

public enum ProviderDiscoveryStatus:
    String, Codable, Equatable, Sendable
{
    case detected
    case connected
    case actionRequired
    case notFound
}

public enum ProviderDiscoverySignal:
    String, Codable, Hashable, Sendable
{
    case installedCLI
    case configurationFile
    case authorizedBookmark
    case existingConfiguration
    case knownConnection
}

/// Non-secret account metadata supplied by the existing ProviderConfig store.
/// Callers decide whether an account has a known usable connection; discovery
/// never loads its Keychain slot to find out.
public struct ProviderDiscoveryAccountMetadata:
    Equatable, Hashable, Sendable
{
    public let accountID: UUID
    public let provider: ProviderKind
    public let isEnabled: Bool

    public init(
        accountID: UUID,
        provider: ProviderKind,
        isEnabled: Bool
    ) {
        self.accountID = accountID
        self.provider = provider
        self.isEnabled = isEnabled
    }

    public init(config: ProviderConfig) {
        self.init(
            accountID: config.accountID,
            provider: config.kind,
            isEnabled: config.isEnabled
        )
    }
}

public struct ProviderDiscoveryContext: Equatable, Sendable {
    public static let empty = ProviderDiscoveryContext(
        accounts: [],
        connectedAccountIDs: [],
        authorizedBookmarkIDs: []
    )

    public let accounts: [ProviderDiscoveryAccountMetadata]
    public let connectedAccountIDs: Set<UUID>
    /// IDs are metadata supplied by BookmarkManager after a prior user grant.
    /// This service does not resolve or start access to any bookmark.
    public let authorizedBookmarkIDs: Set<String>

    public init(
        accounts: [ProviderDiscoveryAccountMetadata],
        connectedAccountIDs: Set<UUID>,
        authorizedBookmarkIDs: Set<String>
    ) {
        self.accounts = accounts
        self.connectedAccountIDs = connectedAccountIDs
        self.authorizedBookmarkIDs = authorizedBookmarkIDs
    }
}

public struct ProviderDiscoveryCandidate:
    Equatable, Identifiable, Sendable
{
    public var id: ProviderKind { kind }

    public let kind: ProviderKind
    public let status: ProviderDiscoveryStatus
    public let accountIDs: [UUID]
    public let signals: Set<ProviderDiscoverySignal>

    public init(
        kind: ProviderKind,
        status: ProviderDiscoveryStatus,
        accountIDs: [UUID],
        signals: Set<ProviderDiscoverySignal>
    ) {
        self.kind = kind
        self.status = status
        self.accountIDs = accountIDs
        self.signals = signals
    }
}

/// Bounded first-run discovery for the three optimized Coding Agents.
///
/// Discovery intentionally returns a deterministic row for Codex, Claude, and
/// Gemini only. Providers without a signal are `.notFound`; the future UI can
/// hide those rows while still offering a generic manual-add path.
public struct ProviderDiscoveryService {
    private struct Probe {
        let kind: ProviderKind
        let bookmarkID: String
        let configurationRelativePath: String
    }

    private static let probes = [
        Probe(
            kind: .codex,
            bookmarkID: "codex",
            configurationRelativePath: ".codex/auth.json"
        ),
        Probe(
            kind: .claude,
            bookmarkID: "claude",
            configurationRelativePath: ".claude/.credentials.json"
        ),
        Probe(
            kind: .gemini,
            bookmarkID: "gemini",
            configurationRelativePath: ".gemini/oauth_creds.json"
        ),
    ]

    private let fileInspector: any ProviderDiscoveryFileInspecting
    private let homeDirectory: String
    private let pathDirectories: [String]

    public init(
        fileInspector: any ProviderDiscoveryFileInspecting =
            FileManagerProviderDiscoveryInspector(),
        homeDirectory: String = NSHomeDirectory(),
        pathDirectories: [String]? = nil
    ) {
        self.fileInspector = fileInspector
        self.homeDirectory = homeDirectory
        self.pathDirectories = Self.normalizedPathDirectories(
            pathDirectories
                ?? ProcessInfo.processInfo.environment["PATH"]?
                    .split(separator: ":")
                    .map(String.init)
                ?? []
        )
    }

    public func discover(
        context: ProviderDiscoveryContext
    ) -> [ProviderDiscoveryCandidate] {
        let bookmarkIDs = Set(
            context.authorizedBookmarkIDs.map {
                $0.lowercased()
            }
        )

        return Self.probes.map { probe in
            let accounts = context.accounts
                .filter { $0.provider == probe.kind }
            let accountIDs = Array(Set(accounts.map(\.accountID)))
                .sorted {
                    $0.uuidString < $1.uuidString
                }
            let connectedIDs = context.connectedAccountIDs.intersection(
                accountIDs
            )
            var signals: Set<ProviderDiscoverySignal> = []

            if !accounts.isEmpty {
                signals.insert(.existingConfiguration)
            }
            if !connectedIDs.isEmpty {
                signals.insert(.knownConnection)
            }

            let configurationPath = (
                homeDirectory as NSString
            ).appendingPathComponent(
                probe.configurationRelativePath
            )
            if fileInspector.fileExists(atPath: configurationPath) {
                signals.insert(.configurationFile)
            }

            if bookmarkIDs.contains(probe.bookmarkID) {
                signals.insert(.authorizedBookmark)
            }

            let cliNames = ProviderRegistry.descriptor(
                for: probe.kind
            ).cliNames
            let hasInstalledCLI = cliNames.contains { cliName in
                pathDirectories.contains { directory in
                    let executablePath = (
                        directory as NSString
                    ).appendingPathComponent(cliName)
                    return fileInspector.isExecutableFile(
                        atPath: executablePath
                    )
                }
            }
            if hasInstalledCLI {
                signals.insert(.installedCLI)
            }

            let status: ProviderDiscoveryStatus
            if signals.contains(.knownConnection) {
                status = .connected
            } else if signals.contains(.existingConfiguration) {
                status = .actionRequired
            } else if signals.isEmpty {
                status = .notFound
            } else {
                status = .detected
            }

            return ProviderDiscoveryCandidate(
                kind: probe.kind,
                status: status,
                accountIDs: accountIDs,
                signals: signals
            )
        }
    }

    private static func normalizedPathDirectories(
        _ directories: [String]
    ) -> [String] {
        var seen: Set<String> = []
        return directories.compactMap { rawDirectory in
            let directory = rawDirectory.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard
                !directory.isEmpty,
                seen.insert(directory).inserted
            else {
                return nil
            }
            return directory
        }
    }
}
