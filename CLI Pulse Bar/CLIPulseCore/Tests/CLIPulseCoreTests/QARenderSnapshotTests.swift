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

    func testTheStoreSetIsTheSixAppStoreScreensInListingOrder() {
        // scripts/appstore_screenshots.py MAC_SCREENS names the same six, and
        // scripts/test_appstore_screenshots.py holds the two lists together.
        XCTAssertEqual(QARenderSnapshot.storeCatalog.map(\.id), [
            "01_overview", "02_providers", "03_usage_history",
            "04_cost", "05_alerts", "06_pulse_cat",
        ])
        XCTAssertEqual(
            QARenderSnapshot.storeCatalog.map(\.fileName),
            QARenderSnapshot.storeCatalog.map { $0.id + ".png" }
        )
        XCTAssertEqual(
            QARenderSnapshot.storeCatalog.compactMap(\.panelFileName),
            ["03_usage_history.panel.png"],
            "only the usage-history shot carries the panel"
        )
        let cost = QARenderSnapshot.storeCatalog[3]
        XCTAssertEqual(cost.surface, .demo(.overview))
        XCTAssertEqual(cost.page, .lastAligned,
                       "the cost shot is the Overview scrolled to its end, opening above a card")
        XCTAssertEqual(QARenderSnapshot.storeCatalog.filter { $0.page != .first }.map(\.id), ["04_cost"])
    }

    // MARK: - Framing the page scrolled to the end

    private static let white: UInt32 = 0xFFFF_FFFF

    private func row(_ width: Int, ink: Int = 0, card: Int = 0) -> [UInt32] {
        // `card` pixels a faint shade off white, `ink` pixels dark grey.
        (0..<width).map { x in
            x < ink ? 0x5050_50FF : (x < ink + card ? 0xFEFE_FEFF : Self.white)
        }
    }

    func testRowsAreBlankInkOrCard() {
        XCTAssertEqual(QARenderSnapshot.rowKind(row(100), background: Self.white), .blank)
        XCTAssertEqual(QARenderSnapshot.rowKind(row(100, ink: 3), background: Self.white), .ink,
                       "a few dark pixels are a line of text")
        XCTAssertEqual(QARenderSnapshot.rowKind(row(100, card: 60), background: Self.white), .card,
                       "a faint shade across most of the row is a card's shadow or fill")
        XCTAssertEqual(QARenderSnapshot.rowKind(row(100, card: 20), background: Self.white), .blank,
                       "a faint shade across part of it is neither")
        XCTAssertEqual(QARenderSnapshot.rowKind([], background: Self.white), .blank)
    }

    func testAPageWhoseTopCutsTextIsShortenedToStartAboveTheCard() {
        // 3 px per point: half a line of text (rows 0-8), 20 blank rows, then a card.
        let rows = Array(repeating: QARenderRow.ink, count: 9)
            + Array(repeating: .blank, count: 20) + Array(repeating: .card, count: 30)
        let trim = QARenderSnapshot.alignedTrim(rows: rows, scale: 3)
        // The card starts at 29 px = 9.67 pt; 4 points of clearance leaves 5.
        XCTAssertEqual(trim, 5)
        let top = (trim ?? 0) * 3
        XCTAssertFalse(rows[top...].prefix(while: { $0 != .card }).contains(.ink),
                       "after the trim no text lies above the card")
        XCTAssertGreaterThanOrEqual(29 - top, 1)
    }

    func testTextJustAboveTheCardWinsOverTheClearance() {
        // Text ends at row 23; the card starts at row 27: the top goes just past the text.
        let rows = Array(repeating: QARenderRow.blank, count: 10) + Array(repeating: .ink, count: 14)
            + Array(repeating: .blank, count: 3) + Array(repeating: .card, count: 10)
        XCTAssertEqual(QARenderSnapshot.alignedTrim(rows: rows, scale: 3), 8)
    }

    func testAPageAlreadyOpeningOnBackgroundNeedsNoTrim() {
        let rows = Array(repeating: QARenderRow.blank, count: 12) + Array(repeating: .card, count: 10)
        XCTAssertEqual(QARenderSnapshot.alignedTrim(rows: rows, scale: 3), 0)
        XCTAssertEqual(QARenderSnapshot.alignedTrim(rows: [.card, .card], scale: 3), 0)
    }

    func testNegativeControlNoCardOrTextRunningIntoTheCardHasNoTrim() {
        XCTAssertNil(QARenderSnapshot.alignedTrim(rows: [.ink, .blank, .ink], scale: 3),
                     "no card in view")
        XCTAssertNil(QARenderSnapshot.alignedTrim(rows: [.ink, .ink, .ink, .card], scale: 3),
                     "no background between the text and the card")
        XCTAssertNil(QARenderSnapshot.alignedTrim(rows: [.card], scale: 0))
    }

    func testOnlyTheLastPetPageIsRefusedNotAnAlignedOverview() {
        let aligned = QARenderStoreShot(id: "09_x", screen: "x", surface: .demo(.overview),
                                        page: .lastAligned, companionPanel: false)
        XCTAssertNil(QARenderSnapshot.storeSurfaceProblem(aligned))
        let pet = QARenderStoreShot(id: "09_x", screen: "x", surface: .demo(.pet),
                                    page: .lastAligned, companionPanel: false)
        XCTAssertNotNil(QARenderSnapshot.storeSurfaceProblem(pet))
    }

    func testEveryStoreShotIsFreeOfUIThatDiffersInTheMacAppStoreBuild() {
        for shot in QARenderSnapshot.storeCatalog {
            XCTAssertNil(QARenderSnapshot.storeSurfaceProblem(shot))
        }
    }

    func testTheStoreRuleRefusesEverySurfaceThatDiffers() {
        func shot(_ surface: QARenderSurface, page: QARenderStoreShot.Page = .first,
                  panel: Bool = false) -> QARenderStoreShot {
            QARenderStoreShot(id: "09_x", screen: "x", surface: surface, page: page, companionPanel: panel)
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
            shot(.demo(.alerts), panel: true),
        ]
        for candidate in refused {
            XCTAssertNotNil(
                QARenderSnapshot.storeSurfaceProblem(candidate),
                "\(candidate.surface.id) page \(candidate.page) panel \(candidate.companionPanel)"
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
            id: "04_cost", surface: "demo-overview", page: .lastAligned, pageIndex: 3,
            pageCount: 3, file: "04_cost.png", md5: "89ab", popoverHeight: 551
        )]
        let data = try manifest.encoded()
        XCTAssertEqual(try JSONDecoder().decode(QARenderManifest.self, from: data), manifest)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"set\" : \"store\""), text)
        XCTAssertTrue(text.contains("\"devidBuild\" : false"), text)
        XCTAssertTrue(text.contains("\"page\" : \"lastAligned\""), text)
        XCTAssertTrue(text.contains("\"popoverHeight\" : 551"), text)
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
        for surface: QARenderSurface in [.about, .subscription, .usageDashboardPanel, .firstRunWelcome] {
            XCTAssertTrue(catalog.contains(surface), "\(surface.id) is not rendered")
        }
        for kind in QARenderSnapshot.providerEditorKinds {
            XCTAssertTrue(catalog.contains(.providerEditor(kind)))
        }
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
        let data = try manifest.encoded()
        XCTAssertEqual(try JSONDecoder().decode(QARenderManifest.self, from: data), manifest)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"한국어\""), "non-Latin text must stay readable in the manifest")
        let app = try XCTUnwrap(text.range(of: "\"app\""))
        let language = try XCTUnwrap(text.range(of: "\"language\""))
        XCTAssertLessThan(app.lowerBound, language.lowerBound, "keys must be sorted")
    }
}
