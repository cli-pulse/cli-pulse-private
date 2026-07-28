import Foundation
import Darwin

public struct CLIPulseRuntimeEnvironment: Equatable, Sendable {
    public enum Channel: String, Sendable {
        case production
        case qa
    }

    public struct Capabilities: Equatable, Sendable {
        public let allowsTelemetry: Bool
        public let allowsUnsandboxedMigration: Bool
        public let allowsHelperRegistration: Bool
        public let allowsPermissionSnapshot: Bool
        public let allowsStoreKitBootstrap: Bool
        public let allowsLiveCollection: Bool
        public let allowsWidgetPublishing: Bool
        public let allowsProductionCloudEndpoints: Bool
        public let allowsPassiveDiscovery: Bool
        public let allowsInMemoryDemoRendering: Bool

        fileprivate static let production = Self(
            allowsTelemetry: true,
            allowsUnsandboxedMigration: true,
            allowsHelperRegistration: true,
            allowsPermissionSnapshot: true,
            allowsStoreKitBootstrap: true,
            allowsLiveCollection: true,
            allowsWidgetPublishing: true,
            allowsProductionCloudEndpoints: true,
            allowsPassiveDiscovery: true,
            allowsInMemoryDemoRendering: true
        )

        fileprivate static let qa = Self(
            allowsTelemetry: false,
            allowsUnsandboxedMigration: false,
            allowsHelperRegistration: false,
            allowsPermissionSnapshot: false,
            allowsStoreKitBootstrap: false,
            allowsLiveCollection: false,
            allowsWidgetPublishing: false,
            allowsProductionCloudEndpoints: false,
            allowsPassiveDiscovery: true,
            allowsInMemoryDemoRendering: true
        )

        fileprivate static let quarantine = Self(
            allowsTelemetry: false,
            allowsUnsandboxedMigration: false,
            allowsHelperRegistration: false,
            allowsPermissionSnapshot: false,
            allowsStoreKitBootstrap: false,
            allowsLiveCollection: false,
            allowsWidgetPublishing: false,
            allowsProductionCloudEndpoints: false,
            allowsPassiveDiscovery: false,
            allowsInMemoryDemoRendering: false
        )
    }

    internal struct FileSystemAccess {
        enum PathEntry: Equatable {
            case directory
            case symbolicLink
            case other
            case missing
            case notDirectory
            case lookupFailed
        }

        let inspectEntry: (String) -> PathEntry
        let resolveRealPath: (String) -> String?
    }

    private static let productionBundleIdentifier = "yyh.CLI-Pulse"
    private static let qaBundleIdentifier = "app.clipulse.qa.local"
    private static let qaHomeRoot = "/private/tmp/clipulse-qa-home"

    public let channel: Channel
    public let bundleIdentifier: String
    public let fixedUserHome: String?
    public let resolvedFixedUserHome: String?
    public let capabilities: Capabilities
    public let shouldResetQAExperience: Bool

    public var isQA: Bool {
        channel == .qa
    }

    public var keychainService: String {
        guard isLaunchSafe else {
            return "com.clipulse.app.quarantine"
        }
        return isQA ? "com.clipulse.app.qa" : "com.clipulse.app"
    }

    public var keychainAccessGroup: String {
        guard isLaunchSafe else {
            return "group.yyh.CLI-Pulse.quarantine"
        }
        return isQA ? "group.yyh.CLI-Pulse.qa" : "group.yyh.CLI-Pulse"
    }

    public var isLaunchSafe: Bool {
        Self.isLaunchSafe(
            channel: channel,
            bundleIdentifier: bundleIdentifier,
            resolvedFixedUserHome: resolvedFixedUserHome
        )
    }

    private static func isLaunchSafe(
        channel: Channel,
        bundleIdentifier: String,
        resolvedFixedUserHome: String?
    ) -> Bool {
        switch channel {
        case .production:
            return bundleIdentifier == Self.productionBundleIdentifier
        case .qa:
            guard bundleIdentifier == Self.qaBundleIdentifier,
                  let resolvedFixedUserHome
            else {
                return false
            }

            return resolvedFixedUserHome == Self.qaHomeRoot
                || resolvedFixedUserHome.hasPrefix(Self.qaHomeRoot + "/")
        }
    }

    /// Captures the bundle, process environment, and live filesystem state
    /// intended to be validated during app startup.
    ///
    /// This is a point-in-time startup snapshot, not an atomic isolation
    /// boundary against concurrent filesystem mutation by the same user.
    public static var current: Self {
        resolveSnapshot(
            infoDictionary: Bundle.main.infoDictionary ?? [:],
            environment: ProcessInfo.processInfo.environment,
            fileSystem: liveFileSystem
        )
    }

    internal static func resolveForTesting(
        infoDictionary: [String: Any],
        environment: [String: String]
    ) -> Self {
        resolveSnapshot(
            infoDictionary: infoDictionary,
            environment: environment,
            fileSystem: liveFileSystem
        )
    }

    internal static func resolveForTesting(
        infoDictionary: [String: Any],
        environment: [String: String],
        fileSystem: FileSystemAccess
    ) -> Self {
        resolveSnapshot(
            infoDictionary: infoDictionary,
            environment: environment,
            fileSystem: fileSystem
        )
    }

    private static func resolveSnapshot(
        infoDictionary: [String: Any],
        environment: [String: String],
        fileSystem: FileSystemAccess
    ) -> Self {
        let channel = (infoDictionary["CLIPULSE_CHANNEL"] as? String) == Channel.qa.rawValue
            ? Channel.qa
            : Channel.production
        let bundleIdentifier = infoDictionary["CFBundleIdentifier"] as? String ?? ""
        let fixedUserHome = environment["CFFIXED_USER_HOME"]
        let resolvedFixedUserHome = resolveFixedUserHome(
            fixedUserHome,
            requiresExistingQARoot: channel == .qa,
            fileSystem: fileSystem
        )
        let isLaunchSafe = isLaunchSafe(
            channel: channel,
            bundleIdentifier: bundleIdentifier,
            resolvedFixedUserHome: resolvedFixedUserHome
        )
        let shouldResetQAExperience =
            channel == .qa
            && isLaunchSafe
            && environment["CLIPULSE_QA_RESET_ON_LAUNCH"] == "1"

        return Self(
            channel: channel,
            bundleIdentifier: bundleIdentifier,
            fixedUserHome: fixedUserHome,
            resolvedFixedUserHome: resolvedFixedUserHome,
            capabilities: isLaunchSafe
                ? (channel == .qa ? .qa : .production)
                : .quarantine,
            shouldResetQAExperience: shouldResetQAExperience
        )
    }

    /// Validates the captured startup snapshot. This does not make filesystem
    /// validation atomic against concurrent mutation by the same user.
    public func preconditionSafeLaunch(
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        precondition(
            isLaunchSafe,
            "Unsafe launch: channel, bundle identifier, and QA home do not match",
            file: file,
            line: line
        )
    }

    private static func resolveFixedUserHome(
        _ fixedUserHome: String?,
        requiresExistingQARoot: Bool,
        fileSystem: FileSystemAccess
    ) -> String? {
        guard let fixedUserHome, !fixedUserHome.isEmpty else { return nil }

        if requiresExistingQARoot {
            guard fileSystem.inspectEntry(Self.qaHomeRoot) == .directory,
                  let resolvedRoot = fileSystem.resolveRealPath(Self.qaHomeRoot),
                  standardizedAbsolutePath(resolvedRoot) == Self.qaHomeRoot
            else {
                return nil
            }
        }

        return canonicalizePath(fixedUserHome, fileSystem: fileSystem)
    }

    private static func standardizedAbsolutePath(_ path: String) -> String? {
        guard !path.isEmpty,
              !path.utf8.contains(0),
              (path as NSString).isAbsolutePath
        else {
            return nil
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains("."),
              !components.contains("..")
        else {
            return nil
        }

        return components.isEmpty
            ? "/"
            : "/" + components.joined(separator: "/")
    }

    private static var liveFileSystem: FileSystemAccess {
        FileSystemAccess(
            inspectEntry: inspectLivePathEntry,
            resolveRealPath: resolveLiveRealPath
        )
    }

    private static func canonicalizePath(
        _ path: String,
        fileSystem: FileSystemAccess
    ) -> String? {
        guard let standardizedPath = standardizedAbsolutePath(path) else {
            return nil
        }

        var candidate = standardizedPath
        var missingComponents: [String] = []

        while true {
            switch fileSystem.inspectEntry(candidate) {
            case .directory, .symbolicLink:
                guard let resolvedAncestor =
                        fileSystem.resolveRealPath(candidate),
                      let canonicalAncestor =
                        standardizedAbsolutePath(resolvedAncestor),
                      fileSystem.inspectEntry(canonicalAncestor) == .directory
                else {
                    return nil
                }

                return missingComponents.reduce(canonicalAncestor) {
                    ($0 as NSString).appendingPathComponent($1)
                }
            case .other, .lookupFailed:
                return nil
            case .missing, .notDirectory:
                guard candidate != "/" else {
                    return nil
                }

                let candidatePath = candidate as NSString
                let missingComponent = candidatePath.lastPathComponent
                guard !missingComponent.isEmpty, missingComponent != "/" else {
                    return nil
                }

                missingComponents.insert(missingComponent, at: 0)
                let parent = candidatePath.deletingLastPathComponent
                candidate = parent.isEmpty ? "/" : parent
            }
        }
    }

    private static func inspectLivePathEntry(
        _ path: String
    ) -> FileSystemAccess.PathEntry {
        guard !path.utf8.contains(0) else {
            return .lookupFailed
        }

        var metadata = stat()
        let status = path.withCString {
            Darwin.lstat($0, &metadata)
        }

        if status == 0 {
            let entryType = metadata.st_mode & S_IFMT
            if entryType == S_IFDIR {
                return .directory
            }
            if entryType == S_IFLNK {
                return .symbolicLink
            }
            return .other
        }

        switch errno {
        case ENOENT:
            return .missing
        case ENOTDIR:
            return .notDirectory
        default:
            return .lookupFailed
        }
    }

    private static func resolveLiveRealPath(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))

        return path.withCString { source in
            buffer.withUnsafeMutableBufferPointer { destination in
                guard let baseAddress = destination.baseAddress,
                      Darwin.realpath(source, baseAddress) != nil
                else {
                    return nil
                }
                return String(cString: baseAddress)
            }
        }
    }
}
