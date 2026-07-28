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
    }

    private static let productionBundleIdentifier = "yyh.CLI-Pulse"
    private static let qaBundleIdentifier = "app.clipulse.qa.local"
    private static let qaHomeRoot = "/private/tmp/clipulse-qa-home"

    public let channel: Channel
    public let bundleIdentifier: String
    public let fixedUserHome: String?
    public let resolvedFixedUserHome: String?
    public let capabilities: Capabilities

    public var isQA: Bool {
        channel == .qa
    }

    public var keychainService: String {
        isQA ? "com.clipulse.app.qa" : "com.clipulse.app"
    }

    public var keychainAccessGroup: String {
        isQA ? "group.yyh.CLI-Pulse.qa" : "group.yyh.CLI-Pulse"
    }

    public var isLaunchSafe: Bool {
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

    public static var current: Self {
        resolve(
            infoDictionary: Bundle.main.infoDictionary ?? [:],
            environment: ProcessInfo.processInfo.environment
        )
    }

    /// Resolves the runtime contract without mutating process state.
    ///
    /// Passing `nil` for the filesystem seams uses the live fail-closed
    /// `lstat`/`realpath` implementation. Tests can inject both seams to remain
    /// independent of the process environment and host filesystem.
    public static func resolve(
        infoDictionary: [String: Any],
        environment: [String: String],
        resolvingSymlinks: ((String) -> String?)? = nil,
        pathEntryExists: ((String) -> Bool)? = nil
    ) -> Self {
        let channel = (infoDictionary["CLIPULSE_CHANNEL"] as? String) == Channel.qa.rawValue
            ? Channel.qa
            : Channel.production
        let bundleIdentifier = infoDictionary["CFBundleIdentifier"] as? String ?? ""
        let fixedUserHome = environment["CFFIXED_USER_HOME"]
        let resolvedFixedUserHome = resolveFixedUserHome(
            fixedUserHome,
            requiresExistingQARoot: channel == .qa,
            resolvingSymlinks: resolvingSymlinks ?? canonicalizePath,
            pathEntryExists: pathEntryExists ?? pathEntryExistsIncludingSymlink
        )

        return Self(
            channel: channel,
            bundleIdentifier: bundleIdentifier,
            fixedUserHome: fixedUserHome,
            resolvedFixedUserHome: resolvedFixedUserHome,
            capabilities: channel == .qa ? .qa : .production
        )
    }

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
        resolvingSymlinks: (String) -> String?,
        pathEntryExists: (String) -> Bool
    ) -> String? {
        guard let fixedUserHome, !fixedUserHome.isEmpty else { return nil }

        if requiresExistingQARoot {
            guard pathEntryExists(Self.qaHomeRoot),
                  let resolvedRoot = resolvingSymlinks(Self.qaHomeRoot),
                  standardizedAbsolutePath(resolvedRoot) == Self.qaHomeRoot
            else {
                return nil
            }
        }

        guard let resolved = resolvingSymlinks(fixedUserHome) else {
            return nil
        }
        return standardizedAbsolutePath(resolved)
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

    private static func pathEntryExistsIncludingSymlink(_ path: String) -> Bool {
        guard !path.utf8.contains(0) else { return false }

        var metadata = stat()
        return path.withCString {
            Darwin.lstat($0, &metadata) == 0
        }
    }

    private static func canonicalizePath(_ path: String) -> String? {
        guard let standardizedPath = standardizedAbsolutePath(path) else {
            return nil
        }

        var candidate = standardizedPath
        var missingComponents: [String] = []

        while true {
            var metadata = stat()
            let lookupStatus = candidate.withCString {
                Darwin.lstat($0, &metadata)
            }

            if lookupStatus == 0 {
                guard let canonicalAncestor = realPath(candidate),
                      isDirectory(atPath: canonicalAncestor)
                else {
                    return nil
                }

                return missingComponents.reduce(canonicalAncestor) {
                    ($0 as NSString).appendingPathComponent($1)
                }
            }

            let lookupError = errno
            guard lookupError == ENOENT || lookupError == ENOTDIR,
                  candidate != "/"
            else {
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

    private static func realPath(_ path: String) -> String? {
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

    private static func isDirectory(atPath path: String) -> Bool {
        var metadata = stat()
        let status = path.withCString {
            Darwin.lstat($0, &metadata)
        }

        return status == 0 && metadata.st_mode & S_IFMT == S_IFDIR
    }
}
