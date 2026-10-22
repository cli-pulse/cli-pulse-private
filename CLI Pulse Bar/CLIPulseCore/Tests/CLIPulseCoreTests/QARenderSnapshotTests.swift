import XCTest
@testable import CLIPulseCore

/// The plan behind the QA build's offscreen renders. The renderer that draws
/// the views lives in the app target and is compiled only into `Debug QA`, so
/// everything it relies on that can be tested without a window is here.
final class QARenderSnapshotTests: XCTestCase {

    // MARK: - Who may render

    private static let qaHome = "/private/tmp/clipulse-qa-home/render-ja"

    private func runtime(
        channel: String = "qa",
        bundleIdentifier: String = "app.clipulse.qa.local",
        fixedHome: String? = QARenderSnapshotTests.qaHome
    ) -> CLIPulseRuntimeEnvironment {
        var environment: [String: String] = [:]
        environment["CFFIXED_USER_HOME"] = fixedHome
        return CLIPulseRuntimeEnvironment.resolveForTesting(
            infoDictionary: [
                "CLIPULSE_CHANNEL": channel,
                "CFBundleIdentifier": bundleIdentifier,
            ],
            environment: environment,
            fileSystem: .init(
                inspectEntry: { $0 == Self.qaHome ? .missing : .directory },
                resolveRealPath: { $0 },
                isPrivateDirectoryOwnedByCurrentUser: { _ in true }
            )
        )
    }

    private func arguments(
        output: String? = "/tmp/renders/ja",
        language: String? = "ja",
        appleLanguages: String? = "(ja)",
        extra: [String] = []
    ) -> [String] {
        var arguments = ["/Applications/CLIPulse QA.app/Contents/MacOS/CLIPulse QA"]
        if let output { arguments += ["-CLIPulseRenderSnapshots", output] }
        if let appleLanguages { arguments += ["-AppleLanguages", appleLanguages] }
        if let language { arguments += ["-cli_pulse_locale_override", language] }
        return arguments + extra
    }

    private func refusal(_ resolution: QARenderSnapshot.Resolution) -> String? {
        if case .refused(let reason) = resolution { return reason }
        return nil
    }

    func testTheQARuntimeFixtureIsLaunchSafe() {
        let qa = runtime()
        XCTAssertTrue(qa.isQA)
        XCTAssertTrue(qa.isLaunchSafe, "the fixture must be a real QA launch, or every test below proves nothing")
    }

    func testNoRenderArgumentMeansAnOrdinaryLaunch() {
        XCTAssertEqual(
            QARenderSnapshot.resolve(arguments: arguments(output: nil), runtime: runtime()),
            .notRequested
        )
        // Nothing else matters when the render was not asked for, including a
        // production runtime: that app must start exactly as before.
        XCTAssertEqual(
            QARenderSnapshot.resolve(
                arguments: ["/Applications/CLI Pulse Bar.app/Contents/MacOS/CLI Pulse Bar"],
                runtime: TestRuntimeFixtures.productionApp
            ),
            .notRequested
        )
    }

    func testAValidQALaunchRenders() {
        let resolution = QARenderSnapshot.resolve(arguments: arguments(), runtime: runtime())
        XCTAssertEqual(resolution, .render(.init(
            outputDirectory: URL(fileURLWithPath: "/tmp/renders/ja", isDirectory: true),
            language: "ja",
            appearance: .light
        )))
    }

    func testAppleLanguagesMayListFallbacksAfterTheRenderedLanguage() {
        let resolution = QARenderSnapshot.resolve(
            arguments: arguments(language: "zh-Hant", appleLanguages: "(\"zh-Hant\", en)"),
            runtime: runtime()
        )
        guard case .render(let request) = resolution else {
            return XCTFail("expected a render, got \(resolution)")
        }
        XCTAssertEqual(request.language, "zh-Hant")
    }

    func testDarkAppearanceIsOptional() {
        let resolution = QARenderSnapshot.resolve(
            arguments: arguments(extra: ["-CLIPulseRenderAppearance", "dark"]),
            runtime: runtime()
        )
        guard case .render(let request) = resolution else {
            return XCTFail("expected a render, got \(resolution)")
        }
        XCTAssertEqual(request.appearance, .dark)
        XCTAssertNotNil(refusal(QARenderSnapshot.resolve(
            arguments: arguments(extra: ["-CLIPulseRenderAppearance", "sepia"]),
            runtime: runtime()
        )))
    }

    func testProductionAndQuarantinedBuildsRefuse() {
        XCTAssertNotNil(refusal(QARenderSnapshot.resolve(
            arguments: arguments(), runtime: TestRuntimeFixtures.productionApp
        )), "a Release build that somehow reached this code must still refuse")
        XCTAssertNotNil(refusal(QARenderSnapshot.resolve(
            arguments: arguments(), runtime: runtime(fixedHome: nil)
        )), "QA without its isolated home is quarantined, and must not render")
        XCTAssertNotNil(refusal(QARenderSnapshot.resolve(
            arguments: arguments(), runtime: runtime(fixedHome: "/Users/someone")
        )))
        XCTAssertNotNil(refusal(QARenderSnapshot.resolve(
            arguments: arguments(), runtime: runtime(bundleIdentifier: "yyh.CLI-Pulse")
        )))
    }

    func testTheOutputMustBeAnAbsoluteDirectory() {
        XCTAssertNotNil(refusal(QARenderSnapshot.resolve(
            arguments: arguments(output: "renders/ja"), runtime: runtime()
        )))
        // A flag with no value: the next token is another flag.
        XCTAssertNotNil(refusal(QARenderSnapshot.resolve(
            arguments: ["app", "-CLIPulseRenderSnapshots", "-AppleLanguages", "(ja)",
                        "-cli_pulse_locale_override", "ja"],
            runtime: runtime()
        )))
    }

    func testTheLanguageMustBeGivenBothWaysAndAgree() {
        XCTAssertNotNil(refusal(QARenderSnapshot.resolve(
            arguments: arguments(language: nil), runtime: runtime()
        )), "without the override CLIPulseCore's strings would follow the system")
        XCTAssertNotNil(refusal(QARenderSnapshot.resolve(
            arguments: arguments(appleLanguages: nil), runtime: runtime()
        )), "without AppleLanguages AppKit's strings would follow the system")
        XCTAssertNotNil(refusal(QARenderSnapshot.resolve(
            arguments: arguments(language: "ja", appleLanguages: "(ko)"), runtime: runtime()
        )))
        XCTAssertNotNil(refusal(QARenderSnapshot.resolve(
            arguments: arguments(appleLanguages: "ja"), runtime: runtime()
        )), "a bare string is not the list AppKit reads")
    }

    func testOnlyShippedLocalizationsAreAccepted() {
        for language in LocaleOverrideStore.shippedLocalizations {
            let resolution = QARenderSnapshot.resolve(
                arguments: arguments(language: language, appleLanguages: "(\"\(language)\")"),
                runtime: runtime()
            )
            guard case .render(let request) = resolution else {
                return XCTFail("\(language): expected a render, got \(resolution)")
            }
            XCTAssertEqual(request.language, language)
        }
        XCTAssertNotNil(refusal(QARenderSnapshot.resolve(
            arguments: arguments(language: "fr", appleLanguages: "(fr)"), runtime: runtime()
        )))
        XCTAssertNotNil(refusal(QARenderSnapshot.resolve(
            arguments: arguments(language: "zh-hans", appleLanguages: "(\"zh-hans\")"), runtime: runtime()
        )), "the override must be the canonical .lproj name the store and the manifest use")
    }

    func testRepeatedArgumentsAreRefused() {
        XCTAssertNotNil(refusal(QARenderSnapshot.resolve(
            arguments: arguments(extra: ["-cli_pulse_locale_override", "ko"]), runtime: runtime()
        )))
        XCTAssertNotNil(refusal(QARenderSnapshot.resolve(
            arguments: arguments(extra: ["-CLIPulseRenderSnapshots", "/tmp/other"]), runtime: runtime()
        )))
    }

    // MARK: - Which set

    func testTheReviewSetIsTheDefaultAtTwoX() {
        guard case .render(let request) = QARenderSnapshot.resolve(
            arguments: arguments(), runtime: runtime()
        ) else {
            return XCTFail("expected a render")
        }
        XCTAssertEqual(request.set, .review)
        XCTAssertEqual(request.scale, 2)
        XCTAssertEqual(request.set.manifestFileName, "manifest.json")
    }

    func testTheStoreSetIsAskedForByNameAndDrawnAtThreeX() {
        guard case .render(let request) = QARenderSnapshot.resolve(
            arguments: arguments(extra: ["-CLIPulseRenderSet", "store"]), runtime: runtime()
        ) else {
            return XCTFail("expected a render")
        }
        XCTAssertEqual(request.set, .store)
        XCTAssertEqual(request.scale, 3)
        XCTAssertEqual(request.set.manifestFileName, "render.json")
    }

    func testAnUnknownOrRepeatedSetIsRefused() {
        XCTAssertNotNil(refusal(QARenderSnapshot.resolve(
            arguments: arguments(extra: ["-CLIPulseRenderSet", "screenshots"]), runtime: runtime()
        )))
        XCTAssertNotNil(refusal(QARenderSnapshot.resolve(
            arguments: arguments(extra: ["-CLIPulseRenderSet"]), runtime: runtime()
        )), "a flag with no value must not fall back to the review set")
        XCTAssertNotNil(refusal(QARenderSnapshot.resolve(
            arguments: arguments(extra: ["-CLIPulseRenderSet", "store", "-CLIPulseRenderSet", "review"]),
            runtime: runtime()
        )))
        XCTAssertNotNil(refusal(QARenderSnapshot.resolve(
            arguments: arguments(extra: ["-CLIPulseRenderSet", "store"]),
            runtime: TestRuntimeFixtures.productionApp
        )), "the store set is a QA render like any other: production refuses it")
    }

    // MARK: - The store set

    func testTheStoreSetIsTheSevenAppStoreScreensInListingOrder() {
        // scripts/appstore_screenshots.py MAC_SCREENS names the same seven, and
        // scripts/test_appstore_screenshots.py holds the two lists together.
        XCTAssertEqual(QARenderSnapshot.storeCatalog.map(\.id), [
            "01_overview", "02_providers", "03_usage_history", "04_projects",
            "05_cost", "06_alerts", "07_pulse_cat",
        ])
        XCTAssertEqual(
            QARenderSnapshot.storeCatalog.map(\.fileName),
            QARenderSnapshot.storeCatalog.map { $0.id + ".png" }
        )
        XCTAssertEqual(
            QARenderSnapshot.storeCatalog.compactMap(\.panelFileName),
            ["03_usage_history.panel.png", "04_projects.panel.png"],
            "the usage-history and projects shots carry a panel, no other"
        )
        XCTAssertEqual(QARenderSnapshot.storeCatalog.map(\.panel),
                       [nil, nil, .usageDashboard, .provider(.codex), nil, nil, nil])
        let projects = QARenderSnapshot.storeCatalog[3]
        XCTAssertEqual(projects.surface, .demo(.providers),
                       "the provider panel beside the Providers tab, whose card opens it")
        let cost = QARenderSnapshot.storeCatalog[4]
        XCTAssertEqual(cost.surface, .demo(.overview))
        XCTAssertEqual(cost.page, .lastAligned,
                       "the cost shot is the Overview scrolled to its end, opening above a card")
        XCTAssertEqual(QARenderSnapshot.storeCatalog.filter { $0.page != .first }.map(\.id), ["05_cost"])
    }

    // MARK: - Framing the provider panel (v1.58)

    /// Shaped like the Codex panel opened from its Demo card at 520 points:
    /// the panel's own backdrop over the whole content, then the chart,
    /// totals, Projects and Sessions cards, 16 points apart, 1,140 points in
    /// all, and the Sessions card's sort control inside it.
    private var codexPanel158: [QARenderSpan] {
        [span(0, 1140), span(96, 355), span(371, 516), span(532, 727), span(743, 1118), span(770, 790)]
    }

    func testTheProviderPanelOpensOnProjectsInAPanelALaptopCanHave() throws {
        // A 876-point panel scrolled to the end opens at 264, through the chart
        // card. Sessions, the first card it runs past, would need a 405-point
        // panel; the lowest card above it a panel of at least 600 can open on
        // is Projects: 532 - 4 = 528 down, 1140 - 528 = 612 tall.
        XCTAssertEqual(QARenderSnapshot.lastPageTop(contentHeight: 1140, viewportHeight: 876), 264)
        XCTAssertEqual(QARenderSnapshot.cutByTopEdge(264, spans: [span(96, 355)]), [span(96, 355)])
        let frame = try XCTUnwrap(QARenderSnapshot.providerPanelFrame(cards: codexPanel158, contentHeight: 1140))
        XCTAssertEqual(frame.card, span(532, 727))
        XCTAssertEqual(frame.height, 612)
        XCTAssertGreaterThanOrEqual(frame.height, QARenderSnapshot.storeProviderPanelMinHeight)
        XCTAssertLessThanOrEqual(frame.height, QARenderSnapshot.storeProviderPanelLaptopHeight)
        let top = QARenderSnapshot.lastPageTop(contentHeight: 1140, viewportHeight: frame.height)
        XCTAssertEqual(top, 528)
        XCTAssertEqual(QARenderSnapshot.cutByTopEdge(
            top, spans: codexPanel158.filter { !QARenderSnapshot.coversContent($0, contentHeight: 1140) }), [])
    }

    func testNegativeControlTheProviderPanelIsNotFramedOnItsOwnBackdropOrWhenItFits() {
        // Without the backdrop filter, the backdrop (0-1140) would be the first
        // card a laptop panel runs past; the frame must not come from it.
        XCTAssertTrue(QARenderSnapshot.coversContent(span(0, 1140), contentHeight: 1140))
        XCTAssertFalse(QARenderSnapshot.coversContent(span(96, 355), contentHeight: 1140))
        XCTAssertNil(QARenderSnapshot.providerPanelFrame(cards: [span(0, 1140)], contentHeight: 1140),
                     "the backdrop alone is no card to open on")
        XCTAssertNil(QARenderSnapshot.providerPanelFrame(cards: [span(0, 800), span(96, 355), span(371, 780)],
                                                         contentHeight: 800),
                     "a panel shorter than a laptop's does not scroll, so there is nothing to frame")
        // A panel whose Projects card would need a panel under 600 points
        // (560 - 264 - 4 = 292 off 876) opens one card higher: on the totals
        // card, 371 - 4 = 367 down, 1140 - 367 = 773 tall.
        let tall = [span(96, 355), span(371, 516), span(560, 700), span(716, 1118)]
        let frame = QARenderSnapshot.providerPanelFrame(cards: tall, contentHeight: 1140)
        XCTAssertEqual(frame?.card, span(371, 516))
        XCTAssertEqual(frame?.height, 773)
    }

    // MARK: - Framing the page scrolled to the end

    private func span(_ top: Double, _ bottom: Double) -> QARenderSpan {
        QARenderSpan(top: top, bottom: bottom)
    }

    /// The 1.55 Demo Overview in the store render, in points down its content:
    /// Activity, Cost Summary, Provider Usage, 12 points apart, in a 748-point
    /// content whose 580-point popover shows 501 of it. No Hourly Activity,
    /// Top Projects or Risk Signals card any more. The renderer measured the
    /// Activity card's span, the last page's top at 247 and the trim of 122;
    /// the other spans are read off the raws, to the point.
    private var overview155: [QARenderSpan] {
        [span(188, 361), span(373, 511), span(523, 736)]
    }

    func testTheCostPageOpensWhereTheFirstPageLeftOff() {
        let cards = overview155
        // Scrolled flush to the end (748 - 501 = 247), the page opens through
        // the Activity card, which the first page (0-501) showed whole.
        XCTAssertEqual(QARenderSnapshot.lastPageTop(contentHeight: 748, viewportHeight: 501), 247)
        XCTAssertEqual(QARenderSnapshot.cutByTopEdge(247, spans: cards), [span(188, 361)])
        // Cost Summary is the first card the first page cut off.
        XCTAssertEqual(QARenderSnapshot.alignedCard(cards, contentHeight: 748, viewportHeight: 501),
                       span(373, 511))
        // 373 - 247 = 126 points down, less the 4 of clearance: a 458-point popover.
        let trim = QARenderSnapshot.alignedTrim(cards: cards, contentHeight: 748, viewportHeight: 501)
        XCTAssertEqual(trim, 122)
        // In the popover shortened by that, the page opens at 369: in the gap
        // above Cost Summary, cutting through nothing.
        let top = QARenderSnapshot.lastPageTop(contentHeight: 748, viewportHeight: 501 - 122)
        XCTAssertEqual(top, 369)
        XCTAssertEqual(QARenderSnapshot.cutByTopEdge(top, spans: cards), [])
    }

    func testALongerOverviewAlignsAboveTheFirstCardTheLastPageCanReach() {
        // Shaped like 1.54's Overview: Top Projects and Risk Signals below
        // Provider Usage, and the Yield Score's text (not a card) above it. The last page
        // (1098 - 506 = 592) starts below Cost Summary's top, so it opens
        // above Provider Usage: 648 - 592 = 56 points down, less the clearance.
        let cards = [span(190, 365), span(377, 472), span(484, 621), span(648, 833),
                     span(845, 968), span(980, 1086)]
        XCTAssertEqual(QARenderSnapshot.alignedCard(cards, contentHeight: 1098, viewportHeight: 506),
                       span(648, 833))
        XCTAssertEqual(QARenderSnapshot.alignedTrim(cards: cards, contentHeight: 1098, viewportHeight: 506), 52)
        let yieldScoreText = span(626, 636)
        XCTAssertEqual(QARenderSnapshot.cutByTopEdge(600, spans: [yieldScoreText]), [],
                       "above the text")
        XCTAssertEqual(QARenderSnapshot.cutByTopEdge(630, spans: [yieldScoreText]), [yieldScoreText],
                       "through the text, as the unshortened 1.54 page did")
        XCTAssertEqual(QARenderSnapshot.cutByTopEdge(592 + 52, spans: cards + [yieldScoreText]), [])
    }

    /// Shaped like 1.55's Overview once Gemini has no cost row: Cost Summary
    /// is 21 points shorter and ends on the first page (0-501), so the first
    /// card the first page cut off is Provider Usage. Opening on it needs 272
    /// points off a 580-point popover (a 308-point one, under the 400 users can
    /// drag it to), so the page opens on Cost Summary, the card above it.
    func testWhenTheCardLeftOffNeedsTooShortAPopoverThePageOpensOnTheCardAbove() {
        let cards = [span(188, 361), span(373, 490), span(502, 715)]
        let lastTop = QARenderSnapshot.lastPageTop(contentHeight: 727, viewportHeight: 501)
        XCTAssertEqual(lastTop, 226)
        XCTAssertEqual(QARenderSnapshot.trim(toOpenAbove: span(502, 715), contentHeight: 727,
                                             viewportHeight: 501, clearance: 4), 272,
                       "Provider Usage alone: a 308-point popover")
        XCTAssertEqual(QARenderSnapshot.alignedCard(cards, contentHeight: 727, viewportHeight: 501),
                       span(373, 490))
        let trim = QARenderSnapshot.alignedTrim(cards: cards, contentHeight: 727, viewportHeight: 501)
        XCTAssertEqual(trim, 143, "373 - 226 = 147 points down, less the 4 of clearance: a 437-point popover")
        XCTAssertEqual(QARenderSnapshot.cutByTopEdge(lastTop + 143, spans: cards), [])
        // With room to shorten further, it opens where the first page left off.
        XCTAssertEqual(QARenderSnapshot.alignedCard(cards, contentHeight: 727, viewportHeight: 501, maxTrim: 300),
                       span(502, 715))
        // Negative control: no card that fits, so nothing to align above.
        XCTAssertNil(QARenderSnapshot.alignedCard([span(502, 715)], contentHeight: 727, viewportHeight: 501))
    }

    func testACardAlreadyJustBelowTheTopEdgeNeedsNoTrim() {
        // The last page starts at 480, 4 points above Cost Summary.
        let cards = [span(377, 472), span(484, 621), span(633, 818)]
        XCTAssertEqual(QARenderSnapshot.alignedTrim(cards: cards, contentHeight: 830, viewportHeight: 350), 0)
        // 2 points above: less than the clearance, still nothing to take off.
        XCTAssertEqual(QARenderSnapshot.alignedTrim(cards: cards, contentHeight: 832, viewportHeight: 350), 0)
    }

    func testNegativeControlNoCardToAlignAboveHasNoTrim() {
        XCTAssertNil(QARenderSnapshot.alignedTrim(cards: [], contentHeight: 830, viewportHeight: 506),
                     "no card measured")
        XCTAssertNil(QARenderSnapshot.alignedTrim(cards: [span(12, 200), span(212, 500)],
                                                  contentHeight: 512, viewportHeight: 506),
                     "the first page showed every card whole")
        XCTAssertNil(QARenderSnapshot.alignedTrim(cards: [span(12, 200), span(212, 900)],
                                                  contentHeight: 912, viewportHeight: 506),
                     "the last page (406) starts inside the only card the first page cut off")
        XCTAssertNil(QARenderSnapshot.alignedTrim(cards: overview155, contentHeight: 748, viewportHeight: 0))
    }

    func testOnlyTheLastPetPageIsRefusedNotAnAlignedOverview() {
        let aligned = QARenderStoreShot(id: "09_x", screen: "x", surface: .demo(.overview),
                                        page: .lastAligned, panel: nil)
        XCTAssertNil(QARenderSnapshot.storeSurfaceProblem(aligned))
        let pet = QARenderStoreShot(id: "09_x", screen: "x", surface: .demo(.pet),
                                    page: .lastAligned, panel: nil)
        XCTAssertNotNil(QARenderSnapshot.storeSurfaceProblem(pet))
    }

    func testEveryStoreShotIsFreeOfUIThatDiffersInTheMacAppStoreBuild() {
        for shot in QARenderSnapshot.storeCatalog {
            XCTAssertNil(QARenderSnapshot.storeSurfaceProblem(shot))
        }
    }

    func testTheStoreRuleRefusesEverySurfaceThatDiffers() {
        func shot(_ surface: QARenderSurface, page: QARenderStoreShot.Page = .first,
                  panel: QARenderStoreShot.Panel? = nil) -> QARenderStoreShot {
            QARenderStoreShot(id: "09_x", screen: "x", surface: surface, page: page, panel: panel)
        }
        let refused: [QARenderStoreShot] = [
            shot(.demo(.sessions)),          // sells helper control and the terminal
            shot(.demo(.machine)),           // reads the helper; differs sandboxed
            shot(.demo(.settings)),          // Companion CLI hidden in QA only
            shot(.demoSettings(.general)),
            shot(.demoUpgradePrompt),        // setup v2 flags, QA only
            shot(.signedOut(.overview)),
            shot(.onboarding(.welcome)),
            shot(.firstLaunch),
            shot(.about),
            shot(.subscription),             // no StoreKit products in QA
            shot(.providerEditor(.codex)),   // QA-only banner
            shot(.usageDashboardPanel),
            shot(.demo(.pet), page: .last),  // the Debug build's test buttons
            shot(.demo(.alerts), panel: .usageDashboard),
            shot(.demo(.providers), panel: .usageDashboard),  // the dashboard opens from the Overview
            shot(.demo(.overview), panel: .provider(.codex)),  // a provider's from its card
            shot(.demo(.alerts), panel: .provider(.codex)),
        ]
        for candidate in refused {
            XCTAssertNotNil(
                QARenderSnapshot.storeSurfaceProblem(candidate),
                "\(candidate.surface.id) page \(candidate.page) panel \(String(describing: candidate.panel))"
            )
        }
    }

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static let sampleDay = Date(timeIntervalSince1970: 1_790_000_000)  // 2026-09-21

    func testTheSampleLocalHistoryIsWhatTheScannerRecords() {
        let archive = QARenderSnapshot.storeLocalScanArchive(today: Self.sampleDay, calendar: Self.utc)
        XCTAssertEqual(QARenderSnapshot.storeLocalScanProblems(archive), [])
        let providers = Set(archive.days.values.flatMap { $0.perProvider.keys })
        XCTAssertEqual(providers, ["Claude", "Codex"], "Claude and Codex only, and both")
        XCTAssertGreaterThan(archive.days.count, 200, "a year of history, with idle days")
        XCTAssertGreaterThan(DailyUsageStats.totalMessages(archive), 0)
        let models = Set(archive.days.values.flatMap { $0.perModel.keys })
        XCTAssertFalse(models.contains(ScanEntry.messageBucketModel),
                       "the message bucket is not a model, as the scanner's merge has it")
    }

    func testTheSampleIsDeterministic() {
        XCTAssertEqual(
            QARenderSnapshot.storeLocalScanSample(today: Self.sampleDay, calendar: Self.utc),
            QARenderSnapshot.storeLocalScanSample(today: Self.sampleDay, calendar: Self.utc)
        )
    }

    func testTodayInTheSampleIsTheDemoDashboardsCodexAndClaude() throws {
        let archive = QARenderSnapshot.storeLocalScanArchive(today: Self.sampleDay, calendar: Self.utc)
        let today = try XCTUnwrap(archive.days[DailyUsageStats.localDayKey(Self.sampleDay, calendar: Self.utc)])
        let codex = try XCTUnwrap(today.perProvider["Codex"])
        let claude = try XCTUnwrap(today.perProvider["Claude"])
        XCTAssertEqual(codex.tokens, 85_900)
        XCTAssertEqual(codex.cost, 1.03, accuracy: 0.0001)
        XCTAssertEqual(claude.tokens, 24_800)
        XCTAssertEqual(claude.cost, 0.37, accuracy: 0.0001)
        XCTAssertGreaterThan(claude.messages, 0)
        XCTAssertEqual(codex.messages, 0, "the scanner counts messages for Claude only")
        let demo = DemoDataProvider.generate().providers
        XCTAssertEqual(demo.first { $0.provider == "Codex" }?.today_usage, codex.tokens)
        XCTAssertEqual(demo.first { $0.provider == "Claude" }?.today_usage, claude.tokens)
    }

    func testNegativeControlAProviderTheScannerNeverRecordsIsCaught() {
        var sample = QARenderSnapshot.storeLocalScanSample(today: Self.sampleDay, calendar: Self.utc)
        sample.append(ScanEntry(
            date: DailyUsageStats.localDayKey(Self.sampleDay, calendar: Self.utc),
            provider: "Gemini", model: "gemini-2.5-pro",
            inputTokens: 100, cachedTokens: 0, outputTokens: 10, cost: 0.01, messages: 0
        ))
        var archive = DailyUsageArchive()
        archive.mergeScanEntries(sample)
        let problems = QARenderSnapshot.storeLocalScanProblems(archive)
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems.first?.contains("Gemini") == true, "\(problems)")
    }

    func testNegativeControlAnEmptyOrMessagelessHistoryIsCaught() {
        XCTAssertFalse(QARenderSnapshot.storeLocalScanProblems(DailyUsageArchive()).isEmpty)
        let noMessages = QARenderSnapshot.storeLocalScanSample(today: Self.sampleDay, calendar: Self.utc)
            .filter { !$0.isMessageBucket }
        var archive = DailyUsageArchive()
        archive.mergeScanEntries(noMessages)
        XCTAssertTrue(
            QARenderSnapshot.storeLocalScanProblems(archive).contains { $0.contains("messages") }
        )
    }

    func testTheStoreManifestRoundTrips() throws {
        var manifest = QARenderManifest(
            set: .store,
            language: "ja", appleLanguages: ["ja"], localeOverride: "ja",
            resolvedLocalization: "ja", appKitLocalization: "ja", localizationActive: true,
            localizationProbe: [], appearance: .light, scale: 3, windowBackingScale: 2,
            app: .init(bundleIdentifier: "app.clipulse.qa.local", version: "1.54.0", build: "107"),
            generatedAt: "2026-09-28T00:00:00Z", dataSource: "DemoDataProvider", forcedSettings: [:]
        )
        manifest.variant = .init(
            devidBuild: false, debugBuild: true, sandboxed: false, channel: "qa",
            remoteControlAvailable: false, popoverWidth: 380, popoverHeight: 580,
            panelWidth: 520, panelSettleSeconds: 3, panelSettled: true,
            localScanDays: 300, localScanProviders: ["Claude", "Codex"], localScanMessages: 9_000,
            scrollerStyle: "overlay", panelBackdropLuminance: 0.12
        )
        manifest.displayLocale = "ja_JP"
        manifest.shots = [.init(
            id: "03_usage_history", surface: "demo-overview", page: .first, pageIndex: 1,
            pageCount: 3, file: "03_usage_history.png", md5: "0123",
            panelFile: "03_usage_history.panel.png", panelMD5: "4567"
        ), .init(
            id: "04_projects", surface: "demo-providers", page: .first, pageIndex: 1,
            pageCount: 2, file: "04_projects.png", md5: "cdef",
            panelFile: "04_projects.panel.png", panelMD5: "fedc",
            panelProvider: "Codex", panelHeight: 612, panelScrolledTo: 528
        ), .init(
            id: "05_cost", surface: "demo-overview", page: .lastAligned, pageIndex: 3,
            pageCount: 3, file: "05_cost.png", md5: "89ab", popoverHeight: 551
        )]
        let data = try manifest.encoded()
        XCTAssertEqual(try JSONDecoder().decode(QARenderManifest.self, from: data), manifest)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"set\" : \"store\""), text)
        XCTAssertTrue(text.contains("\"devidBuild\" : false"), text)
        XCTAssertTrue(text.contains("\"page\" : \"lastAligned\""), text)
        XCTAssertTrue(text.contains("\"popoverHeight\" : 551"), text)
        XCTAssertTrue(text.contains("\"panelHeight\" : 612"), text)
        XCTAssertTrue(text.contains("\"panelScrolledTo\" : 528"), text)
        XCTAssertTrue(text.contains("\"panelProvider\" : \"Codex\""), text)
        XCTAssertTrue(text.contains("\"scrollerStyle\" : \"overlay\""), text)
    }

    // MARK: - What is drawn

    func testCatalogIdentifiersAreUniqueAndFileSafe() {
        let ids = QARenderSnapshot.catalog.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate ids: \(ids)")
        for id in ids {
            XCTAssertFalse(id.isEmpty)
            XCTAssertNil(
                id.range(of: "[^a-z0-9-]", options: .regularExpression),
                "\(id) is not a plain file name"
            )
        }
        let files = QARenderSnapshot.catalog.enumerated().map {
            QARenderSnapshot.fileName(index: $0.offset, surface: $0.element, page: 1)
        }
        XCTAssertEqual(files.count, Set(files).count)
    }

    func testEveryVisibleTabIsDrawnWithDemoData() {
        let catalog = QARenderSnapshot.catalog
        for tab in AppState.Tab.visibleCases where tab != .settings {
            XCTAssertTrue(catalog.contains(.demo(tab)), "\(tab) is not rendered")
        }
        // Settings is drawn once per section, which covers the tab itself.
        for section in QARenderSettingsSection.allCases {
            XCTAssertTrue(catalog.contains(.demoSettings(section)))
        }
        for tab in QARenderSnapshot.signedOutTabs {
            XCTAssertTrue(catalog.contains(.signedOut(tab)))
        }
    }

    func testEverySetupStepIsDrawn() {
        let catalog = QARenderSnapshot.catalog
        for step in AgentSetupStep.allCases where step != .completed {
            XCTAssertTrue(catalog.contains(.onboarding(step)), "setup v2 step \(step) is not rendered")
        }
        // `.completed` routes to the main app, so its page is drawn through the
        // wizard's own finish state instead, once per mode.
        for mode in QARenderFinishMode.allCases {
            XCTAssertTrue(catalog.contains(.onboardingFinished(mode)))
        }
        for step in 0..<QARenderSnapshot.legacyOnboardingStepCount {
            XCTAssertTrue(catalog.contains(.legacyOnboarding(step: step)))
        }
    }

    func testEveryWindowTheAppDeclaresIsDrawnOrKnowinglyLeftOut() {
        let catalog = QARenderSnapshot.catalog
        for surface: QARenderSurface in [.about, .subscription, .usageDashboardPanel, .firstRunWelcome,
                                         .codexResetCreditsStates] {
            XCTAssertTrue(catalog.contains(surface), "\(surface.id) is not rendered")
        }
        for kind in QARenderSnapshot.providerEditorKinds {
            XCTAssertTrue(catalog.contains(.providerEditor(kind)))
        }
        // v1.57: the usage panel's provider mode, in both metrics, and the
        // iPhone card's history section.
        for kind in [ProviderKind.codex, .claude] {
            XCTAssertTrue(catalog.contains(.providerUsagePanel(kind)), "\(kind) provider panel is not rendered")
        }
        XCTAssertEqual(Set(QARenderSnapshot.providerPanelKinds.map(QARenderSnapshot.providerPanelMetric)),
                       Set(UsageChartMetric.allCases), "the review set shows the chart in tokens and in cost")
        XCTAssertTrue(catalog.contains(.providerUsageCardHistory))
        XCTAssertEqual(QARenderSurface.providerUsagePanel(.codex).id, "panel-provider-usage-codex")
        XCTAssertEqual(QARenderSurface.providerUsagePanel(.codex).kind, .panel)
        // The panel as a Demo card's chart opens it, for both cards that
        // draw one.
        for kind in [ProviderKind.codex, .claude] {
            XCTAssertTrue(catalog.contains(.providerCardPanel(kind)), "\(kind) card's panel is not rendered")
        }
        XCTAssertEqual(QARenderSurface.providerCardPanel(.claude).id, "panel-provider-card-claude")
        XCTAssertEqual(QARenderSurface.providerCardPanel(.claude).kind, .panel)
    }

    /// v1.58: the review set draws the Usage Dashboard with Trends in Cost,
    /// the cost charts' stub for a day with no known cost, and the Claude
    /// card with this Mac's message counts, whose layout depends on the
    /// language. None of them is a store shot.
    func testTheReviewSetDrawsTheV158Surfaces() {
        let catalog = QARenderSnapshot.catalog
        let expected: [(QARenderSurface, String, QARenderSurface.Kind)] = [
            (.usageDashboardPanelCost, "panel-usage-dashboard-cost", .panel),
            (.costUnknownDays, "chart-cost-unknown-days", .window),
            (.claudeCardThisMacMessages, "card-claude-this-mac-messages", .window),
        ]
        for (surface, id, kind) in expected {
            XCTAssertTrue(catalog.contains(surface), "\(id) is not rendered")
            XCTAssertEqual(surface.id, id)
            XCTAssertEqual(surface.kind, kind)
            XCTAssertFalse(QARenderSnapshot.storeCatalog.contains { $0.surface == surface })
        }
        // The Cost panel comes right after the Tokens one, both in Demo mode.
        guard let tokens = catalog.firstIndex(of: .usageDashboardPanel),
              let cost = catalog.firstIndex(of: .usageDashboardPanelCost) else { return XCTFail("missing") }
        XCTAssertEqual(cost, tokens + 1)

        // The card's scan sample: Claude's rows and a message count a day,
        // and nothing for any other provider.
        let today = DayKey.date(from: "2026-10-07", hour: 12) ?? Date()
        let utc = TimeZone(identifier: "UTC")!
        let scan = QARenderSnapshot.claudeMessagesScanSample(today: today, timeZone: utc)
        XCTAssertTrue(scan.allSatisfy { $0.provider == ProviderKind.claude.rawValue })
        let buckets = scan.filter { $0.model == ScanEntry.messageBucketModel }
        XCTAssertFalse(buckets.isEmpty)
        XCTAssertTrue(buckets.allSatisfy { $0.messageCount > 0 && $0.inputTokens == 0 && $0.costUSD == nil })
        XCTAssertEqual(Set(buckets.map(\.date)),
                       Set(scan.filter { $0.model != ScanEntry.messageBucketModel }.map(\.date)),
                       "a message count for every day with usage")
        XCTAssertEqual(scan.map(\.messageCount),
                       QARenderSnapshot.claudeMessagesScanSample(today: today, timeZone: utc).map(\.messageCount))
    }

    /// v1.58: the states the PR #686 reviews asked to see, in the review set:
    /// cost charts with no day known, the provider panel (dark) with a stub
    /// hovered and with a day of models with no rate, the dashboard panel's
    /// Trends with stubs, the Sessions legend with log-derived rows, and the
    /// source line signed in, merged and with no quota source. None is a
    /// store shot.
    func testTheReviewSetDrawsTheStatesTheReviewsAskedFor() throws {
        let catalog = QARenderSnapshot.catalog
        let expected: [(QARenderSurface, String, QARenderSurface.Kind)] = [
            (.costUnknownEveryDay, "chart-cost-unknown-every-day", .window),
            (.providerPanelCostUnknown, "panel-provider-cost-unknown-claude", .panel),
            (.providerPanelNoRateDay, "panel-provider-no-rate-day-claude", .panel),
            (.usageDashboardPanelCostUnknown, "panel-usage-dashboard-cost-unknown", .panel),
            (.demoSessionsWithLogs, "demo-sessions-with-logs", .popover),
            (.cardSourceLines, "card-source-lines", .window),
        ]
        for (surface, id, kind) in expected {
            XCTAssertTrue(catalog.contains(surface), "\(id) is not rendered")
            XCTAssertEqual(surface.id, id)
            XCTAssertEqual(surface.kind, kind)
            XCTAssertFalse(QARenderSnapshot.storeCatalog.contains { $0.surface == surface })
        }
        XCTAssertEqual(Set(catalog.map(\.id)).count, catalog.count, "two surfaces share a file name")

        let today = DayKey.date(from: "2026-10-07", hour: 12) ?? Date()
        let utc = TimeZone(identifier: "UTC")!
        // No day's cost known.
        let all = QARenderSnapshot.costAllUnknownSample(today: today, timeZone: utc)
        XCTAssertFalse(all.isEmpty)
        XCTAssertTrue(all.allSatisfy { $0.cost == 0 })
        let allDays = ProviderUsageDays.fromCloud(all, provider: "Claude", todayKey: "2026-10-07", timeZone: utc)
        XCTAssertTrue(allDays.days.filter(\.hasUsage).allSatisfy(\.costIsUnknown))
        XCTAssertEqual(allDays.days.map { $0.value(.cost) }.max(), 0)
        // A day of models with no rate on this Mac.
        let noRate = QARenderSnapshot.noRateDaySample(today: today, timeZone: utc)
        let day = try XCTUnwrap(noRate.day)
        let scanDays = ProviderUsageDays.fromScan(noRate.rows, provider: "Claude", todayKey: "2026-10-07", timeZone: utc)
        let unpriced = try XCTUnwrap(scanDays.day(day))
        XCTAssertTrue(unpriced.costIsUnknown)
        XCTAssertTrue(unpriced.models.allSatisfy(\.hasNoRate))
        XCTAssertEqual(scanDays.days.filter(\.costIsUnknown).map(\.dateKey), [day], "only that day changes")
        // Sessions from this Mac's logs: one Recent activity, one Recent.
        let sessions = QARenderSnapshot.logSessionsSample(now: today)
        XCTAssertEqual(sessions.map { SessionFreshnessTierClassifier.classify($0, now: today) },
                       [.activeJsonl, .recentJsonl])
    }

    /// The provider-panel renders draw from sample rows that are the same on
    /// every run and show what the panel marks: a borrowed rate, a model with
    /// no rate, idle days. No Demo surface reads them.
    func testTheProviderPanelSampleIsDeterministicAndShowsTheMarks() {
        let today = DayKey.date(from: "2026-10-07", hour: 12) ?? Date()
        let utc = TimeZone(identifier: "UTC")!
        let codex = QARenderSnapshot.providerPanelSample(.codex, today: today, timeZone: utc)
        let again = QARenderSnapshot.providerPanelSample(.codex, today: today, timeZone: utc)
        XCTAssertEqual(codex.map(\.date), again.map(\.date))
        XCTAssertEqual(codex.map(\.inputTokens), again.map(\.inputTokens))
        XCTAssertTrue(codex.allSatisfy { $0.provider == "Codex" && $0.cachedTokens <= $0.inputTokens })
        XCTAssertTrue(codex.contains { $0.priceIsApproximate })

        let claude = QARenderSnapshot.providerPanelSample(.claude, today: today, timeZone: utc)
        XCTAssertTrue(claude.contains { $0.costUSD == nil }, "a model with no rate, for the coverage line")
        let days = ProviderUsageDays.fromScan(claude, provider: "Claude", todayKey: "2026-10-07", timeZone: utc)
        XCTAssertTrue(days.coverage.shouldDisclose)
        XCTAssertGreaterThan(days.days.filter(\.hasUsage).count, 15)
        XCTAssertLessThan(days.days.filter(\.hasUsage).count, 30, "some idle days")
        // As synced rows (the iPhone component), its model with no rate
        // arrives with a cost of 0 and is drawn as unknown.
        let synced = claude.map {
            DailyUsage(date: $0.date, provider: $0.provider, model: $0.model, inputTokens: $0.inputTokens,
                       cachedTokens: $0.cachedTokens, outputTokens: $0.outputTokens, cost: $0.costUSD ?? 0)
        }
        let cloud = ProviderUsageDays.fromCloud(synced, provider: "Claude", basis: .inputOutput,
                                                todayKey: "2026-10-07", timeZone: utc)
        XCTAssertTrue(cloud.days.contains { $0.models.contains(where: \.costIsUnknown) })
    }

    func testSignedOutSurfacesComeBeforeDemoMode() {
        // The renderer enters Demo mode once and cannot leave it, so every
        // signed-out surface must be drawn first.
        let catalog = QARenderSnapshot.catalog
        guard let firstDemo = catalog.firstIndex(where: {
            if case .demo = $0 { return true }
            return false
        }) else {
            return XCTFail("no demo surface")
        }
        for (index, surface) in catalog.enumerated() {
            switch surface {
            case .firstLaunch, .legacyOnboarding, .onboarding, .onboardingFinished,
                 .localScanConsent, .localScanConsentOlderLogs, .signedOut, .signedOutPasswordSignIn:
                XCTAssertLessThan(index, firstDemo, "\(surface.id) is drawn after Demo mode began")
            default:
                XCTAssertGreaterThanOrEqual(index, firstDemo, "\(surface.id) is drawn before Demo mode")
            }
        }
    }

    func testFileNamesAreNumberedInDrawingOrderWithPageSuffixes() {
        XCTAssertEqual(
            QARenderSnapshot.fileName(index: 0, surface: .firstLaunch, page: 1),
            "01-first-launch.png"
        )
        XCTAssertEqual(
            QARenderSnapshot.fileName(index: 11, surface: .onboarding(.syncMode), page: 3),
            "12-setup-v2-sync-mode-p3.png"
        )
    }

    func testSlugs() {
        XCTAssertEqual(QARenderSurface.slug("syncMode"), "sync-mode")
        XCTAssertEqual(QARenderSurface.slug("JetBrains AI"), "jet-brains-ai")
        XCTAssertEqual(QARenderSurface.slug("z.ai"), "z-ai")
        XCTAssertEqual(QARenderSurface.slug("Overview"), "overview")
    }

    // MARK: - Scrolling

    func testContentThatFitsIsOnePage() {
        XCTAssertEqual(QARenderSnapshot.pageOffsets(contentHeight: 500, viewportHeight: 500), [0])
        XCTAssertEqual(QARenderSnapshot.pageOffsets(contentHeight: 300, viewportHeight: 500), [0])
    }

    func testPagesCoverEveryPointAndEndFlushWithTheBottom() {
        let viewport = 500.0
        let content = 1_730.0
        let offsets = QARenderSnapshot.pageOffsets(
            contentHeight: content, viewportHeight: viewport, overlap: 48
        )
        XCTAssertEqual(offsets.first, 0)
        XCTAssertEqual(offsets.last, content - viewport)
        for (a, b) in zip(offsets, offsets.dropFirst()) {
            XCTAssertGreaterThan(b, a)
            XCTAssertLessThanOrEqual(b - a, viewport, "a gap between pages would hide content")
        }
    }

    func testTheNextPageIsMeasuredAgainAsLazyContentGrows() {
        XCTAssertEqual(
            QARenderSnapshot.nextPageOffset(after: 0, contentHeight: 1_000, viewportHeight: 500),
            452
        )
        // The stack grew while it was scrolled: paging continues past the
        // height first measured instead of stopping at it.
        XCTAssertEqual(
            QARenderSnapshot.nextPageOffset(after: 500, contentHeight: 2_000, viewportHeight: 500),
            952
        )
        XCTAssertNil(QARenderSnapshot.nextPageOffset(after: 1_500, contentHeight: 2_000, viewportHeight: 500))
        XCTAssertNil(QARenderSnapshot.nextPageOffset(after: 0, contentHeight: 900, viewportHeight: 0))
    }

    func testPagesAreCapped() {
        let offsets = QARenderSnapshot.pageOffsets(
            contentHeight: 100_000, viewportHeight: 500, maxPages: 4
        )
        XCTAssertEqual(offsets.count, 4)
        XCTAssertEqual(offsets.last, 99_500)
    }

    // MARK: - Checking a render

    func testUniformOrNearUniformPixelsLookBlank() {
        XCTAssertTrue(QARenderSnapshot.looksBlank(rgbaSamples: Array(repeating: 0xFFFF_FFFF, count: 400)))
        // Noise in the low bits is not drawing.
        XCTAssertTrue(QARenderSnapshot.looksBlank(rgbaSamples: [0xFFFF_FFFF, 0xFEFE_FEFF, 0xF9FA_FBFF]))
        XCTAssertTrue(QARenderSnapshot.looksBlank(rgbaSamples: []))
    }

    func testDrawnPixelsDoNotLookBlank() {
        XCTAssertFalse(QARenderSnapshot.looksBlank(
            rgbaSamples: [0xFFFF_FFFF, 0x0000_00FF, 0x8080_80FF, 0xFFFF_FFFF]
        ))
    }

    // MARK: - Localization probe

    func testProbeKeysExistInEveryShippedCatalogue() throws {
        for language in LocaleOverrideStore.shippedLocalizations {
            let bundle = try XCTUnwrap(
                LocaleOverrideStore.bundle(forLocalization: language), "\(language).lproj"
            )
            for key in QARenderSnapshot.probeKeys {
                let value = NSLocalizedString(key, bundle: bundle, comment: "")
                XCTAssertNotEqual(value, key, "\(key) is missing from \(language)")
            }
        }
    }

    func testProbeTellsATranslatedCatalogueFromEnglish() {
        let english = QARenderManifest.Probe(key: "tab.settings", value: "Settings", english: "Settings")
        let japanese = QARenderManifest.Probe(key: "tab.settings", value: "設定", english: "Settings")
        XCTAssertTrue(QARenderSnapshot.localizationIsActive(language: "en", probes: [english]))
        XCTAssertFalse(QARenderSnapshot.localizationIsActive(language: "ja", probes: [english]),
                       "Japanese showing only English values means the catalogue did not load")
        XCTAssertTrue(QARenderSnapshot.localizationIsActive(language: "ja", probes: [english, japanese]))
    }

    // MARK: - Hide personal information (v1.58, P1-6)

    /// Every privacy surface is drawn, last, with its kind; none is a store
    /// shot.
    func testTheReviewSetDrawsEveryPrivacySurface() {
        let catalog = QARenderSnapshot.catalog
        let expected: [(QARenderPrivacySurface, String, QARenderSurface.Kind)] = [
            (.overview, "hide-personal-info-overview", .popover),
            (.sessions, "hide-personal-info-sessions", .popover),
            (.alerts, "hide-personal-info-alerts", .popover),
            (.panel, "hide-personal-info-panel-codex", .panel),
            (.exports, "hide-personal-info-exports", .document),
        ]
        XCTAssertEqual(expected.map(\.0), QARenderPrivacySurface.allCases)
        for (which, id, kind) in expected {
            let surface = QARenderSurface.hidePersonalInfo(which)
            XCTAssertTrue(catalog.contains(surface), "\(id) is not rendered")
            XCTAssertEqual(surface.id, id)
            XCTAssertEqual(surface.kind, kind)
            XCTAssertFalse(QARenderSnapshot.storeCatalog.contains { $0.surface == surface })
        }
        XCTAssertEqual(
            Array(catalog.suffix(QARenderPrivacySurface.allCases.count)),
            QARenderPrivacySurface.allCases.map { .hidePersonalInfo($0) },
            "drawn after everything else, so the switch they turn on and off is off for every other surface")
    }

    /// What the privacy renders look for: every project name and path, every
    /// session's stored name (the command line included) and project, every
    /// alert's, and "/Users/"; not the app's own words, a provider's name or
    /// a placeholder.
    func testThePersonalStringsAreTheDatasNamesAndPaths() {
        let now = Date()
        let sessions = DemoDataProvider.generate().sessions + QARenderSnapshot.logSessionsSample(now: now)
            + QARenderSnapshot.privacySessionsSample(now: now)
            + [SessionRecord(id: "jsonl-claude-9", name: "Claude session", provider: "Claude", project: "unknown",
                             device_name: "MacBook Pro", started_at: "", last_active_at: "", status: "Running",
                             total_usage: 0, estimated_cost: 0, cost_status: "Estimated", requests: 0, error_count: 0),
               SessionRecord(id: "local-9", name: "claude", provider: "Claude", project: "unknown",
                             device_name: "MacBook Pro", started_at: "", last_active_at: "", status: "Running",
                             total_usage: 0, estimated_cost: 0, cost_status: "Estimated", requests: 0, error_count: 0)]
        let projects = [ProjectIdentity.folder("/Users/demo/Developer/cli-pulse-ios"), .unknown]
        let strings = QARenderSnapshot.personalStrings(
            sessions: sessions, alerts: QARenderSnapshot.privacyAlertsSample(now: now), projects: projects)
        for expected in ["/Users/", "/Users/demo/Developer/cli-pulse-ios", "cli-pulse-ios", "provider-layer",
                         "Claude · demo-app", "sample-service", QARenderSnapshot.privacyCommandLine,
                         "codex exec --cd /Users/sample/Projects/demo-app", "codex-demo-app", "demo-app"] {
            XCTAssertTrue(strings.contains(expected), expected)
        }
        for left in ["Claude session", "claude", "codex", "gemini", "unknown", "local-workspace", "MacBook Pro", "build-box"] {
            XCTAssertFalse(strings.contains(left), left)
        }
        XCTAssertEqual(strings, strings.sorted())
        XCTAssertEqual(strings.count, Set(strings).count)
    }

    func testAPrivacyCheckPassesOnlyWithTextAControlAndNoLeak() {
        let needles = ["demo-app", "/Users/"]
        let pass = QARenderSnapshot.privacyCheck(
            id: "hide-personal-info-sessions", source: "accessibility", needles: needles,
            textsOn: ["Codex · 项目 1", "Codex 会话"], textsOff: ["Codex · demo-app"])
        XCTAssertTrue(pass.passed)
        XCTAssertEqual(pass.shownWithSwitchOff, ["demo-app"])
        XCTAssertNil(QARenderSnapshot.privacyProblem(pass))

        // Negative controls: each way a check must fail.
        let leak = QARenderSnapshot.privacyCheck(
            id: "x", source: "sessions.csv", needles: needles,
            textsOn: ["codex exec --cd /Users/sample/Projects/demo-app"], textsOff: ["demo-app"])
        XCTAssertFalse(leak.passed)
        XCTAssertEqual(leak.leaks, ["demo-app", "/Users/"], "a name inside a longer line is shown")
        XCTAssertEqual(QARenderSnapshot.privacyProblem(leak),
                       "privacy: x (sessions.csv) shows with the switch on: demo-app, /Users/")
        let blind = QARenderSnapshot.privacyCheck(
            id: "x", source: "accessibility", needles: needles, textsOn: ["Codex 会话"], textsOff: ["Codex 会话"])
        XCTAssertFalse(blind.passed, "a control that shows nothing could not have seen a leak")
        XCTAssertTrue(QARenderSnapshot.privacyProblem(blind)?.contains("control") ?? false)
        // The control is the switch-off reading alone: what leaked with the
        // switch on does not stand in for it.
        let blindButLeaking = QARenderSnapshot.privacyCheck(
            id: "x", source: "accessibility", needles: needles, textsOn: ["demo-app"], textsOff: ["Codex 会话"])
        XCTAssertEqual(blindButLeaking.shownWithSwitchOff, [])
        XCTAssertEqual(blindButLeaking.leaks, ["demo-app"])
        XCTAssertTrue(QARenderSnapshot.privacyProblem(blindButLeaking)?.contains("control") ?? false)
        let nothingRead = QARenderSnapshot.privacyCheck(
            id: "x", source: "accessibility", needles: needles, textsOn: [], textsOff: ["demo-app"])
        XCTAssertFalse(nothingRead.passed)
        XCTAssertTrue(QARenderSnapshot.privacyProblem(nothingRead)?.contains("no text") ?? false)
        let caseMatters = QARenderSnapshot.privacyCheck(
            id: "x", source: "accessibility", needles: ["demo-app"], textsOn: ["Demo-App"], textsOff: ["demo-app"])
        XCTAssertTrue(caseMatters.leaks.isEmpty)
    }

    /// The samples are what the producers write: the Companion CLI names a
    /// process row by the first 48 characters of its command line, and its
    /// alert and the desktop app's are templates `AlertPresentation`
    /// recognises.
    func testThePrivacySamplesAreWhatTheProducersWrite() {
        XCTAssertEqual(QARenderSnapshot.privacyCommandLine.count, 48)
        let now = Date()
        let rows = QARenderSnapshot.privacySessionsSample(now: now)
        XCTAssertTrue(rows[0].isProcessScanRow)
        XCTAssertFalse(rows[1].isProcessScanRow || rows[1].id.hasPrefix("jsonl-"))
        XCTAssertTrue(rows.allSatisfy { SessionFreshnessTierClassifier.classify($0, now: now).isVisible },
                      "both rows are listed in the Sessions tab")
        for alert in QARenderSnapshot.privacyAlertsSample(now: now) {
            XCTAssertTrue(AlertPresentation.text(for: alert).recognized, alert.id)
        }
    }

    // MARK: - Manifest

    func testManifestRoundTripsAsSortedJSON() throws {
        let manifest = QARenderManifest(
            language: "ko",
            appleLanguages: ["ko"],
            localeOverride: "ko",
            resolvedLocalization: "ko",
            appKitLocalization: "ko",
            localizationActive: true,
            localizationProbe: [.init(key: "tab.settings", value: "설정", english: "Settings")],
            appearance: .light,
            scale: 2,
            windowBackingScale: 2,
            app: .init(bundleIdentifier: "app.clipulse.qa.local", version: "1.53.0", build: "106"),
            generatedAt: "2026-09-26T00:00:00Z",
            dataSource: "DemoDataProvider",
            forcedSettings: ["cli_pulse_notifications": "false"],
            renders: [.init(
                id: "demo-overview", kind: .popover, file: "20-demo-overview.png",
                page: 1, pageCount: 2, width: 380, height: 580,
                pixelWidth: 760, pixelHeight: 1160, suspectBlank: false
            )],
            languageMenu: .init(source: "nsmenu", note: "", items: [
                .init(title: "한국어", checked: true, separator: false, enabled: true),
            ]),
            skipped: [.init(id: "terminal", reason: "needs a helper session")],
            blockedRequests: ["https://status.example.com/api/v2/status.json"],
            warnings: []
        )
        var withChecks = manifest
        withChecks.privacyChecks = [.init(
            id: "hide-personal-info-sessions", source: "accessibility", textsRead: 120, lookedFor: 14,
            shownWithSwitchOff: ["cli-pulse-ios"], leaks: [])]
        XCTAssertEqual(
            try JSONDecoder().decode(QARenderManifest.self, from: try withChecks.encoded()), withChecks)
        XCTAssertFalse(
            String(decoding: try manifest.encoded(), as: UTF8.self).contains("privacyChecks"),
            "a run that drew no privacy surface writes no privacyChecks")
        let data = try manifest.encoded()
        XCTAssertEqual(try JSONDecoder().decode(QARenderManifest.self, from: data), manifest)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"한국어\""), "non-Latin text must stay readable in the manifest")
        let app = try XCTUnwrap(text.range(of: "\"app\""))
        let language = try XCTUnwrap(text.range(of: "\"language\""))
        XCTAssertLessThan(app.lowerBound, language.lowerBound, "keys must be sorted")
    }
}
