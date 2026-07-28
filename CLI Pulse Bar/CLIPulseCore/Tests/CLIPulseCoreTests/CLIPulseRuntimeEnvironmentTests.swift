import Foundation
import Darwin
import XCTest
@testable import CLIPulseCore

final class CLIPulseRuntimeEnvironmentTests: XCTestCase {
    private static let qaRoot = "/private/tmp/clipulse-qa-home"
    private static let qaBundleIdentifier = "app.clipulse.qa.local"
    private static let qaHelperBundleIdentifier =
        "app.clipulse.qa.local.helper"
    private static let productionBundleIdentifier = "yyh.CLI-Pulse"
    private static let watchBundleIdentifier =
        "yyh.CLI-Pulse.watchkitapp"
    private static let widgetsBundleIdentifier =
        "yyh.CLI-Pulse.widgets"
    private static let helperBundleIdentifier =
        "yyh.CLI-Pulse.helper"
    private typealias FileSystemAccess =
        CLIPulseRuntimeEnvironment.FileSystemAccess
    private typealias PathEntry = FileSystemAccess.PathEntry

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
        XCTAssertTrue(capabilities.allowsBookmarkRestoration)
        XCTAssertTrue(capabilities.allowsPetRestoration)
        XCTAssertTrue(capabilities.allowsHelperManifestRefresh)
        XCTAssertTrue(capabilities.allowsAppUpdateRefresh)
        XCTAssertTrue(capabilities.allowsCurrencyNetworkRefresh)
        XCTAssertTrue(capabilities.allowsCloudSessionRestore)
        XCTAssertTrue(capabilities.allowsBackgroundActivityAssertion)
        XCTAssertTrue(runtime.allowsProductionCloudEndpoints)
    }

    func testProductionLaunchRequiresExactProductionBundleIdentifier() {
        let rejectedBundleIdentifiers: [String?] = [
            nil,
            "",
            Self.qaBundleIdentifier,
            Self.watchBundleIdentifier,
            Self.widgetsBundleIdentifier,
            Self.helperBundleIdentifier,
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

    func testProductionKeychainClientAllowlistDoesNotGrantAppCapabilities() {
        let clientBundleIdentifiers = [
            Self.watchBundleIdentifier,
            Self.widgetsBundleIdentifier,
            Self.helperBundleIdentifier,
        ]

        for bundleIdentifier in clientBundleIdentifiers {
            let runtime = resolve(
                channel: nil,
                bundleIdentifier: bundleIdentifier,
                fixedUserHome: nil
            )

            XCTAssertFalse(
                runtime.isLaunchSafe,
                "\(bundleIdentifier) must not become app launch-safe"
            )
            XCTAssertEqual(
                runtime.keychainService,
                "com.clipulse.app"
            )
            XCTAssertEqual(
                runtime.keychainAccessGroup,
                "group.yyh.CLI-Pulse"
            )
            XCTAssertFalse(runtime.shouldResetQAExperience)
            assertCapabilitiesQuarantined(runtime)
            XCTAssertTrue(
                runtime.allowsProductionCloudEndpoints,
                "\(bundleIdentifier) must retain trusted production cloud configuration"
            )
        }
    }

    func testProductionKeychainClientAllowlistRequiresExactBundleIdentifier() {
        let rejectedBundleIdentifiers: [String?] = [
            nil,
            "",
            "com.example.clipulse",
            "yyh.CLI-Pulse.evil",
            "prefix.yyh.CLI-Pulse.helper",
            Self.helperBundleIdentifier + ".evil",
            Self.watchBundleIdentifier + " ",
            Self.widgetsBundleIdentifier.uppercased(),
            "yyh.CLI-Pulse.Helper",
            "$(PRODUCT_BUNDLE_IDENTIFIER)",
        ]

        for bundleIdentifier in rejectedBundleIdentifiers {
            let runtime = resolve(
                channel: nil,
                bundleIdentifier: bundleIdentifier,
                fixedUserHome: nil
            )

            assertFullyQuarantined(runtime)
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

    func testInvalidProductionFallbackIsFullyQuarantined() {
        let invalidRuntimes = [
            resolve(
                channel: "prodution",
                bundleIdentifier: Self.qaBundleIdentifier
            ),
            resolve(
                channel: nil,
                bundleIdentifier: "com.example.clipulse"
            ),
        ]

        for runtime in invalidRuntimes {
            XCTAssertEqual(runtime.channel, .production)
            assertFullyQuarantined(runtime)
        }
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
        XCTAssertFalse(capabilities.allowsBookmarkRestoration)
        XCTAssertFalse(capabilities.allowsPetRestoration)
        XCTAssertFalse(capabilities.allowsHelperManifestRefresh)
        XCTAssertFalse(capabilities.allowsAppUpdateRefresh)
        XCTAssertFalse(capabilities.allowsCurrencyNetworkRefresh)
        XCTAssertFalse(capabilities.allowsCloudSessionRestore)
        XCTAssertFalse(capabilities.allowsBackgroundActivityAssertion)
        XCTAssertFalse(runtime.allowsProductionCloudEndpoints)
    }

    func testQAResetOnLaunchRequiresExactOne() {
        XCTAssertTrue(
            resolve(
                channel: "qa",
                resetOnLaunch: "1"
            ).shouldResetQAExperience
        )

        let rejectedValues: [String?] = [
            nil,
            "",
            "0",
            "01",
            "true",
            "1 ",
            " 1",
        ]
        for value in rejectedValues {
            XCTAssertFalse(
                resolve(
                    channel: "qa",
                    resetOnLaunch: value
                ).shouldResetQAExperience,
                "expected reset value \(value ?? "nil") to fail closed"
            )
        }
    }

    func testQAResetOnLaunchFailsClosedOutsideLaunchSafeQA() {
        let safeProduction = resolve(
            channel: nil,
            bundleIdentifier: Self.productionBundleIdentifier,
            fixedUserHome: nil,
            resetOnLaunch: "1"
        )
        let invalidQA = resolve(
            channel: "qa",
            bundleIdentifier: Self.productionBundleIdentifier,
            resetOnLaunch: "1"
        )
        let unknownChannel = resolve(
            channel: "preview",
            bundleIdentifier: Self.productionBundleIdentifier,
            fixedUserHome: nil,
            resetOnLaunch: "1"
        )

        XCTAssertTrue(safeProduction.isLaunchSafe)
        XCTAssertFalse(safeProduction.shouldResetQAExperience)
        XCTAssertFalse(invalidQA.isLaunchSafe)
        XCTAssertFalse(invalidQA.shouldResetQAExperience)
        XCTAssertTrue(unknownChannel.isLaunchSafe)
        XCTAssertFalse(unknownChannel.shouldResetQAExperience)
    }

    func testQAHelperUsesQANamespaceWithoutAppCapabilities() {
        let runtime = resolve(
            channel: "qa",
            bundleIdentifier: Self.qaHelperBundleIdentifier,
            fixedUserHome: Self.qaRoot,
            resetOnLaunch: "1"
        )

        XCTAssertEqual(runtime.channel, .qa)
        XCTAssertFalse(runtime.isLaunchSafe)
        XCTAssertEqual(runtime.keychainService, "com.clipulse.app.qa")
        XCTAssertEqual(
            runtime.keychainAccessGroup,
            "group.yyh.CLI-Pulse.qa"
        )
        XCTAssertFalse(runtime.shouldResetQAExperience)
        assertCapabilitiesQuarantined(runtime)
        XCTAssertFalse(runtime.allowsProductionCloudEndpoints)
    }

    func testQAHelperNamespaceRequiresValidatedQARootAndHome() {
        let invalidRuntimes = [
            resolve(
                channel: "qa",
                bundleIdentifier: Self.qaHelperBundleIdentifier,
                fixedUserHome: nil
            ),
            resolve(
                channel: "qa",
                bundleIdentifier: Self.qaHelperBundleIdentifier,
                fixedUserHome: Self.qaRoot + "-evil"
            ),
            resolve(
                channel: "qa",
                bundleIdentifier: Self.qaHelperBundleIdentifier,
                fixedUserHome: Self.qaRoot,
                fileSystem: makeFileSystem(
                    inspectEntry: { path in
                        path == Self.qaRoot ? .missing : .directory
                    }
                )
            ),
            resolve(
                channel: "qa",
                bundleIdentifier: Self.qaHelperBundleIdentifier,
                fixedUserHome: Self.qaRoot,
                fileSystem: makeFileSystem(
                    inspectEntry: { path in
                        path == Self.qaRoot ? .symbolicLink : .directory
                    }
                )
            ),
            resolve(
                channel: "qa",
                bundleIdentifier: "app.clipulse.qa.local.helper.evil",
                fixedUserHome: Self.qaRoot
            ),
        ]

        for runtime in invalidRuntimes {
            assertFullyQuarantined(runtime)
        }
    }

    func testInvalidQAIsFullyQuarantined() {
        let invalidRuntimes = [
            resolve(
                channel: "qa",
                bundleIdentifier: Self.productionBundleIdentifier
            ),
            resolve(
                channel: "qa",
                fixedUserHome: Self.qaRoot + "-evil"
            ),
        ]

        for runtime in invalidRuntimes {
            XCTAssertEqual(runtime.channel, .qa)
            assertFullyQuarantined(runtime)
        }
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
            fileSystem: makeFileSystem(
                inspectEntry: { path in
                    path == link ? .symbolicLink : .directory
                },
                resolveRealPath: {
                    if $0 == Self.qaRoot {
                        return Self.qaRoot
                    }
                    resolvedInput = $0
                    return Self.qaRoot + "/resolved"
                }
            )
        )

        XCTAssertEqual(resolvedInput, link)
        XCTAssertEqual(runtime.resolvedFixedUserHome, Self.qaRoot + "/resolved")
        XCTAssertTrue(runtime.isLaunchSafe)
    }

    func testQALaunchRejectsSymlinkDestinationOutsideRoot() {
        let runtime = resolve(
            channel: "qa",
            fixedUserHome: Self.qaRoot + "/escape",
            fileSystem: makeFileSystem(
                inspectEntry: { path in
                    path == Self.qaRoot + "/escape"
                        ? .symbolicLink
                        : .directory
                },
                resolveRealPath: {
                    if $0 == Self.qaRoot {
                        return Self.qaRoot
                    }
                    return FileManager.default.homeDirectoryForCurrentUser.path
                }
            )
        )

        XCTAssertFalse(runtime.isLaunchSafe)
    }

    func testQALaunchRejectsWhenQARootDoesNotExist() {
        let runtime = resolve(
            channel: "qa",
            fileSystem: makeFileSystem(
                inspectEntry: { path in
                    path == Self.qaRoot ? .missing : .directory
                }
            )
        )

        XCTAssertFalse(runtime.isLaunchSafe)
    }

    func testQALaunchRejectsSymlinkedQARoot() {
        let runtime = resolve(
            channel: "qa",
            fileSystem: makeFileSystem(
                inspectEntry: { path in
                    path == Self.qaRoot ? .symbolicLink : .directory
                },
                resolveRealPath: { path in
                    path == Self.qaRoot ? "/private/tmp/elsewhere" : path
                }
            )
        )

        XCTAssertNil(runtime.resolvedFixedUserHome)
        XCTAssertFalse(runtime.isLaunchSafe)
    }

    func testQALaunchRejectsQARootThatIsNotDirectory() {
        let runtime = resolve(
            channel: "qa",
            fileSystem: makeFileSystem(
                inspectEntry: { path in
                    path == Self.qaRoot ? .other : .directory
                }
            )
        )

        XCTAssertNil(runtime.resolvedFixedUserHome)
        XCTAssertFalse(runtime.isLaunchSafe)
    }

    func testQALaunchRejectsQARootInspectionFailure() {
        let runtime = resolve(
            channel: "qa",
            fileSystem: makeFileSystem(
                inspectEntry: { path in
                    path == Self.qaRoot ? .lookupFailed : .directory
                }
            )
        )

        XCTAssertNil(runtime.resolvedFixedUserHome)
        XCTAssertFalse(runtime.isLaunchSafe)
    }

    func testQALaunchRejectsQARootRealPathFailure() {
        let runtime = resolve(
            channel: "qa",
            fileSystem: makeFileSystem(
                resolveRealPath: { path in
                    path == Self.qaRoot ? nil : path
                }
            )
        )

        XCTAssertNil(runtime.resolvedFixedUserHome)
        XCTAssertFalse(runtime.isLaunchSafe)
    }

    func testQALaunchRejectsHomePathInspectionFailure() {
        let home = Self.qaRoot + "/unreadable"
        let runtime = resolve(
            channel: "qa",
            fixedUserHome: home,
            fileSystem: makeFileSystem(
                inspectEntry: { path in
                    path == home ? .lookupFailed : .directory
                }
            )
        )

        XCTAssertNil(runtime.resolvedFixedUserHome)
        XCTAssertFalse(runtime.isLaunchSafe)
    }

    func testQALaunchRejectsHomePathRealPathFailure() {
        let home = Self.qaRoot + "/unresolvable-link"
        let runtime = resolve(
            channel: "qa",
            fixedUserHome: home,
            fileSystem: makeFileSystem(
                inspectEntry: { path in
                    path == home ? .symbolicLink : .directory
                },
                resolveRealPath: { path in
                    path == home ? nil : path
                }
            )
        )

        XCTAssertNil(runtime.resolvedFixedUserHome)
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
        resetOnLaunch: String? = nil,
        fileSystem: FileSystemAccess? = nil
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
        if let resetOnLaunch {
            environment["CLIPULSE_QA_RESET_ON_LAUNCH"] = resetOnLaunch
        }

        return CLIPulseRuntimeEnvironment.resolveForTesting(
            infoDictionary: infoDictionary,
            environment: environment,
            fileSystem: fileSystem ?? makeFileSystem()
        )
    }

    private func makeFileSystem(
        inspectEntry: @escaping (String) -> PathEntry = { _ in .directory },
        resolveRealPath: @escaping (String) -> String? = { $0 }
    ) -> FileSystemAccess {
        FileSystemAccess(
            inspectEntry: inspectEntry,
            resolveRealPath: resolveRealPath
        )
    }

    private func assertFullyQuarantined(
        _ runtime: CLIPulseRuntimeEnvironment,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            runtime.isLaunchSafe,
            "preconditionSafeLaunch must reject an invalid runtime",
            file: file,
            line: line
        )
        XCTAssertEqual(
            runtime.keychainService,
            "com.clipulse.app.quarantine",
            file: file,
            line: line
        )
        XCTAssertEqual(
            runtime.keychainAccessGroup,
            "group.yyh.CLI-Pulse.quarantine",
            file: file,
            line: line
        )
        XCTAssertFalse(
            runtime.allowsProductionCloudEndpoints,
            "unknown clients must not receive production cloud configuration",
            file: file,
            line: line
        )

        assertCapabilitiesQuarantined(
            runtime,
            file: file,
            line: line
        )
    }

    private func assertCapabilitiesQuarantined(
        _ runtime: CLIPulseRuntimeEnvironment,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let capabilities = runtime.capabilities
        let capabilityStates: [(name: String, isEnabled: Bool)] = [
            ("telemetry", capabilities.allowsTelemetry),
            ("unsandboxed migration", capabilities.allowsUnsandboxedMigration),
            ("helper registration", capabilities.allowsHelperRegistration),
            ("permission snapshot", capabilities.allowsPermissionSnapshot),
            ("StoreKit bootstrap", capabilities.allowsStoreKitBootstrap),
            ("live collection", capabilities.allowsLiveCollection),
            ("widget publishing", capabilities.allowsWidgetPublishing),
            (
                "legacy production cloud capability",
                capabilities.allowsProductionCloudEndpoints
            ),
            ("passive discovery", capabilities.allowsPassiveDiscovery),
            (
                "in-memory demo rendering",
                capabilities.allowsInMemoryDemoRendering
            ),
            ("bookmark restoration", capabilities.allowsBookmarkRestoration),
            ("pet restoration", capabilities.allowsPetRestoration),
            (
                "helper manifest refresh",
                capabilities.allowsHelperManifestRefresh
            ),
            ("app update refresh", capabilities.allowsAppUpdateRefresh),
            (
                "currency network refresh",
                capabilities.allowsCurrencyNetworkRefresh
            ),
            ("cloud session restore", capabilities.allowsCloudSessionRestore),
            (
                "background activity assertion",
                capabilities.allowsBackgroundActivityAssertion
            ),
        ]

        for capability in capabilityStates {
            XCTAssertFalse(
                capability.isEnabled,
                "\(capability.name) must be disabled for an invalid runtime",
                file: file,
                line: line
            )
        }
    }

    private func resolveUsingDefaultFileSystem(
        fixedUserHome: String
    ) -> CLIPulseRuntimeEnvironment {
        CLIPulseRuntimeEnvironment.resolveForTesting(
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
