import Foundation
import XCTest
@testable import CLIPulseCore

final class RuntimeCloudConfigurationTests: XCTestCase {
    private static let qaRoot = "/private/tmp/clipulse-qa-home"
    private static let productionBundleIdentifiers = [
        "yyh.CLI-Pulse",
        "yyh.CLI-Pulse.watchkitapp",
        "yyh.CLI-Pulse.widgets",
        "yyh.CLI-Pulse.helper",
    ]

    func testProductionCloudAllowlistIsExactAndIndependentOfLaunchSafety() {
        for bundleIdentifier in Self.productionBundleIdentifiers {
            let runtime = makeRuntime(
                channel: nil,
                bundleIdentifier: bundleIdentifier
            )

            XCTAssertTrue(
                runtime.allowsProductionCloudEndpoints,
                "\(bundleIdentifier) must retain production cloud configuration"
            )
            XCTAssertEqual(
                runtime.isLaunchSafe,
                bundleIdentifier == "yyh.CLI-Pulse",
                "cloud authorization must not make Watch/widgets/helper app-launch safe"
            )
        }

        for bundleIdentifier in [
            "",
            "yyh.CLI-Pulse.evil",
            "prefix.yyh.CLI-Pulse.helper",
            "YYH.CLI-Pulse",
            "com.example.clipulse",
        ] {
            XCTAssertFalse(
                makeRuntime(
                    channel: nil,
                    bundleIdentifier: bundleIdentifier
                ).allowsProductionCloudEndpoints,
                "\(bundleIdentifier) must fail closed"
            )
        }
    }

    func testTrustedProductionResolverPreservesInfoEnvironmentDefaultOrder() {
        let runtime = makeRuntime(
            channel: nil,
            bundleIdentifier: "yyh.CLI-Pulse"
        )

        XCTAssertEqual(
            RuntimeCloudConfiguration.resolve(
                runtimeEnvironment: runtime,
                explicitURL: nil,
                explicitAnonKey: nil,
                infoDictionary: [
                    "SUPABASE_URL": "https://info.example",
                    "SUPABASE_ANON_KEY": "info-key",
                ],
                environment: [
                    "CLI_PULSE_SUPABASE_URL": "https://env.example",
                    "CLI_PULSE_SUPABASE_ANON_KEY": "env-key",
                ]
            ),
            RuntimeCloudConfiguration(
                url: "https://info.example",
                anonKey: "info-key"
            )
        )

        XCTAssertEqual(
            RuntimeCloudConfiguration.resolve(
                runtimeEnvironment: runtime,
                explicitURL: nil,
                explicitAnonKey: nil,
                infoDictionary: [:],
                environment: [
                    "CLI_PULSE_SUPABASE_URL": "https://env.example",
                    "CLI_PULSE_SUPABASE_ANON_KEY": "env-key",
                ]
            ),
            RuntimeCloudConfiguration(
                url: "https://env.example",
                anonKey: "env-key"
            )
        )

        XCTAssertEqual(
            RuntimeCloudConfiguration.resolve(
                runtimeEnvironment: runtime,
                explicitURL: nil,
                explicitAnonKey: nil,
                infoDictionary: [:],
                environment: [:]
            ),
            RuntimeCloudConfiguration(
                url: "https://gkjwsxotmwrgqsvfijzs.supabase.co",
                anonKey: ""
            )
        )
    }

    func testQAAndUnknownClientsIgnoreProductionInfoAndEnvironment() {
        let runtimes = [
            makeRuntime(
                channel: "qa",
                bundleIdentifier: "app.clipulse.qa.local",
                fixedUserHome: Self.qaRoot
            ),
            makeRuntime(
                channel: "qa",
                bundleIdentifier: "app.clipulse.qa.local.helper",
                fixedUserHome: Self.qaRoot
            ),
            makeRuntime(
                channel: nil,
                bundleIdentifier: "com.example.clipulse"
            ),
        ]

        for runtime in runtimes {
            let configuration = RuntimeCloudConfiguration.resolve(
                runtimeEnvironment: runtime,
                explicitURL: nil,
                explicitAnonKey: nil,
                infoDictionary: [
                    "SUPABASE_URL": "https://production-info.example",
                    "SUPABASE_ANON_KEY": "production-info-key",
                ],
                environment: [
                    "CLI_PULSE_SUPABASE_URL": "https://production-env.example",
                    "CLI_PULSE_SUPABASE_ANON_KEY": "production-env-key",
                ]
            )

            XCTAssertEqual(configuration.url, "http://127.0.0.1:0")
            XCTAssertEqual(configuration.anonKey, "qa-local-invalid-anon-key")
        }
    }

    func testExplicitOverridesWinIndependentlyForQAAPIClient() async {
        let runtime = makeRuntime(
            channel: "qa",
            bundleIdentifier: "app.clipulse.qa.local",
            fixedUserHome: Self.qaRoot
        )

        let explicitURL = APIClient(
            supabaseURL: "https://explicit.example",
            runtimeEnvironment: runtime
        )
        let explicitURLConfiguration = await explicitURL.realtimeConfiguration()
        XCTAssertEqual(
            explicitURLConfiguration.supabaseURL,
            "https://explicit.example"
        )
        XCTAssertEqual(
            explicitURLConfiguration.supabaseAnonKey,
            "qa-local-invalid-anon-key"
        )

        let explicitKey = APIClient(
            supabaseAnonKey: "explicit-key",
            runtimeEnvironment: runtime
        )
        let explicitKeyConfiguration = await explicitKey.realtimeConfiguration()
        XCTAssertEqual(
            explicitKeyConfiguration.supabaseURL,
            "http://127.0.0.1:0"
        )
        XCTAssertEqual(
            explicitKeyConfiguration.supabaseAnonKey,
            "explicit-key"
        )
    }

    private func makeRuntime(
        channel: String?,
        bundleIdentifier: String,
        fixedUserHome: String? = nil
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

        return CLIPulseRuntimeEnvironment.resolveForTesting(
            infoDictionary: infoDictionary,
            environment: environment,
            fileSystem: .init(
                inspectEntry: { path in
                    path == Self.qaRoot ? .directory : .missing
                },
                resolveRealPath: { $0 }
            )
        )
    }
}
