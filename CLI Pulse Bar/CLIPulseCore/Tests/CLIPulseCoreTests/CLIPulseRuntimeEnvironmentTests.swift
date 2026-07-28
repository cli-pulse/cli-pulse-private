import Foundation
import Darwin
import XCTest
@testable import CLIPulseCore

final class CLIPulseRuntimeEnvironmentTests: XCTestCase {
    private static let qaRoot = "/private/tmp/clipulse-qa-home"
    private static let qaBundleIdentifier = "app.clipulse.qa.local"
    private static let productionBundleIdentifier = "yyh.CLI-Pulse"

    func testAbsentAndUnknownChannelsResolveToProduction() {
        let absent = resolve(channel: nil)
        let unknown = resolve(channel: "preview")

        XCTAssertEqual(absent.channel, .production)
        XCTAssertEqual(unknown.channel, .production)
        XCTAssertFalse(absent.isQA)
        XCTAssertFalse(unknown.isQA)
    }

    func testProductionRetainsExistingNamespacesAndCapabilities() {
        let runtime = resolve(
            channel: nil,
            bundleIdentifier: Self.productionBundleIdentifier
        )

        XCTAssertEqual(runtime.keychainService, "com.clipulse.app")
        XCTAssertEqual(runtime.keychainAccessGroup, "group.yyh.CLI-Pulse")
        XCTAssertTrue(runtime.isLaunchSafe)
        runtime.preconditionSafeLaunch()

        let capabilities = runtime.capabilities
        XCTAssertTrue(capabilities.allowsTelemetry)
        XCTAssertTrue(capabilities.allowsUnsandboxedMigration)
        XCTAssertTrue(capabilities.allowsHelperRegistration)
        XCTAssertTrue(capabilities.allowsPermissionSnapshot)
        XCTAssertTrue(capabilities.allowsStoreKitBootstrap)
        XCTAssertTrue(capabilities.allowsLiveCollection)
        XCTAssertTrue(capabilities.allowsWidgetPublishing)
        XCTAssertTrue(capabilities.allowsProductionCloudEndpoints)
        XCTAssertTrue(capabilities.allowsPassiveDiscovery)
        XCTAssertTrue(capabilities.allowsInMemoryDemoRendering)
    }

    func testProductionLaunchRequiresExactProductionBundleIdentifier() {
        let rejectedBundleIdentifiers: [String?] = [
            nil,
            "",
            Self.qaBundleIdentifier,
            "com.example.clipulse",
            "YYH.CLI-Pulse",
            "yyh.cli-pulse",
            Self.productionBundleIdentifier + " ",
            "$(PRODUCT_BUNDLE_IDENTIFIER)",
        ]

        for bundleIdentifier in rejectedBundleIdentifiers {
            let runtime = resolve(
                channel: nil,
                bundleIdentifier: bundleIdentifier
            )
            XCTAssertFalse(
                runtime.isLaunchSafe,
                "expected bundle \(bundleIdentifier ?? "nil") to fail closed"
            )
        }
    }

    func testUnknownChannelStaysProductionButRejectsNonProductionBundle() {
        let mismatched = resolve(
            channel: "prodution",
            bundleIdentifier: Self.qaBundleIdentifier
        )
        let matched = resolve(
            channel: "prodution",
            bundleIdentifier: Self.productionBundleIdentifier
        )

        XCTAssertEqual(mismatched.channel, .production)
        XCTAssertFalse(mismatched.isLaunchSafe)
        XCTAssertEqual(matched.channel, .production)
        XCTAssertTrue(matched.isLaunchSafe)
    }

    func testQAUsesIsolatedNamespacesAndRestrictedCapabilities() {
        let runtime = resolve(channel: "qa")

        XCTAssertEqual(runtime.channel, .qa)
        XCTAssertTrue(runtime.isQA)
        XCTAssertEqual(runtime.keychainService, "com.clipulse.app.qa")
        XCTAssertEqual(runtime.keychainAccessGroup, "group.yyh.CLI-Pulse.qa")

        let capabilities = runtime.capabilities
        XCTAssertFalse(capabilities.allowsTelemetry)
        XCTAssertFalse(capabilities.allowsUnsandboxedMigration)
        XCTAssertFalse(capabilities.allowsHelperRegistration)
        XCTAssertFalse(capabilities.allowsPermissionSnapshot)
        XCTAssertFalse(capabilities.allowsStoreKitBootstrap)
        XCTAssertFalse(capabilities.allowsLiveCollection)
        XCTAssertFalse(capabilities.allowsWidgetPublishing)
        XCTAssertFalse(capabilities.allowsProductionCloudEndpoints)
        XCTAssertTrue(capabilities.allowsPassiveDiscovery)
        XCTAssertTrue(capabilities.allowsInMemoryDemoRendering)
    }

    func testQALaunchIsSafeAtRootAndWithinDescendant() {
        let root = resolve(channel: "qa", fixedUserHome: Self.qaRoot)
        let descendant = resolve(
            channel: "qa",
            fixedUserHome: Self.qaRoot + "/runs/manual"
        )

        XCTAssertTrue(root.isLaunchSafe)
        XCTAssertTrue(descendant.isLaunchSafe)
        if root.isLaunchSafe {
            root.preconditionSafeLaunch()
        }
        if descendant.isLaunchSafe {
            descendant.preconditionSafeLaunch()
        }
    }

    func testQALaunchRequiresExactQABundleIdentifier() {
        let rejectedBundleIdentifiers: [String?] = [
            nil,
            "",
            Self.productionBundleIdentifier,
            "com.example.clipulse.qa",
            "APP.clipulse.qa.local",
            Self.qaBundleIdentifier + " ",
            "$(PRODUCT_BUNDLE_IDENTIFIER)",
        ]

        for bundleIdentifier in rejectedBundleIdentifiers {
            let runtime = resolve(
                channel: "qa",
                bundleIdentifier: bundleIdentifier
            )
            XCTAssertFalse(
                runtime.isLaunchSafe,
                "expected bundle \(bundleIdentifier ?? "nil") to fail closed"
            )
        }
    }

    func testQALaunchRejectsMissingEmptyRootRealHomeAndPrefixSpoof() {
        let rejectedHomes: [String?] = [
            nil,
            "",
            "/",
            FileManager.default.homeDirectoryForCurrentUser.path,
            Self.qaRoot + "-evil",
        ]

        for fixedUserHome in rejectedHomes {
            let runtime = resolve(
                channel: "qa",
                fixedUserHome: fixedUserHome
            )
            XCTAssertFalse(
                runtime.isLaunchSafe,
                "expected fixed home \(fixedUserHome ?? "nil") to fail closed"
            )
        }
    }

    func testQALaunchUsesResolvedSymlinkDestinationInsideRoot() {
        let link = "/private/tmp/clipulse-qa-link"
        var resolvedInput: String?

        let runtime = resolve(
            channel: "qa",
            fixedUserHome: link,
            resolvingSymlinks: {
                if $0 == Self.qaRoot {
                    return Self.qaRoot
                }
                resolvedInput = $0
                return Self.qaRoot + "/resolved"
            }
        )

        XCTAssertEqual(resolvedInput, link)
        XCTAssertEqual(runtime.resolvedFixedUserHome, Self.qaRoot + "/resolved")
        XCTAssertTrue(runtime.isLaunchSafe)
    }

    func testQALaunchRejectsSymlinkDestinationOutsideRoot() {
        let runtime = resolve(
            channel: "qa",
            fixedUserHome: Self.qaRoot + "/escape",
            resolvingSymlinks: {
                if $0 == Self.qaRoot {
                    return Self.qaRoot
                }
                return FileManager.default.homeDirectoryForCurrentUser.path
            }
        )

        XCTAssertFalse(runtime.isLaunchSafe)
    }

    func testQALaunchRejectsWhenQARootDoesNotExist() {
        let runtime = resolve(
            channel: "qa",
            pathEntryExists: { path in
                path != Self.qaRoot
            }
        )

        XCTAssertFalse(runtime.isLaunchSafe)
    }

    func testDefaultResolverRejectsMissingDescendantThroughEscapingSymlink() throws {
        let fileManager = FileManager.default
        let identifier = UUID().uuidString
        let qaFixture = try makeQAFixtureDirectory(identifier: identifier)
        defer { try? fileManager.removeItem(at: qaFixture) }

        let outsideFixture = URL(
            fileURLWithPath: "/private/tmp/clipulse-qa-outside-\(identifier)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: outsideFixture,
            withIntermediateDirectories: false
        )
        defer { try? fileManager.removeItem(at: outsideFixture) }

        let escape = qaFixture.appendingPathComponent("escape")
        try fileManager.createSymbolicLink(
            at: escape,
            withDestinationURL: outsideFixture
        )

        let runtime = resolveUsingDefaultFileSystem(
            fixedUserHome: escape.appendingPathComponent("missing").path
        )

        XCTAssertFalse(runtime.isLaunchSafe)
    }

    func testDefaultResolverAllowsMissingDescendantBelowExistingQADirectory() throws {
        let fileManager = FileManager.default
        let identifier = UUID().uuidString
        let qaFixture = try makeQAFixtureDirectory(identifier: identifier)
        defer { try? fileManager.removeItem(at: qaFixture) }

        let existingAncestor = qaFixture.appendingPathComponent(
            "existing",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: existingAncestor,
            withIntermediateDirectories: false
        )

        let runtime = resolveUsingDefaultFileSystem(
            fixedUserHome: existingAncestor
                .appendingPathComponent("missing/descendant")
                .path
        )

        XCTAssertTrue(runtime.isLaunchSafe)
    }

    func testDefaultResolverRejectsBrokenSymlinkAncestor() throws {
        let fileManager = FileManager.default
        let identifier = UUID().uuidString
        let qaFixture = try makeQAFixtureDirectory(identifier: identifier)
        defer { try? fileManager.removeItem(at: qaFixture) }

        let brokenLink = qaFixture.appendingPathComponent("broken")
        try fileManager.createSymbolicLink(
            atPath: brokenLink.path,
            withDestinationPath: "/private/tmp/clipulse-qa-missing-\(identifier)"
        )

        let runtime = resolveUsingDefaultFileSystem(
            fixedUserHome: brokenLink.appendingPathComponent("missing").path
        )

        XCTAssertFalse(runtime.isLaunchSafe)
    }

    private func resolve(
        channel: String?,
        bundleIdentifier: String? = qaBundleIdentifier,
        fixedUserHome: String? = qaRoot,
        resolvingSymlinks: @escaping (String) -> String? = { $0 },
        pathEntryExists: @escaping (String) -> Bool = { _ in true }
    ) -> CLIPulseRuntimeEnvironment {
        var infoDictionary: [String: Any] = [:]
        if let channel {
            infoDictionary["CLIPULSE_CHANNEL"] = channel
        }
        if let bundleIdentifier {
            infoDictionary["CFBundleIdentifier"] = bundleIdentifier
        }

        var environment: [String: String] = [:]
        if let fixedUserHome {
            environment["CFFIXED_USER_HOME"] = fixedUserHome
        }

        return CLIPulseRuntimeEnvironment.resolve(
            infoDictionary: infoDictionary,
            environment: environment,
            resolvingSymlinks: resolvingSymlinks,
            pathEntryExists: pathEntryExists
        )
    }

    private func resolveUsingDefaultFileSystem(
        fixedUserHome: String
    ) -> CLIPulseRuntimeEnvironment {
        CLIPulseRuntimeEnvironment.resolve(
            infoDictionary: [
                "CLIPULSE_CHANNEL": "qa",
                "CFBundleIdentifier": Self.qaBundleIdentifier,
            ],
            environment: [
                "CFFIXED_USER_HOME": fixedUserHome,
            ]
        )
    }

    private func makeQAFixtureDirectory(identifier: String) throws -> URL {
        try ensureQARootDirectory()

        let fixture = URL(
            fileURLWithPath: Self.qaRoot,
            isDirectory: true
        ).appendingPathComponent(identifier, isDirectory: true)
        try FileManager.default.createDirectory(
            at: fixture,
            withIntermediateDirectories: false
        )
        return fixture
    }

    private func ensureQARootDirectory() throws {
        var metadata = stat()
        let status = Self.qaRoot.withCString {
            Darwin.lstat($0, &metadata)
        }

        if status == 0 {
            guard metadata.st_mode & S_IFMT == S_IFDIR else {
                throw NSError(
                    domain: "CLIPulseRuntimeEnvironmentTests",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "QA root exists but is not a physical directory",
                    ]
                )
            }
            return
        }

        guard errno == ENOENT else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        try FileManager.default.createDirectory(
            atPath: Self.qaRoot,
            withIntermediateDirectories: false
        )
    }
}
