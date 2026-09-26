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

    /// Every render is drawn at this backing scale.
    public static let scale = 2

    public enum Appearance: String, CaseIterable, Codable, Sendable {
        case light
        case dark
    }

    public struct Request: Equatable, Sendable {
        public let outputDirectory: URL
        public let language: String
        public let appearance: Appearance
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
            appleLanguagesArgument, appearanceArgument,
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
        return .render(Request(
            outputDirectory: URL(fileURLWithPath: output, isDirectory: true)
                .standardizedFileURL,
            language: language,
            appearance: appearance
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

/// What a run writes next to its PNGs, as `manifest.json`.
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

        public init(source: String, note: String, items: [MenuItem], image: String? = nil) {
            self.source = source
            self.note = note
            self.items = items
            self.image = image
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

    public var schemaVersion = 1
    public var language: String
    public var appleLanguages: [String]
    public var localeOverride: String?
    /// The catalogue CLIPulseCore reads (`LocaleOverrideStore.resolvedLocalization`).
    public var resolvedLocalization: String?
    /// The localization AppKit chose for the app bundle.
    public var appKitLocalization: String?
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
    /// Requests the renderer refused, as scheme, host and path. Empty when
    /// the run sent nothing.
    public var blockedRequests: [String]
    public var warnings: [String]

    public init(
        language: String,
        appleLanguages: [String],
        localeOverride: String?,
        resolvedLocalization: String?,
        appKitLocalization: String?,
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
        self.language = language
        self.appleLanguages = appleLanguages
        self.localeOverride = localeOverride
        self.resolvedLocalization = resolvedLocalization
        self.appKitLocalization = appKitLocalization
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
