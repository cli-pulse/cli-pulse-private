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
                 .localScanConsent, .signedOut, .signedOutPasswordSignIn:
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
