@testable import CLIPulseCore

enum TestRuntimeFixtures {
    static var productionApp: CLIPulseRuntimeEnvironment {
        CLIPulseRuntimeEnvironment.resolveForTesting(
            infoDictionary: [
                "CFBundleIdentifier": "yyh.CLI-Pulse",
            ],
            environment: [:]
        )
    }
}
