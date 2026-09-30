import Foundation

/// The plan for the QA build's offscreen renders of the macOS views: one run
/// per shipped language, each writing PNGs of the real views and a JSON
/// manifest, so a native speaker can review the Mac app without anyone
/// driving it on a screen.
///
/// Only the plan lives here — which launches may ask for it, which views are
/// drawn in what order, what the files are called, and what the manifest
/// says. The renderer that hosts the views is in the app target
/// (`QASnapshotRenderer.swift`), because the views live there, and it is
/// compiled only into the `Debug QA` configuration (`CLIPULSE_QA_RENDER`).
/// Nothing in this file draws, reads or writes a file, so a Release build
/// that carries it carries inert data.
///
/// How to run it: `docs/qa/macos-offscreen-renders.md`.
public enum QARenderSnapshot {

    // MARK: - Launch arguments

    /// `-CLIPulseRenderSnapshots <absolute output directory>` asks for a run.
    public static let outputArgument = "-CLIPulseRenderSnapshots"
    /// Optional `-CLIPulseRenderAppearance light|dark`; light by default.
    public static let appearanceArgument = "-CLIPulseRenderAppearance"
    /// The app's own language override, passed through the argument domain so
    /// the run never writes the choice into anyone's defaults.
    public static let localeOverrideArgument = "-" + LocaleOverrideStore.defaultsKey
    /// What AppKit and Foundation read the process language from.
    public static let appleLanguagesArgument = "-AppleLanguages"

    /// Optional `-CLIPulseRenderSet review|store`; `review` by default.
    public static let setArgument = "-CLIPulseRenderSet"

    public enum Appearance: String, CaseIterable, Codable, Sendable {
        case light
        case dark
    }

    /// Which surfaces a run draws.
    public enum RenderSet: String, CaseIterable, Codable, Sendable {
        /// Every surface in `catalog`, for native review of the Mac app.
        case review
        /// The Mac App Store screenshots: `storeCatalog` only, surfaces whose
        /// visible UI is the same in the QA render and in the Mac App Store
        /// build. See docs/qa/macos-offscreen-renders.md, "The store set".
        case store

        /// Pixels per point. The store set is drawn at 3x, so the App Store
        /// panel downscales it rather than blowing up a 2x render.
        public var scale: Int {
            switch self {
            case .review: return 2
            case .store: return 3
            }
        }

        /// The manifest's file name in the output directory.
        public var manifestFileName: String {
            switch self {
            case .review: return "manifest.json"
            case .store: return "render.json"
            }
        }
    }

    public struct Request: Equatable, Sendable {
        public let outputDirectory: URL
        public let language: String
        public let appearance: Appearance
        public let set: RenderSet

        public init(
            outputDirectory: URL,
            language: String,
            appearance: Appearance,
            set: RenderSet = .review
        ) {
            self.outputDirectory = outputDirectory
            self.language = language
            self.appearance = appearance
            self.set = set
        }

        /// Every render of this run is drawn at this backing scale.
        public var scale: Int { self.set.scale }
    }

    public enum Resolution: Equatable, Sendable {
        /// No render was asked for: start the app as usual.
        case notRequested
        /// A render was asked for and cannot be honoured. The process must
        /// exit with the reason rather than start the app, so a mistyped
        /// argument never becomes an ordinary launch on someone's screen.
        case refused(String)
        case render(Request)
    }

    /// Decides what a launch with these arguments does.
    ///
    /// The checks are the contract the renderer relies on:
    /// * only the QA build, launched with its isolated home, may render —
    ///   the same `isQA && isLaunchSafe` test that guards every QA launch;
    /// * the language comes from BOTH the app's override and `AppleLanguages`,
    ///   and they must agree, so app strings (CLIPulseCore's catalogue) and
    ///   framework strings (AppKit, formatters) are in the same language;
    /// * each argument appears once, because which duplicate the argument
    ///   domain keeps is not something to depend on.
    public static func resolve(
        arguments: [String],
        runtime: CLIPulseRuntimeEnvironment
    ) -> Resolution {
        let parsed = ArgumentScan(arguments)
        guard parsed.count(of: outputArgument) > 0 else {
            return .notRequested
        }
        guard runtime.isQA, runtime.isLaunchSafe else {
            return .refused(
                "offscreen rendering exists only in the QA build, launched with "
                    + "CFFIXED_USER_HOME inside /private/tmp/clipulse-qa-home"
            )
        }
        for argument in [
            outputArgument, localeOverrideArgument,
            appleLanguagesArgument, appearanceArgument, setArgument,
        ] where parsed.count(of: argument) > 1 {
            return .refused("\(argument) is given more than once")
        }
        guard let output = parsed.value(of: outputArgument), !output.isEmpty else {
            return .refused("\(outputArgument) needs an output directory")
        }
        guard (output as NSString).isAbsolutePath else {
            return .refused("\(outputArgument) needs an absolute path, got \(output)")
        }
        guard let language = parsed.value(of: localeOverrideArgument) else {
            return .refused(
                "\(localeOverrideArgument) <language> is required, so the "
                    + "app's own strings are in the language being rendered"
            )
        }
        guard LocaleOverrideStore.shippedLocalizations.contains(language) else {
            return .refused(
                "\(language) is not a shipped localization ("
                    + LocaleOverrideStore.shippedLocalizations.joined(separator: ", ")
                    + ")"
            )
        }
        guard let rawLanguages = parsed.value(of: appleLanguagesArgument),
              let appleLanguages = appleLanguagesList(rawLanguages),
              let first = appleLanguages.first
        else {
            return .refused(
                "\(appleLanguagesArgument) \"(\(language))\" is required, so "
                    + "AppKit and formatters use the language being rendered"
            )
        }
        guard first == language else {
            return .refused(
                "\(appleLanguagesArgument) starts with \(first) but "
                    + "\(localeOverrideArgument) is \(language)"
            )
        }
        var appearance = Appearance.light
        if parsed.count(of: appearanceArgument) > 0 {
            guard let raw = parsed.value(of: appearanceArgument),
                  let chosen = Appearance(rawValue: raw)
            else {
                return .refused(
                    "\(appearanceArgument) must be one of "
                        + Appearance.allCases.map(\.rawValue).joined(separator: ", ")
                )
            }
            appearance = chosen
        }
        var set = RenderSet.review
        if parsed.count(of: setArgument) > 0 {
            guard let raw = parsed.value(of: setArgument),
                  let chosen = RenderSet(rawValue: raw)
            else {
                return .refused(
                    "\(setArgument) must be one of "
                        + RenderSet.allCases.map(\.rawValue).joined(separator: ", ")
                )
            }
            set = chosen
        }
        return .render(Request(
            outputDirectory: URL(fileURLWithPath: output, isDirectory: true)
                .standardizedFileURL,
            language: language,
            appearance: appearance,
            set: set
        ))
    }

    /// `AppleLanguages` as the argument domain reads it: an old-style
    /// property-list array such as `(zh-Hant)` or `("zh-Hant", en)`. A bare
    /// string is not an array, and the system does not treat it as a list.
    static func appleLanguagesList(_ raw: String) -> [String]? {
        guard let list = try? PropertyListSerialization.propertyList(
            from: Data(raw.utf8), options: [], format: nil
        ) as? [String], !list.isEmpty else {
            return nil
        }
        return list
    }

    /// `-key value` pairs in the order given. A value is the next argument
    /// unless that is another `-key`.
    private struct ArgumentScan {
        private var pairs: [(key: String, value: String?)] = []

        init(_ arguments: [String]) {
            var index = arguments.startIndex
            if index < arguments.endIndex { index += 1 }  // argv[0]
            while index < arguments.endIndex {
                let argument = arguments[index]
                guard argument.hasPrefix("-") else {
                    index += 1
                    continue
                }
                let next = index + 1
                if next < arguments.endIndex, !arguments[next].hasPrefix("-") {
                    pairs.append((argument, arguments[next]))
                    index += 2
                } else {
                    pairs.append((argument, nil))
                    index += 1
                }
            }
        }

        func count(of key: String) -> Int {
            pairs.filter { $0.key == key }.count
        }

        func value(of key: String) -> String? {
            pairs.first { $0.key == key }?.value
        }
    }

    // MARK: - What is drawn

    /// The production first-run wizard (`LegacyOnboardingWizardView`) has
    /// this many steps: welcome, features, privacy, sign-in, pair.
    public static let legacyOnboardingStepCount = 5

    /// The signed-out shell's tabs worth drawing: the ones whose empty state
    /// differs from the demo's. Machine and Pet do not depend on sign-in.
    public static let signedOutTabs: [AppState.Tab] = [
        .overview, .providers, .sessions, .alerts, .settings,
    ]

    /// The provider editor is drawn for the kinds the QA build seeds
    /// accounts for (`QAExperienceSeed`).
    public static let providerEditorKinds: [ProviderKind] = [.codex, .claude, .gemini]

    /// Every surface, in drawing order. The order is also the state order:
    /// everything signed out comes before Demo mode is entered, because the
    /// renderer, like the app, has no way back out of it.
    public static var catalog: [QARenderSurface] {
        var surfaces: [QARenderSurface] = [.firstLaunch]
        surfaces += (0..<legacyOnboardingStepCount).map { .legacyOnboarding(step: $0) }
        surfaces += AgentSetupStep.allCases
            .filter { $0 != .completed }
            .map { .onboarding($0) }
        surfaces += QARenderFinishMode.allCases.map { .onboardingFinished($0) }
        surfaces.append(.localScanConsent)
        surfaces.append(.localScanConsentOlderLogs)
        surfaces += signedOutTabs.map { .signedOut($0) }
        surfaces.append(.signedOutPasswordSignIn)
        surfaces += AppState.Tab.visibleCases
            .filter { $0 != .settings }
            .map { .demo($0) }
        surfaces += QARenderSettingsSection.allCases.map { .demoSettings($0) }
        surfaces += [.demoUpgradePrompt, .demoAgentSetupRerun]
        surfaces += [.about, .subscription]
        surfaces += providerEditorKinds.map { .providerEditor($0) }
        surfaces += [.usageDashboardPanel, .firstRunWelcome]
        return surfaces
    }

    /// `01-first-launch.png`, and `01-first-launch-p2.png` for the second
    /// page of a view taller than its window.
    public static func fileName(index: Int, surface: QARenderSurface, page: Int) -> String {
        let number = String(format: "%02d", index + 1)
        let suffix = page > 1 ? "-p\(page)" : ""
        return "\(number)-\(surface.id)\(suffix).png"
    }

    // MARK: - The store set

    /// The Mac App Store screenshots, in listing order. `id` is the file stem
    /// the App Store pipeline uses (`NN_<screen>`, scripts/appstore_screenshots.py
    /// MAC SCREENS names the same six in the same order).
    ///
    /// Only surfaces whose visible UI does not depend on anything that differs
    /// between the QA render (Debug, unsandboxed, channel `qa`) and the Mac App
    /// Store build (Release, sandboxed, production): `storeSurfaceProblem`
    /// says which, and why the others are left out.
    public static var storeCatalog: [QARenderStoreShot] {
        let rows: [(String, QARenderSurface, QARenderStoreShot.Page, Bool)] = [
            ("overview", .demo(.overview), .first, false),
            ("providers", .demo(.providers), .first, false),
            ("usage_history", .demo(.overview), .first, true),
            ("cost", .demo(.overview), .lastAligned, false),
            ("alerts", .demo(.alerts), .first, false),
            ("pulse_cat", .demo(.pet), .first, false),
        ]
        return rows.enumerated().map { offset, row in
            let number = offset + 1
            return QARenderStoreShot(
                id: (number < 10 ? "0" : "") + "\(number)_\(row.0)",
                screen: row.0,
                surface: row.1,
                page: row.2,
                companionPanel: row.3
            )
        }
    }

    /// The tabs a store shot may show. Every other popover surface differs in
    /// the Mac App Store build, or sells something it does not have:
    /// * Sessions: offers helper control of Claude sessions and, unsandboxed,
    ///   the in-app terminal; the Mac App Store build ships neither.
    /// * Machine: reads a helper the QA build refuses, and shows another
    ///   affordance under the sandbox.
    /// * Settings: hides Companion CLI in QA (shown in the Mac App Store build),
    ///   and its account and helper rows are not the store build's.
    /// * setup and signed-out pages: the QA build turns setup v2 on.
    public static let storeTabs: Set<AppState.Tab> = [.overview, .providers, .alerts, .pet]

    /// Why `shot` may not be in the store set, or nil when it may. A
    /// diagnostic for the QA renderer's log and the tests, never shown in the
    /// app (hardcoded_ui_strings_baseline.json).
    public static func storeSurfaceProblem(_ shot: QARenderStoreShot) -> String? {
        guard case .demo(let tab) = shot.surface else {
            return "\(shot.id): \(shot.surface.id) is not a Demo-mode popover tab, and setup, signed-out, Settings, window and menu surfaces differ in the Mac App Store build"
        }
        guard storeTabs.contains(tab) else {
            return "\(shot.id): the \(tab.rawValue) tab differs in the Mac App Store build (helper, sandbox or QA-channel UI)"
        }
        if tab == .pet, shot.page != .first {
            return "\(shot.id): only the Pet tab's first page is free of the Debug build's test buttons at the bottom of the tab"
        }
        if shot.companionPanel, tab != .overview {
            return "\(shot.id): the usage panel slides out of the Overview's Activity card"
        }
        return nil
    }

    /// The popover's size in points: `MenuBarView` is 380 wide, and 580 high
    /// unless the user dragged it (400–900). The store set pins the default,
    /// except for a `.lastAligned` page, which shortens it (`alignedTrim`).
    public static let storePopoverWidth = 380.0
    public static let storePopoverHeight = 580.0
    /// The shortest popover `MenuBarView` lets the user drag it to.
    public static let storePopoverMinHeight = 400.0
    /// Points a `.lastAligned` page keeps between its top edge and the card
    /// it opens on: inside the 12 points the Overview's stack leaves between
    /// cards, so the edge cuts through neither.
    public static let storeAlignedClearance = 4.0
    /// The usage panel's see-through HUD backdrop has nothing behind it
    /// offscreen; the renderer blends it within the window, over the panel's
    /// dark fill, as it blends over a desktop. Relative luminance (0...1) of
    /// the backdrop above which that did not work and it drew as a flat gray
    /// slab (the #600 and first store renders measured about 0.36).
    public static let storePanelMaxBackdropLuminance = 0.25
    /// The usage panel's width: `DashboardPanelController` uses
    /// `min(520, max(440, room to the left of the popover))`, which is 520
    /// whenever the popover sits at the right of an ordinary screen.
    public static let storePanelWidth = 520.0
    /// The panel's headline counts up for 2.2 s (`CountUpNumber`); the panel
    /// is drawn no sooner than this after it appears.
    public static let storePanelSettleSeconds = 3.0

    // MARK: - The store set's local usage history

    /// What `CostUsageScanner` records, and so all the local-scan archive
    /// behind the Overview's Activity card and the usage panel can hold.
    public static let storeLocalScanProviders: Set<String> = ["Claude", "Codex"]
    public static let storeLocalScanDays = 365
    /// The home every QA render runs in (`CFFIXED_USER_HOME` below it). The
    /// store set writes its sample local history only inside it.
    public static let qaHomeRoot = "/private/tmp/clipulse-qa-home"

    /// A year of local usage history for the store set, in the shape the
    /// scanner produces: Claude and Codex only, per model, plus Claude's
    /// message-count bucket (`ScanEntry.messageBucketModel`), which is where
    /// the dashboard's MESSAGES count comes from. The days and the numbers are
    /// the Demo archive's (`DemoDataProvider.dailyUsage`) without Gemini, so
    /// today's Codex and Claude figures are the Demo dashboard's own (85.9K /
    /// $1.03 and 24.8K / $0.37). Deterministic: the same day renders the same.
    public static func storeLocalScanSample(
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> [ScanEntry] {
        var entries: [ScanEntry] = []
        for row in DemoDataProvider.dailyUsage(days: storeLocalScanDays, today: today, calendar: calendar)
        where storeLocalScanProviders.contains(row.provider) {
            entries.append(ScanEntry(
                date: row.date, provider: row.provider, model: row.model,
                inputTokens: row.inputTokens, cachedTokens: row.cachedTokens,
                outputTokens: row.outputTokens, cost: row.cost, messages: 0
            ))
            if row.provider == "Claude" {
                let tokens = row.inputTokens + row.cachedTokens + row.outputTokens
                entries.append(ScanEntry(
                    date: row.date, provider: "Claude", model: ScanEntry.messageBucketModel,
                    inputTokens: 0, cachedTokens: 0, outputTokens: 0, cost: 0,
                    messages: max(1, tokens / 190)
                ))
            }
        }
        return entries
    }

    /// The sample as the archive holds it after a scan merge.
    public static func storeLocalScanArchive(
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> DailyUsageArchive {
        var archive = DailyUsageArchive()
        archive.mergeScanEntries(storeLocalScanSample(today: today, calendar: calendar))
        return archive
    }

    /// Why `archive` is not a local-scan history the store set may show, or
    /// empty. The renderer checks the archive the app itself loaded, before
    /// and after drawing, so a provider the scanner never records (Gemini, in
    /// the Demo archive) cannot reach a panel captioned "Claude + Codex local
    /// history".
    public static func storeLocalScanProblems(_ archive: DailyUsageArchive) -> [String] {
        var problems: [String] = []
        if archive.days.isEmpty {
            problems.append("the local usage history is empty, so the Activity card says so")
        }
        let providers = Set(archive.days.values.flatMap { $0.perProvider.keys })
        let foreign = providers.subtracting(storeLocalScanProviders).sorted()
        if !foreign.isEmpty {
            problems.append(
                "the local usage history holds \(foreign.joined(separator: ", ")), which the "
                    + "scanner never records (only \(storeLocalScanProviders.sorted().joined(separator: " and ")))"
            )
        }
        if DailyUsageStats.totalMessages(archive) <= 0 {
            problems.append("the local usage history has no messages, so MESSAGES reads 0")
        }
        return problems
    }

    // MARK: - Scrolling

    /// A view taller than its window is drawn as at most this many pages.
    public static let maxPages = 12

    /// Consecutive pages overlap by this much, so a line cut at the bottom of
    /// one page is whole at the top of the next.
    public static let pageOverlap = 48.0

    /// Where the next page starts, measured from the top of the content, or
    /// nil when the page at `offset` already reaches the bottom. The last page
    /// ends flush with the bottom of the content.
    ///
    /// Asked again after every scroll, with the content height measured
    /// again, because a lazy stack grows as it is scrolled.
    public static func nextPageOffset(
        after offset: Double,
        contentHeight: Double,
        viewportHeight: Double,
        overlap: Double = pageOverlap
    ) -> Double? {
        guard viewportHeight > 0 else { return nil }
        let last = contentHeight - viewportHeight
        guard last > offset + 1 else { return nil }
        let step = max(viewportHeight - overlap, viewportHeight / 2)
        return min(offset + step, last)
    }

    /// Every page offset for content of a fixed height, capped at `maxPages`
    /// (the cap keeps the last page flush with the bottom).
    public static func pageOffsets(
        contentHeight: Double,
        viewportHeight: Double,
        overlap: Double = pageOverlap,
        maxPages: Int = QARenderSnapshot.maxPages
    ) -> [Double] {
        var offsets: [Double] = [0]
        while let next = nextPageOffset(
            after: offsets[offsets.count - 1],
            contentHeight: contentHeight,
            viewportHeight: viewportHeight,
            overlap: overlap
        ) {
            offsets.append(next)
        }
        guard offsets.count > maxPages, maxPages > 1 else {
            return offsets.count > maxPages ? [0] : offsets
        }
        return Array(offsets.prefix(maxPages - 1)) + [offsets[offsets.count - 1]]
    }

    // MARK: - Framing a page scrolled to the end

    /// How many whole points to take off the popover's height so that the
    /// page scrolled to the end opens `clearance` points above `alignedCard`:
    /// where the first page left off, so it neither repeats a card the first
    /// page already showed whole nor opens through the card, or the line of
    /// text, above that one.
    ///
    /// `cards` are the view's cards and `contentHeight` its scrolling
    /// content's height, all in points from the top of the content;
    /// `viewportHeight` is how much of it one page shows at the pinned
    /// popover height. The first page shows the content from 0 down to
    /// `viewportHeight`, and the last page ends flush with the content, so
    /// shortening the popover by `t` points moves its top edge `t` points down
    /// the content. 0 when the card already starts within `clearance` below
    /// the edge; nil when there is no such card.
    ///
    /// Cards, not pixels: the Overview's cards cast shadows that fill the
    /// 12 points between them, so no row of pixels there is plain background
    /// and a page cannot be split into cards and gaps by colour (1.55's
    /// Overview, whose last page opened on the bottom edge of the Activity
    /// card, read as a single card from the top edge down).
    public static func alignedTrim(
        cards: [QARenderSpan],
        contentHeight: Double,
        viewportHeight: Double,
        clearance: Double = storeAlignedClearance
    ) -> Int? {
        guard let card = alignedCard(cards, contentHeight: contentHeight, viewportHeight: viewportHeight)
        else { return nil }
        let room = card.top - lastPageTop(contentHeight: contentHeight, viewportHeight: viewportHeight)
        return max(0, Int((room - clearance).rounded(.down)))
    }

    /// The card a `.lastAligned` page opens on: the highest one that reaches
    /// below the first page (which shows the content from 0 down to
    /// `viewportHeight`) and starts at or below the last page's top edge,
    /// where a shorter popover can bring that edge. nil when every card fits
    /// on the first page, or the last page already starts inside the last
    /// card.
    public static func alignedCard(
        _ cards: [QARenderSpan], contentHeight: Double, viewportHeight: Double
    ) -> QARenderSpan? {
        guard viewportHeight > 0 else { return nil }
        let lastTop = lastPageTop(contentHeight: contentHeight, viewportHeight: viewportHeight)
        return cards
            .filter { $0.bottom > viewportHeight + spanTolerance && $0.top >= lastTop - spanTolerance }
            .min { $0.top < $1.top }
    }

    /// Where the page scrolled to the end starts, in points from the top of
    /// the content: it ends flush with the content.
    public static func lastPageTop(contentHeight: Double, viewportHeight: Double) -> Double {
        max(0, contentHeight - viewportHeight)
    }

    /// The drawn things a page's top edge, `top` points down the content,
    /// cuts through: each starts above it and ends below it.
    public static func cutByTopEdge(_ top: Double, spans: [QARenderSpan]) -> [QARenderSpan] {
        spans.filter { $0.top < top - spanTolerance && $0.bottom > top + spanTolerance }
    }

    /// Half a pixel at the store set's scale: layout rounds frames to pixels.
    static let spanTolerance = 0.5 / 3

    // MARK: - Checking a render

    /// Whether sampled pixels look like nothing was drawn: fewer than three
    /// distinct colours once each channel is reduced to five bits. Any line
    /// of anti-aliased text produces far more than that.
    public static func looksBlank(rgbaSamples: [UInt32]) -> Bool {
        var colours = Set<UInt32>()
        for pixel in rgbaSamples {
            colours.insert(pixel & 0xF8F8_F8F8)
            if colours.count >= 3 { return false }
        }
        return true
    }

    /// Catalogue keys whose value in the rendered language, next to English,
    /// shows the catalogue was really loaded: a missing `.lproj` falls back to
    /// English copy, which a picture of English text would not reveal.
    public static let probeKeys = [
        "tab.overview", "tab.settings", "language.title",
        "language.system_default", "onboarding_wizard.welcome_title",
    ]

    public static func localizationProbe() -> [QARenderManifest.Probe] {
        probeKeys.map { key in
            QARenderManifest.Probe(
                key: key,
                value: L10n.resolve(key),
                english: LocaleOverrideStore.englishBundle.map {
                    NSLocalizedString(key, bundle: $0, comment: "")
                } ?? key
            )
        }
    }

    /// True when the probes show the language is in effect: English trivially,
    /// any other language when at least one probe is not its English value.
    public static func localizationIsActive(
        language: String, probes: [QARenderManifest.Probe]
    ) -> Bool {
        language == "en" || probes.contains { $0.value != $0.english }
    }
}

/// Which completion text the setup wizard's last page shows.
public enum QARenderFinishMode: String, CaseIterable, Sendable {
    case localOnly = "local"
    case sync
}

/// The four Settings sections behind the segmented picker
/// (`SettingsTab.SettingsSection` in the app target). The renderer maps them
/// by raw value and reports any section this list does not name.
public enum QARenderSettingsSection: String, CaseIterable, Sendable {
    case general = "General"
    case display = "Display"
    case providers = "Providers"
    case advanced = "Advanced"
}

/// One view the renderer draws.
public enum QARenderSurface: Hashable {
    /// What a new install shows the first time the menu is opened: the
    /// anonymous-statistics notice above the production setup wizard.
    case firstLaunch
    /// The production setup wizard, by step (0-based).
    case legacyOnboarding(step: Int)
    /// Setup v2, behind flags that are off in production and on in QA.
    case onboarding(AgentSetupStep)
    case onboardingFinished(QARenderFinishMode)
    /// Local mode before the user has said whether the Mac may be scanned.
    case localScanConsent
    /// v1.55: a v1 "yes" on file and no answer to disclosure v2 — the
    /// question about reading up to a year of older logs.
    case localScanConsentOlderLogs
    case signedOut(AppState.Tab)
    case signedOutPasswordSignIn
    case demo(AppState.Tab)
    case demoSettings(QARenderSettingsSection)
    /// Setup v2's prompt to existing users (QA flags only).
    case demoUpgradePrompt
    /// Settings with setup v2's "run agent setup again" card (QA flags only).
    case demoAgentSetupRerun
    case about
    case subscription
    case providerEditor(ProviderKind)
    case usageDashboardPanel
    case firstRunWelcome

    public enum Kind: String, Codable, Sendable {
        /// The menu-bar popover (`MenuBarView`), 380 points wide.
        case popover
        /// A window scene of the app.
        case window
        /// A borderless panel the app slides out next to the popover.
        case panel
        /// A picture of a menu's items, drawn from the items (a menu cannot
        /// be drawn without opening it on screen).
        case menu
    }

    public var kind: Kind {
        switch self {
        case .about, .subscription, .providerEditor, .firstRunWelcome:
            return .window
        case .usageDashboardPanel:
            return .panel
        default:
            return .popover
        }
    }

    /// File-name-safe, stable identifier.
    public var id: String {
        switch self {
        case .firstLaunch: return "first-launch"
        case .legacyOnboarding(let step): return "setup-step-\(step + 1)"
        case .onboarding(let step): return "setup-v2-\(Self.slug(step.rawValue))"
        case .onboardingFinished(let mode): return "setup-v2-finished-\(mode.rawValue)"
        case .localScanConsent: return "local-scan-consent"
        case .localScanConsentOlderLogs: return "local-scan-consent-older-logs"
        case .signedOut(let tab): return "signed-out-\(Self.slug(tab.rawValue))"
        case .signedOutPasswordSignIn: return "signed-out-settings-password"
        case .demo(let tab): return "demo-\(Self.slug(tab.rawValue))"
        case .demoSettings(let section): return "demo-settings-\(Self.slug(section.rawValue))"
        case .demoUpgradePrompt: return "demo-setup-v2-upgrade-prompt"
        case .demoAgentSetupRerun: return "demo-settings-setup-v2-rerun"
        case .about: return "window-about"
        case .subscription: return "window-subscription"
        case .providerEditor(let kind): return "window-provider-\(Self.slug(kind.rawValue))"
        case .usageDashboardPanel: return "panel-usage-dashboard"
        case .firstRunWelcome: return "window-first-run-welcome"
        }
    }

    /// Lowercase ASCII words joined by hyphens: `syncMode` → `sync-mode`,
    /// `JetBrains AI` → `jet-brains-ai`, `z.ai` → `z-ai`.
    static func slug(_ raw: String) -> String {
        var slug = ""
        var previous: Character?
        for character in raw {
            guard character.isASCII, character.isLetter || character.isNumber else {
                if !slug.isEmpty, slug.last != "-" { slug.append("-") }
                previous = nil
                continue
            }
            if character.isUppercase,
               let previous, previous.isLowercase || previous.isNumber {
                slug.append("-")
            }
            slug.append(Character(character.lowercased()))
            previous = character
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug
    }
}

/// Where something drawn in a scrolling view lies, in points from the top of
/// the view's content (`QARenderSnapshot.alignedTrim`).
public struct QARenderSpan: Equatable, Sendable {
    public let top: Double
    public let bottom: Double

    public init(top: Double, bottom: Double) {
        self.top = top
        self.bottom = bottom
    }
}

/// One Mac App Store screenshot of the store set (`QARenderSnapshot.storeCatalog`).
public struct QARenderStoreShot: Equatable, Sendable {
    public enum Page: String, Codable, Sendable {
        /// The view as it opens.
        case first
        /// Scrolled to the end, flush with the bottom of the content.
        case last
        /// Scrolled to the end, in a popover shortened so that the top edge
        /// falls just above the first card the first page did not show whole
        /// (`QARenderSnapshot.alignedTrim`): the page starts where the first
        /// one left off, and cuts through nothing. Users drag the popover
        /// anywhere between 400 and 900 points high, so the shorter popover
        /// is a state the app really has; render.json records its height.
        case lastAligned
    }

    /// `01_overview`: the file stem.
    public let id: String
    /// `overview`: the screen name, as scripts/appstore_screenshots.py lists it.
    public let screen: String
    public let surface: QARenderSurface
    public let page: Page
    /// Also draw the usage panel `DashboardPanelController` slides out to the
    /// left of the popover, the one surface only the Mac has.
    public let companionPanel: Bool

    public init(
        id: String, screen: String, surface: QARenderSurface,
        page: Page, companionPanel: Bool
    ) {
        self.id = id
        self.screen = screen
        self.surface = surface
        self.page = page
        self.companionPanel = companionPanel
    }

    public var fileName: String { id + ".png" }
    public var panelFileName: String? { companionPanel ? id + ".panel.png" : nil }
}

/// What a run writes next to its PNGs, as `manifest.json` (the review set)
/// or `render.json` (the store set).
public struct QARenderManifest: Codable, Equatable, Sendable {
    public struct App: Codable, Equatable, Sendable {
        public var bundleIdentifier: String
        public var version: String
        public var build: String

        public init(bundleIdentifier: String, version: String, build: String) {
            self.bundleIdentifier = bundleIdentifier
            self.version = version
            self.build = build
        }
    }

    /// One PNG. What each `id` shows is listed in
    /// docs/qa/macos-offscreen-renders.md.
    public struct Render: Codable, Equatable, Sendable {
        public var id: String
        public var kind: QARenderSurface.Kind
        public var file: String
        public var page: Int
        public var pageCount: Int
        public var width: Double
        public var height: Double
        public var pixelWidth: Int
        public var pixelHeight: Int
        public var suspectBlank: Bool
        public var note: String?

        public init(
            id: String, kind: QARenderSurface.Kind, file: String,
            page: Int, pageCount: Int, width: Double, height: Double,
            pixelWidth: Int, pixelHeight: Int, suspectBlank: Bool, note: String? = nil
        ) {
            self.id = id
            self.kind = kind
            self.file = file
            self.page = page
            self.pageCount = pageCount
            self.width = width
            self.height = height
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.suspectBlank = suspectBlank
            self.note = note
        }
    }

    public struct MenuItem: Codable, Equatable, Sendable {
        public var title: String
        public var checked: Bool
        public var separator: Bool
        public var enabled: Bool

        public init(title: String, checked: Bool, separator: Bool, enabled: Bool) {
            self.title = title
            self.checked = checked
            self.separator = separator
            self.enabled = enabled
        }
    }

    public struct LanguageMenu: Codable, Equatable, Sendable {
        /// `nsmenu` when read from the menu the popover really builds;
        /// `languageOptions-fallback` when it could not be reached offscreen
        /// and the items were rebuilt the way `LanguagePickerMenu` builds them.
        public var source: String
        public var note: String
        public var items: [MenuItem]
        /// A picture of `items`, when one was drawn.
        public var image: String?
        /// The point size AppKit draws the real menu's items in (`NSMenu.font`),
        /// when the menu was read. The picture is drawn from the titles, so it
        /// cannot show this: a control size on the globe button once shrank the
        /// whole menu to 9 pt while every picture looked right.
        public var fontPointSize: Double?

        public init(source: String, note: String, items: [MenuItem], image: String? = nil,
                    fontPointSize: Double? = nil) {
            self.source = source
            self.note = note
            self.items = items
            self.image = image
            self.fontPointSize = fontPointSize
        }
    }

    public struct Probe: Codable, Equatable, Sendable {
        public var key: String
        public var value: String
        public var english: String

        public init(key: String, value: String, english: String) {
            self.key = key
            self.value = value
            self.english = english
        }
    }

    public struct Skipped: Codable, Equatable, Sendable {
        public var id: String
        public var reason: String

        public init(id: String, reason: String) {
            self.id = id
            self.reason = reason
        }
    }

    /// What the build that drew a store set is, measured by that build. The
    /// App Store compositor refuses a set whose facts are not the Mac App
    /// Store build's where they can change what is drawn.
    public struct Variant: Codable, Equatable, Sendable {
        /// Compiled with DEVID_BUILD (the Developer ID build). Must be false:
        /// the store set refuses to run in such a build at all.
        public var devidBuild: Bool
        /// Compiled with DEBUG, as `Debug QA` is. The store catalog holds no
        /// surface whose visible UI depends on it.
        public var debugBuild: Bool
        /// `MASSandboxGate.isSandboxed`. False in the QA build; the store
        /// catalog holds no surface whose visible UI depends on it.
        public var sandboxed: Bool
        public var channel: String
        /// `RemoteControlFeature.isAvailable()`: false in the Mac App Store
        /// build, and must be false here too.
        public var remoteControlAvailable: Bool
        public var popoverWidth: Double
        public var popoverHeight: Double
        public var panelWidth: Double
        /// Seconds the usage panel was left to settle before it was drawn.
        public var panelSettleSeconds: Double
        /// Two drawings of the panel half a second apart were identical.
        public var panelSettled: Bool
        /// The local usage history the app loaded (`DailyUsageArchiveManager`),
        /// read after the last shot was drawn.
        public var localScanDays: Int
        public var localScanProviders: [String]
        public var localScanMessages: Int
        /// `NSScroller.preferredScrollerStyle`: `overlay`, as on a Mac with a
        /// trackpad and the default "Show scroll bars" setting, or `legacy`.
        /// A legacy scroller reserves a gutter the offscreen drawing leaves
        /// empty, so every scrolling tab's content sat off-centre. Must be
        /// `overlay`.
        public var scrollerStyle: String
        /// Relative luminance (0...1) of the usage panel's backdrop as drawn
        /// (`QARenderSnapshot.storePanelMaxBackdropLuminance`).
        public var panelBackdropLuminance: Double

        public init(
            devidBuild: Bool, debugBuild: Bool, sandboxed: Bool, channel: String,
            remoteControlAvailable: Bool, popoverWidth: Double, popoverHeight: Double,
            panelWidth: Double, panelSettleSeconds: Double, panelSettled: Bool,
            localScanDays: Int, localScanProviders: [String], localScanMessages: Int,
            scrollerStyle: String, panelBackdropLuminance: Double
        ) {
            self.devidBuild = devidBuild
            self.debugBuild = debugBuild
            self.sandboxed = sandboxed
            self.channel = channel
            self.remoteControlAvailable = remoteControlAvailable
            self.popoverWidth = popoverWidth
            self.popoverHeight = popoverHeight
            self.panelWidth = panelWidth
            self.panelSettleSeconds = panelSettleSeconds
            self.panelSettled = panelSettled
            self.localScanDays = localScanDays
            self.localScanProviders = localScanProviders
            self.localScanMessages = localScanMessages
            self.scrollerStyle = scrollerStyle
            self.panelBackdropLuminance = panelBackdropLuminance
        }
    }

    /// One store-set PNG: the popover, and for the usage-history shot the
    /// panel beside it, each with its md5 so the compositor can tell that the
    /// committed file is the one this run wrote.
    public struct StoreShot: Codable, Equatable, Sendable {
        public var id: String
        public var surface: String
        public var page: QARenderStoreShot.Page
        /// Which page was drawn (1-based) of how many the view has.
        public var pageIndex: Int
        public var pageCount: Int
        public var file: String
        public var md5: String
        public var panelFile: String?
        public var panelMD5: String?
        /// The popover's height in points when it is not the pinned default:
        /// a `.lastAligned` page's shortened popover.
        public var popoverHeight: Double?

        public init(
            id: String, surface: String, page: QARenderStoreShot.Page,
            pageIndex: Int, pageCount: Int, file: String, md5: String,
            panelFile: String? = nil, panelMD5: String? = nil, popoverHeight: Double? = nil
        ) {
            self.id = id
            self.surface = surface
            self.page = page
            self.pageIndex = pageIndex
            self.pageCount = pageCount
            self.file = file
            self.md5 = md5
            self.panelFile = panelFile
            self.panelMD5 = panelMD5
            self.popoverHeight = popoverHeight
        }
    }

    public var schemaVersion = 1
    public var set: QARenderSnapshot.RenderSet
    /// The store set only.
    public var variant: Variant?
    /// The store set only, in listing order.
    public var shots: [StoreShot]?
    public var language: String
    public var appleLanguages: [String]
    public var localeOverride: String?
    /// The catalogue CLIPulseCore reads (`LocaleOverrideStore.resolvedLocalization`).
    public var resolvedLocalization: String?
    /// The localization AppKit chose for the app bundle.
    public var appKitLocalization: String?
    /// The locale numbers, money and dates are formatted with
    /// (`LocaleOverrideStore.displayLocale`): the rendered language on the
    /// region the run was given (`-AppleLocale`, render_macos_qa_views.sh),
    /// never the region of the Mac it ran on.
    public var displayLocale: String?
    public var localizationActive: Bool
    public var localizationProbe: [Probe]
    public var appearance: QARenderSnapshot.Appearance
    public var scale: Int
    /// The offscreen window's own backing scale, for comparison with `scale`.
    public var windowBackingScale: Double?
    public var app: App
    public var generatedAt: String
    public var dataSource: String
    /// Settings the run changed from their defaults, and why.
    public var forcedSettings: [String: String]
    public var renders: [Render]
    public var languageMenu: LanguageMenu?
    public var skipped: [Skipped]
    /// Requests made through `URLSession.shared` that the renderer refused, as
    /// scheme, host and path. Empty when none were made that way. A session
    /// built from its own configuration (APIClient's, for one) is not covered,
    /// so this is not proof that nothing left the process; watching its
    /// sockets (`lsof -i -p <pid>`) is.
    public var blockedRequests: [String]
    public var warnings: [String]

    public init(
        set: QARenderSnapshot.RenderSet = .review,
        language: String,
        appleLanguages: [String],
        localeOverride: String?,
        resolvedLocalization: String?,
        appKitLocalization: String?,
        displayLocale: String? = nil,
        localizationActive: Bool,
        localizationProbe: [Probe],
        appearance: QARenderSnapshot.Appearance,
        scale: Int,
        windowBackingScale: Double?,
        app: App,
        generatedAt: String,
        dataSource: String,
        forcedSettings: [String: String],
        renders: [Render] = [],
        languageMenu: LanguageMenu? = nil,
        skipped: [Skipped] = [],
        blockedRequests: [String] = [],
        warnings: [String] = []
    ) {
        self.set = set
        self.language = language
        self.appleLanguages = appleLanguages
        self.localeOverride = localeOverride
        self.resolvedLocalization = resolvedLocalization
        self.appKitLocalization = appKitLocalization
        self.displayLocale = displayLocale
        self.localizationActive = localizationActive
        self.localizationProbe = localizationProbe
        self.appearance = appearance
        self.scale = scale
        self.windowBackingScale = windowBackingScale
        self.app = app
        self.generatedAt = generatedAt
        self.dataSource = dataSource
        self.forcedSettings = forcedSettings
        self.renders = renders
        self.languageMenu = languageMenu
        self.skipped = skipped
        self.blockedRequests = blockedRequests
        self.warnings = warnings
    }

    /// Pretty, key-sorted JSON, so two runs diff line by line.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
