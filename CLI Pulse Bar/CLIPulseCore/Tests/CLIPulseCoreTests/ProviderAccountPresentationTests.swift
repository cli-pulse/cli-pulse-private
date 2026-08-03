import XCTest
@testable import CLIPulseCore

final class ProviderAccountPresentationTests: XCTestCase {
    func testGroupsFollowProviderOrderAndSortNamedAccounts() throws {
        let codexID = try XCTUnwrap(
            UUID(uuidString: "11111111-1111-4111-8111-111111111111")
        )
        let workID = try XCTUnwrap(
            UUID(uuidString: "33333333-3333-4333-8333-333333333333")
        )
        let personalID = try XCTUnwrap(
            UUID(uuidString: "22222222-2222-4222-8222-222222222222")
        )

        let groups = ProviderAccountPresentation.groups([
            makeAccount(
                id: workID,
                provider: .claude,
                label: "Work"
            ),
            makeAccount(
                id: codexID,
                provider: .codex,
                label: nil
            ),
            makeAccount(
                id: personalID,
                provider: .claude,
                label: "Personal"
            ),
        ])

        XCTAssertEqual(groups.map(\.provider), [.codex, .claude])
        XCTAssertEqual(
            groups[1].accounts.map(\.id),
            [personalID, workID]
        )
    }

    func testUnnamedAccountsSortAfterNamedAccountsThenByStableID() throws {
        let firstUnnamedID = try XCTUnwrap(
            UUID(uuidString: "11111111-1111-4111-8111-111111111111")
        )
        let secondUnnamedID = try XCTUnwrap(
            UUID(uuidString: "22222222-2222-4222-8222-222222222222")
        )
        let namedID = try XCTUnwrap(
            UUID(uuidString: "99999999-9999-4999-8999-999999999999")
        )

        let group = try XCTUnwrap(
            ProviderAccountPresentation.groups([
                makeAccount(
                    id: secondUnnamedID,
                    provider: .gemini,
                    label: " "
                ),
                makeAccount(
                    id: namedID,
                    provider: .gemini,
                    label: "Primary"
                ),
                makeAccount(
                    id: firstUnnamedID,
                    provider: .gemini,
                    label: nil
                ),
            ]).first
        )

        XCTAssertEqual(
            group.accounts.map(\.id),
            [namedID, firstUnnamedID, secondUnnamedID]
        )
    }

    func testGroupsExcludingRepresentedProvidersKeepsAccountOnlyCloudData() {
        let accounts = [
            makeAccount(
                id: UUID(),
                provider: .claude,
                label: "Work"
            ),
            makeAccount(
                id: UUID(),
                provider: .codex,
                label: "Personal"
            ),
        ]

        let accountOnlyGroups = ProviderAccountPresentation.groups(
            accounts,
            excluding: [.claude]
        )

        XCTAssertEqual(
            accountOnlyGroups.map(\.provider),
            [.codex]
        )
        XCTAssertEqual(
            accountOnlyGroups.first?.accounts.map(\.accountLabel),
            ["Personal"]
        )
    }

    func testFreshnessUsesQuotaObservationBeforePlanEvidence() throws {
        let planDate = try XCTUnwrap(
            sharedISO8601Parse("2026-07-24T10:00:00Z")
        )
        let account = makeAccount(
            id: UUID(),
            provider: .claude,
            label: "Work",
            observedAt: "2026-07-24T09:00:00Z",
            planObservedAt: planDate
        )

        XCTAssertEqual(
            ProviderAccountPresentation.freshnessTimestamp(
                for: account
            ),
            "2026-07-24T09:00:00Z"
        )
    }

    func testFreshnessFallsBackToPlanEvidenceAndLatestIsSelected() throws {
        let olderPlanDate = try XCTUnwrap(
            sharedISO8601Parse("2026-07-24T08:00:00Z")
        )
        let accounts = [
            makeAccount(
                id: UUID(),
                provider: .claude,
                label: "Personal",
                planObservedAt: olderPlanDate
            ),
            makeAccount(
                id: UUID(),
                provider: .claude,
                label: "Work",
                observedAt: "2026-07-24T11:30:00Z"
            ),
        ]

        XCTAssertEqual(
            ProviderAccountPresentation.freshnessTimestamp(
                for: accounts[0]
            ),
            "2026-07-24T08:00:00Z"
        )
        XCTAssertEqual(
            ProviderAccountPresentation.latestFreshnessTimestamp(
                in: accounts
            ),
            "2026-07-24T11:30:00Z"
        )
    }

    private func makeAccount(
        id: UUID,
        provider: ProviderKind,
        label: String?,
        observedAt: String? = nil,
        planObservedAt: Date? = nil
    ) -> ProviderAccountUsage {
        ProviderAccountUsage(
            id: id,
            provider: provider,
            accountLabel: label,
            planEvidence: ProviderPlanEvidence(
                rawValue: "pro",
                displayValue: "Pro",
                source: .providerAPI,
                confidence: .high,
                observedAt: planObservedAt
            ),
            quota: 100,
            remaining: 50,
            tiers: [],
            resetTime: nil,
            observedAt: observedAt,
            sourceDeviceID: nil,
            statusText: "Operational"
        )
    }
}
