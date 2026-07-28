import Foundation

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
        guard isQA else { return true }
        guard !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              bundleIdentifier != Self.productionBundleIdentifier,
              let resolvedFixedUserHome
        else {
            return false
        }

        return resolvedFixedUserHome == Self.qaHomeRoot
            || resolvedFixedUserHome.hasPrefix(Self.qaHomeRoot + "/")
    }

    public static var current: Self {
        resolve(
            infoDictionary: Bundle.main.infoDictionary ?? [:],
            environment: ProcessInfo.processInfo.environment
        )
    }

    public static func resolve(
        infoDictionary: [String: Any],
        environment: [String: String],
        resolvingSymlinks: (String) -> String = {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        }
    ) -> Self {
        let channel = (infoDictionary["CLIPULSE_CHANNEL"] as? String) == Channel.qa.rawValue
            ? Channel.qa
            : Channel.production
        let bundleIdentifier = infoDictionary["CFBundleIdentifier"] as? String ?? ""
        let fixedUserHome = environment["CFFIXED_USER_HOME"]
        let resolvedFixedUserHome = resolveFixedUserHome(
            fixedUserHome,
            resolvingSymlinks: resolvingSymlinks
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
            "Unsafe QA launch: use a non-production bundle identifier and "
                + "CFFIXED_USER_HOME resolved under \(Self.qaHomeRoot)",
            file: file,
            line: line
        )
    }

    private static func resolveFixedUserHome(
        _ fixedUserHome: String?,
        resolvingSymlinks: (String) -> String
    ) -> String? {
        guard let fixedUserHome, !fixedUserHome.isEmpty else { return nil }

        let resolved = resolvingSymlinks(fixedUserHome)
        guard !resolved.isEmpty, (resolved as NSString).isAbsolutePath else {
            return nil
        }

        return URL(fileURLWithPath: resolved).standardizedFileURL.path
    }
}
