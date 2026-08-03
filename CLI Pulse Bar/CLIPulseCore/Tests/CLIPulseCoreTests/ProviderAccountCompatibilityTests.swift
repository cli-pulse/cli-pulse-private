import Foundation
import XCTest
@testable import CLIPulseCore

#if os(macOS)

final class ProviderAccountCompatibilityTests: XCTestCase {

    func testLegacyProviderUsageDecodesWithoutAccountFields() throws {
        let json = """
        {
          "provider": "Claude",
          "today_usage": 12,
          "week_usage": 34,
          "estimated_cost_today": 0,
          "estimated_cost_week": 0,
          "estimated_cost_30_day": 0,
          "cost_status_today": "Unavailable",
          "cost_status_week": "Unavailable",
          "quota": 100,
          "remaining": 88,
          "plan_type": "Pro",
          "reset_time": "2026-07-24T12:00:00Z",
          "tiers": [],
          "status_text": "12% used",
          "trend": [],
          "recent_sessions": [],
          "recent_errors": []
        }
        """

        let usage = try JSONDecoder().decode(ProviderUsage.self, from: Data(json.utf8))

        XCTAssertEqual(usage.provider, "Claude")
        XCTAssertEqual(usage.id, "Claude")
        XCTAssertEqual(usage.remaining, 88)
    }

    func testHelperIPCV1ProviderDictionaryStillReads() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: HelperIPC.suiteName))
        let previous = defaults.data(forKey: HelperIPC.collectorResultsKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: HelperIPC.collectorResultsKey)
            } else {
                defaults.removeObject(forKey: HelperIPC.collectorResultsKey)
            }
        }

        let payload: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "providers": [
                "Claude": [
                    "quota": 100,
                    "remaining": 64,
                    "today_usage": 36,
                    "week_usage": 52,
                    "plan_type": "Pro",
                    "status_text": "36% used",
                    "tiers": [],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        HelperIPC.writeCollectorResults(data)

        let results = DataRefreshManager.readHelperCollectorResults()

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.usage.provider, "Claude")
        XCTAssertEqual(results.first?.usage.remaining, 64)
        XCTAssertEqual(results.first?.usage.plan_type, "Pro")
    }
}

#endif
