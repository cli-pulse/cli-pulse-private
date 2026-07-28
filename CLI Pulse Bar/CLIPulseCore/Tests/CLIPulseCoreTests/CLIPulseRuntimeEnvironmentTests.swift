import Foundation
import XCTest
@testable import CLIPulseCore

final class CLIPulseRuntimeEnvironmentTests: XCTestCase {
    private static let qaRoot = "/private/tmp/clipulse-qa-home"
    private static let qaBundleIdentifier = "app.clipulse.qa.local"

    func testAbsentAndUnknownChannelsResolveToProduction() {
        let absent = resolve(channel: nil)
        let unknown = resolve(channel: "preview")

        XCTAssertEqual(absent.channel, .production)
        XCTAssertEqual(unknown.channel, .production)
        XCTAssertFalse(absent.isQA)
        XCTAssertFalse(unknown.isQA)
    }

    func testProductionRetainsExistingNamespacesAndCapabilities() {
        let runtime = resolve(channel: nil)

        XCTAssertEqual(runtime.keychainService, "com.clipulse.app")
        XCTAssertEqual(runtime.keychainAccessGroup, "group.yyh.CLI-Pulse")
        XCTAssertTrue(runtime.isLaunchSafe)

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
        root.preconditionSafeLaunch()
        descendant.preconditionSafeLaunch()
    }

    func testQALaunchRequiresNonProductionBundleIdentifier() {
        let runtime = resolve(
            channel: "qa",
            bundleIdentifier: "yyh.CLI-Pulse"
        )

        XCTAssertFalse(runtime.isLaunchSafe)
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
            resolvingSymlinks: { _ in
                FileManager.default.homeDirectoryForCurrentUser.path
            }
        )

        XCTAssertFalse(runtime.isLaunchSafe)
    }

    private func resolve(
        channel: String?,
        bundleIdentifier: String = qaBundleIdentifier,
        fixedUserHome: String? = qaRoot,
        resolvingSymlinks: (String) -> String = { $0 }
    ) -> CLIPulseRuntimeEnvironment {
        var infoDictionary: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
        ]
        if let channel {
            infoDictionary["CLIPULSE_CHANNEL"] = channel
        }

        var environment: [String: String] = [:]
        if let fixedUserHome {
            environment["CFFIXED_USER_HOME"] = fixedUserHome
        }

        return CLIPulseRuntimeEnvironment.resolve(
            infoDictionary: infoDictionary,
            environment: environment,
            resolvingSymlinks: resolvingSymlinks
        )
    }
}
