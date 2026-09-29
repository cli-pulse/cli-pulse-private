// QA build only. Every line below is compiled out of Debug, Release, the Mac
// App Store and Developer ID builds: only the app target's `Debug QA`
// configuration defines CLIPULSE_QA_RENDER, and scripts/ci_check_qa_scheme.py
// fails CI if any other configuration does.
#if CLIPULSE_QA_RENDER
import AppKit
import CryptoKit
import SwiftUI
import CLIPulseCore

// MARK: - Entry point

/// Where the QA build starts. Every other build starts at `CLIPulseBarApp`,
/// whose `@main` is compiled out here.
///
/// A launch without `-CLIPulseRenderSnapshots` goes straight to
/// `CLIPulseBarApp.main()`, which is what `@main` on the app would have
/// called. With it, the process draws the Mac views offscreen, writes PNGs and
/// a manifest, and exits without ever becoming a menu-bar app. The launch
/// contract is `QARenderSnapshot.resolve`; how to run it is
/// docs/qa/macos-offscreen-renders.md.
@main
enum CLIPulseQAEntryPoint {
    @MainActor
    static func main() {
        switch QARenderSnapshot.resolve(
            arguments: CommandLine.arguments,
            runtime: .current
        ) {
        case .notRequested:
            CLIPulseBarApp.main()
        case .refused(let reason):
            QASnapshotRenderer.log("refused: \(reason)")
            exit(64)
        case .render(let request):
            QASnapshotRenderer.run(request)
        }
    }
}

// MARK: - View hooks

/// Where a view starts when the renderer draws it, for pages a user reaches
/// by clicking inside a view (a Settings section, a setup page) rather than
/// through app state. Views read it through `qaRenderViewState`; that
/// property and the code reading it exist only in the QA build.
struct QARenderViewState: Equatable {
    /// `LegacyOnboardingWizardView` page, 0-based.
    var legacyOnboardingStep: Int?
    /// `SettingsTab.SettingsSection` raw value.
    var settingsSection: String?
    /// The signed-out sign-in form in its password mode.
    var usePasswordLogin = false
    /// Setup v2: discover accounts on appear, as they would have been for a
    /// user who reached this page through the discovery page.
    var onboardingRunsDiscovery = false
    /// Setup v2: show the finish page, in this mode.
    var onboardingFinish: QARenderFinishMode?
}

private struct QARenderViewStateKey: EnvironmentKey {
    static let defaultValue: QARenderViewState? = nil
}

extension EnvironmentValues {
    var qaRenderViewState: QARenderViewState? {
        get { self[QARenderViewStateKey.self] }
        set { self[QARenderViewStateKey.self] = newValue }
    }
}

// MARK: - Renderer

/// Draws every `QARenderSnapshot.catalog` surface into an offscreen window
/// that is never ordered in, one PNG per page, and writes `manifest.json`.
///
/// What keeps it off the screen of the person using the Mac:
/// * the activation policy is `.prohibited` (no Dock icon, no menu bar, never
///   frontmost), and `CLIPulseBarApp`, which owns the status item, is never
///   created;
/// * windows are created borderless and never ordered in, and no view is
///   drawn that presents a sheet, alert or popover by itself;
/// * views are told they are in the key window (`controlActiveState`), as
///   the open popover is, so SwiftUI-drawn controls such as prominent buttons
///   take their accent colour. AppKit-drawn switches and segmented controls
///   still draw their inactive tint: an app that may never be activated
///   cannot have active controls;
/// * the Alerts tab would ask macOS for notification permission, so
///   notifications are switched off for the run (`forcedSettings`).
///
/// What keeps it off everything else: the QA runtime already refuses the
/// helper, collectors, StoreKit, telemetry, widgets and production endpoints.
/// On top of that, provider status checks are switched off, every request
/// through the shared URL session is refused and listed in the manifest, and
/// the QA defaults domain is emptied for a reproducible run and restored as it
/// was before the process exits.
@MainActor
final class QASnapshotRenderer: NSObject, NSApplicationDelegate {
    private static var current: QASnapshotRenderer?

    nonisolated static func log(_ message: String) {
        FileHandle.standardError.write(Data("[qa-render] \(message)\n".utf8))
    }

    static func run(_ request: QARenderSnapshot.Request) -> Never {
        startWatchdog()
        URLProtocol.registerClass(QARenderRefusingURLProtocol.self)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(
            named: request.appearance == .dark ? .darkAqua : .aqua
        )
        let renderer = QASnapshotRenderer(request: request)
        current = renderer
        app.delegate = renderer
        app.run()
        exit(70)
    }

    /// A hung render must not outlive the shell that started it.
    private static func startWatchdog() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 900) {
            log("watchdog: still running after 15 minutes; exiting")
            exit(70)
        }
    }

    private let request: QARenderSnapshot.Request
    private let defaults = UserDefaults.standard
    private let domain: String
    private var savedDomain: [String: Any]?
    private var domainCleared = false
    /// Created on first use, which `renderAll` makes come after the QA
    /// defaults are emptied: `AppState.init` seeds them.
    private lazy var state = AppState(runtimeEnvironment: .current)
    private var manifest: QARenderManifest
    private var enteredDemo = false

    /// The setup wizard's marker for provider configs it seeded itself
    /// (`OnboardingWizardView.seededConfigsKey`, and
    /// `AgentSetupStateStore.wizardSeededConfigsKey` in CLIPulseCore).
    private static let wizardSeededConfigsKey =
        "cli_pulse_agent_setup_seeded_provider_configs_v2"
    private static let notificationsKey = "cli_pulse_notifications"
    private static let providerStatusKey = "cli_pulse_check_provider_status"

    private init(request: QARenderSnapshot.Request) {
        let domain = Bundle.main.bundleIdentifier ?? "app.clipulse.qa.local"
        self.request = request
        self.domain = domain
        self.manifest = Self.initialManifest(for: request, domain: domain)
    }

    /// What the run knows before it draws anything: the language as the
    /// argument domain, the catalogue and AppKit each see it, and the app.
    private static func initialManifest(
        for request: QARenderSnapshot.Request,
        domain: String
    ) -> QARenderManifest {
        let probe = QARenderSnapshot.localizationProbe()
        let info = Bundle.main.infoDictionary ?? [:]
        let dataSource = request.set == .store
            ? "DemoDataProvider, the same demo data as the iPhone app's Try Demo, entered "
                + "the way the QA build enters local mode, with the five sample accounts "
                + "switched on. The local usage history behind the Activity card and the "
                + "usage panel is QARenderSnapshot.storeLocalScanSample (Claude and Codex, "
                + "what the scanner records), written into the QA home before the app read it."
            : "Setup and signed-out screens: the QA build's five sample "
                + "accounts (QAExperienceSeed). Everything after: DemoDataProvider, the "
                + "same demo data as the iPhone app's Try Demo, entered the way the QA "
                + "build enters local mode (continueWithoutAccount), with all five "
                + "sample accounts switched on as finishing setup with them would."
        return QARenderManifest(
            set: request.set,
            language: request.language,
            appleLanguages: UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? [],
            localeOverride: LocaleOverrideStore.shared.override,
            resolvedLocalization: LocaleOverrideStore.resolvedLocalization,
            appKitLocalization: Bundle.main.preferredLocalizations.first,
            displayLocale: LocaleOverrideStore.shared.displayLocale.identifier,
            localizationActive: QARenderSnapshot.localizationIsActive(
                language: request.language, probes: probe
            ),
            localizationProbe: probe,
            appearance: request.appearance,
            scale: request.scale,
            windowBackingScale: nil,
            app: .init(
                bundleIdentifier: domain,
                version: info["CFBundleShortVersionString"] as? String ?? "",
                build: info["CFBundleVersion"] as? String ?? ""
            ),
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            dataSource: dataSource,
            forcedSettings: [
                notificationsKey: "false: the Alerts tab would otherwise ask macOS "
                    + "for notification permission, a prompt on the screen of whoever "
                    + "is using the Mac. Settings > General shows the switch off.",
                providerStatusKey: "false: provider status badges would otherwise "
                    + "fetch public status pages. They draw nothing unless a provider "
                    + "has an incident.",
            ]
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let status: Int32
            switch self.request.set {
            case .review: status = await self.renderAll()
            case .store: status = await self.renderStore()
            }
            self.restoreDefaults()
            Self.log("done, exit \(status)")
            exit(status)
        }
    }

    // MARK: Run

    /// What every run does before it draws: an empty output directory, the
    /// language in effect, and empty QA defaults. An exit status when the run
    /// cannot go on, nil when it can.
    private func beginRun() -> Int32? {
        guard prepareOutputDirectory() else { return 73 }

        let language = request.language
        guard manifest.localeOverride == language,
              manifest.resolvedLocalization == language,
              manifest.localizationActive
        else {
            Self.log(
                "the \(language) catalogue is not in effect (override "
                    + "\(manifest.localeOverride ?? "none"), resolved "
                    + "\(manifest.resolvedLocalization ?? "none"), probe active "
                    + "\(manifest.localizationActive)); nothing rendered"
            )
            return 65
        }

        // A reproducible run starts from empty QA defaults. The domain is
        // this build's own (`app.clipulse.qa.local`), never production's, and
        // it is put back as it was before the process exits.
        savedDomain = defaults.persistentDomain(forName: domain)
        defaults.removePersistentDomain(forName: domain)
        domainCleared = true
        defaults.set(false, forKey: Self.notificationsKey)
        defaults.set(false, forKey: Self.providerStatusKey)

        if manifest.appKitLocalization != language {
            manifest.warnings.append(
                "AppKit chose \(manifest.appKitLocalization ?? "none") for the app "
                    + "bundle, so text AppKit supplies may not be in \(language)"
            )
        }
        return nil
    }

    private func renderAll() async -> Int32 {
        if let status = beginRun() { return status }
        _ = state  // seeds the emptied defaults
        manifest.skipped = skippedSurfaces()
        checkSettingsSectionCoverage()

        let catalog = QARenderSnapshot.catalog
        for (index, surface) in catalog.enumerated() {
            Self.log("\(index + 1)/\(catalog.count) \(surface.id)")
            await render(surface, index: index)
        }
        await captureLanguageMenu(index: catalog.count)

        manifest.blockedRequests = QARenderRefusingURLProtocol.refused
        if !manifest.blockedRequests.isEmpty {
            manifest.warnings.append(
                "\(manifest.blockedRequests.count) network request(s) were refused; see blockedRequests"
            )
        }
        guard writeManifest() else { return 74 }
        let blank = manifest.renders.filter(\.suspectBlank).map(\.file)
        if !blank.isEmpty {
            Self.log("renders that look blank: \(blank.joined(separator: ", "))")
            return 3
        }
        return manifest.warnings.contains(where: { $0.hasPrefix("coverage:") }) ? 4 : 0
    }

    private func writeManifest() -> Bool {
        let name = request.set.manifestFileName
        do {
            try manifest.encoded().write(
                to: request.outputDirectory.appendingPathComponent(name),
                options: .atomic
            )
            return true
        } catch {
            Self.log("could not write \(name): \(error)")
            return false
        }
    }

    // MARK: The store set

    private static let menuBarHeightKey = "cli_pulse_menubar_height"

    /// The Mac App Store screenshots (`QARenderSnapshot.storeCatalog`): one
    /// PNG per shot, the page it names, at 3x, plus the usage panel beside
    /// the usage-history shot, and `render.json`. Stricter than the review
    /// set: any warning, refused request, blank-looking render or local
    /// history the scanner could not have produced fails the run, because
    /// these files are what the App Store listing is composed from.
    private func renderStore() async -> Int32 {
        #if DEVID_BUILD
        // The store set shows what the Mac App Store build has. A build that
        // compiles the Developer ID-only UI in must not draw it at all.
        Self.log("refused: the store set is drawn only by a build without DEVID_BUILD")
        return 64
        #else
        if let status = beginRun() { return status }
        manifest.forcedSettings[Self.menuBarHeightKey] = "\(Int(QARenderSnapshot.storePopoverHeight)): "
            + "the popover's default height, pinned; users can drag it between 400 and 900."
        defaults.set(QARenderSnapshot.storePopoverHeight, forKey: Self.menuBarHeightKey)
        manifest.skipped = []

        // The sample local history goes in before anything reads the archive:
        // `DailyUsageArchiveManager` loads it once, on first use, and
        // `AppState` is not created yet.
        guard await seedLocalScanArchive() else { return 66 }
        _ = state  // seeds the emptied defaults

        var shots: [QARenderManifest.StoreShot] = []
        var panelSettled = false
        var panelLuminance = 1.0
        for (index, shot) in QARenderSnapshot.storeCatalog.enumerated() {
            if let problem = QARenderSnapshot.storeSurfaceProblem(shot) {
                Self.log("refused: \(problem)")
                return 67
            }
            guard case .demo(let tab) = shot.surface else { return 67 }
            Self.log("\(index + 1)/\(QARenderSnapshot.storeCatalog.count) \(shot.id)")
            enterDemoIfNeeded()
            shapeExistingUser(onboardingV2: false)
            UserDefaultsAnonymousTelemetryStore().hasSeenDisclosure = true
            state.selectedTab = tab
            guard var record = await captureStoreShot(shot) else { continue }
            if shot.companionPanel {
                guard let panel = await captureStorePanel(shot) else { continue }
                record.panelFile = panel.file
                record.panelMD5 = panel.md5
                panelSettled = panel.settled
                panelLuminance = panel.backdropLuminance
            }
            shots.append(record)
        }
        manifest.shots = shots

        let archive = await DailyUsageArchiveManager.shared.snapshot()
        for problem in QARenderSnapshot.storeLocalScanProblems(archive) {
            manifest.warnings.append("local usage history after drawing: \(problem)")
        }
        manifest.variant = .init(
            devidBuild: false,
            debugBuild: Self.isDebugBuild,
            sandboxed: MASSandboxGate.isSandboxed,
            channel: state.runtimeEnvironment.channel.rawValue,
            remoteControlAvailable: RemoteControlFeature.isAvailable(),
            popoverWidth: QARenderSnapshot.storePopoverWidth,
            popoverHeight: QARenderSnapshot.storePopoverHeight,
            panelWidth: QARenderSnapshot.storePanelWidth,
            panelSettleSeconds: QARenderSnapshot.storePanelSettleSeconds,
            panelSettled: panelSettled,
            localScanDays: archive.days.count,
            localScanProviders: Set(archive.days.values.flatMap { $0.perProvider.keys }).sorted(),
            localScanMessages: DailyUsageStats.totalMessages(archive),
            scrollerStyle: NSScroller.preferredScrollerStyle == .overlay ? "overlay" : "legacy",
            panelBackdropLuminance: (panelLuminance * 1000).rounded() / 1000
        )
        if manifest.variant?.scrollerStyle != "overlay" {
            manifest.warnings.append(
                "scroll bars are the legacy style (AppleShowScrollBars), so every scrolling "
                    + "tab reserves a gutter the offscreen drawing leaves empty; render with "
                    + "-AppleShowScrollBars WhenScrolling (render_macos_qa_views.sh does)"
            )
        }
        if panelLuminance > QARenderSnapshot.storePanelMaxBackdropLuminance {
            manifest.warnings.append(
                "the usage panel's backdrop drew at luminance \(panelLuminance), a flat gray "
                    + "rather than the dark HUD it is over a desktop"
            )
        }
        if manifest.variant?.remoteControlAvailable == true {
            manifest.warnings.append("remote control is available in this build; the Mac App Store build has none")
        }
        if !panelSettled {
            manifest.warnings.append("the usage panel was still changing when it was drawn")
        }
        if shots.count != QARenderSnapshot.storeCatalog.count {
            manifest.warnings.append(
                "drew \(shots.count) of \(QARenderSnapshot.storeCatalog.count) store shots"
            )
        }
        manifest.blockedRequests = QARenderRefusingURLProtocol.refused
        if !manifest.blockedRequests.isEmpty {
            manifest.warnings.append(
                "\(manifest.blockedRequests.count) network request(s) were refused; see blockedRequests"
            )
        }
        guard writeManifest() else { return 74 }
        let blank = manifest.renders.filter(\.suspectBlank).map(\.file)
        if !blank.isEmpty {
            Self.log("renders that look blank: \(blank.joined(separator: ", "))")
            return 3
        }
        if !manifest.warnings.isEmpty {
            Self.log("warnings: \(manifest.warnings.joined(separator: " | "))")
            return 5
        }
        return 0
        #endif
    }

    private static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Writes the store set's sample local history where the app reads it,
    /// and only inside the QA home: `CFFIXED_USER_HOME` moves Application
    /// Support there, and this proves it did before anything is written, so
    /// the real user's history is never touched. Then reads it back through
    /// the app's own archive manager.
    private func seedLocalScanArchive() async -> Bool {
        // Compared as realpath(3) gives them: /tmp is a symlink to
        // /private/tmp, and Foundation's own resolving strips /private again.
        let root = QARenderSnapshot.qaHomeRoot + "/"
        let file = DailyUsageArchiveIO.fileURL()
        let directory = file.deletingLastPathComponent()
        do {
            guard let home = Self.realPathOfDeepestExisting(URL(fileURLWithPath: NSHomeDirectory())),
                  (home + "/").hasPrefix(root),
                  let existing = Self.realPathOfDeepestExisting(directory),
                  (existing + "/").hasPrefix(root)
            else {
                throw CocoaError(.fileWriteNoPermission)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let created = Self.realPathOfDeepestExisting(directory),
                  (created + "/").hasPrefix(root)
            else {
                throw CocoaError(.fileWriteNoPermission)
            }
        } catch {
            Self.log(
                "refused: the local usage history would be written to \(file.path), "
                    + "outside \(QARenderSnapshot.qaHomeRoot)"
            )
            return false
        }
        var archive = QARenderSnapshot.storeLocalScanArchive()
        archive.lastUpdatedUnixMs = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        guard DailyUsageArchiveIO.save(archive) else {
            Self.log("could not write the sample local usage history to \(file.path)")
            return false
        }
        let loaded = await DailyUsageArchiveManager.shared.snapshot()
        let problems = QARenderSnapshot.storeLocalScanProblems(loaded)
        guard problems.isEmpty, loaded.days == archive.days else {
            Self.log(
                "the app did not load the sample local usage history: "
                    + (problems.isEmpty ? "it loaded other days" : problems.joined(separator: "; "))
            )
            return false
        }
        return true
    }

    /// realpath(3) of `url`, or of its nearest ancestor that exists.
    private static func realPathOfDeepestExisting(_ url: URL) -> String? {
        var current = url.standardizedFileURL
        while true {
            if let resolved = realpath(current.path, nil) {
                defer { free(resolved) }
                return String(cString: resolved)
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            current = parent
        }
    }

    /// One store shot's popover, the page it names. A `.lastAligned` page is
    /// drawn once at the pinned height to measure what lies above its first
    /// card, then again in a popover shortened by `QARenderSnapshot.alignedTrim`,
    /// and must then open on nothing but background above that card.
    private func captureStoreShot(_ shot: QARenderStoreShot) async -> QARenderManifest.StoreShot? {
        var height = QARenderSnapshot.storePopoverHeight
        guard var drawn = await drawStorePopover(shot) else { return nil }
        if shot.page == .lastAligned {
            guard let trim = alignedTrim(drawn) else {
                manifest.warnings.append(
                    "\(shot.id): no space above a card to start the page in; its top edge "
                        + "would cut through a line of text"
                )
                return nil
            }
            if trim > 0 {
                height -= Double(trim)
                guard height >= QARenderSnapshot.storePopoverMinHeight else {
                    manifest.warnings.append(
                        "\(shot.id): aligning the page needs a \(height)-point popover, "
                            + "under the \(QARenderSnapshot.storePopoverMinHeight) users can set"
                    )
                    return nil
                }
                defaults.set(height, forKey: Self.menuBarHeightKey)
                let again = await drawStorePopover(shot)
                defaults.set(QARenderSnapshot.storePopoverHeight, forKey: Self.menuBarHeightKey)
                guard let again else { return nil }
                drawn = again
                guard alignedTrim(drawn) == 0 else {
                    manifest.warnings.append(
                        "\(shot.id): in a \(height)-point popover the page still does not "
                            + "open on background above its first card"
                    )
                    return nil
                }
            }
        }
        let pageIndex = shot.page == .first ? 1 : drawn.pages.count
        let page = drawn.pages[pageIndex - 1]
        let expected = NSSize(width: QARenderSnapshot.storePopoverWidth, height: height)
        if page.size != expected {
            manifest.warnings.append(
                "\(shot.id): the popover is \(page.size.width)x\(page.size.height) points, "
                    + "not \(expected.width)x\(expected.height)"
            )
        }
        guard let md5 = writeStoreFile(page, name: shot.fileName, id: shot.id, pageIndex: pageIndex,
                                       pageCount: drawn.pages.count, kind: .popover) else {
            return nil
        }
        if height != QARenderSnapshot.storePopoverHeight {
            manifest.forcedSettings[Self.menuBarHeightKey + " (" + shot.id + ")"] = "\(Int(height)): "
                + "this shot's popover, shortened from \(Int(QARenderSnapshot.storePopoverHeight)) "
                + "so the page scrolled to the end opens on the space above a card, not through "
                + "a line of text. Users can drag the popover between 400 and 900."
        }
        return .init(
            id: shot.id, surface: shot.surface.id, page: shot.page,
            pageIndex: pageIndex, pageCount: drawn.pages.count,
            file: shot.fileName, md5: md5,
            popoverHeight: height == QARenderSnapshot.storePopoverHeight ? nil : height
        )
    }

    private struct StorePopover {
        let pages: [NSBitmapImageRep]
        /// The main scroll view's visible area, in points from the top of the
        /// popover: where a page's own content starts and ends.
        let viewport: (top: Double, height: Double)?
    }

    private func drawStorePopover(_ shot: QARenderStoreShot) async -> StorePopover? {
        let root = MenuBarView()
            .environmentObject(state)
            .environmentObject(state.subscriptionManager)
            .environmentObject(state.authState)
            .environmentObject(state.alertState)
            .environmentObject(state.providerState)
            .background(Color(nsColor: .windowBackgroundColor))
        guard let drawn = await drawPages(root, id: shot.id, settle: 0.8) else { return nil }
        drawn.window.contentView = nil
        guard !drawn.pages.isEmpty else {
            manifest.warnings.append("\(shot.id): nothing was drawn")
            return nil
        }
        return StorePopover(pages: drawn.pages, viewport: drawn.viewport)
    }

    /// `QARenderSnapshot.alignedTrim` for the last page, measured on its pixels.
    private func alignedTrim(_ drawn: StorePopover) -> Int? {
        guard let viewport = drawn.viewport, let page = drawn.pages.last else { return nil }
        let rows = pixelRows(page, from: viewport.top, height: viewport.height)
        return QARenderSnapshot.alignedTrim(rows: rows, scale: request.scale)
    }

    /// Each pixel row of `rep` between `top` and `top + height` points,
    /// classified against the colour at its left edge (the scroll view's
    /// background, inside the content's inset).
    private func pixelRows(_ rep: NSBitmapImageRep, from top: Double, height: Double) -> [QARenderRow] {
        let scale = Double(request.scale)
        let first = max(0, Int((top * scale).rounded()))
        let end = min(rep.pixelsHigh, Int(((top + height) * scale).rounded()))
        guard first < end else { return [] }
        let background = rgba(rep, x: 2, y: first)
        return (first..<end).map { y in
            QARenderSnapshot.rowKind((0..<rep.pixelsWide).map { rgba(rep, x: $0, y: y) },
                                     background: background)
        }
    }

    /// One pixel as RGBA, alpha in the low byte; y counts from the top.
    private func rgba(_ rep: NSBitmapImageRep, x: Int, y: Int) -> UInt32 {
        var pixel = [Int](repeating: 0, count: max(4, rep.samplesPerPixel))
        rep.getPixel(&pixel, atX: x, y: y)
        func byte(_ index: Int) -> UInt32 { UInt32(max(0, min(255, pixel[index]))) }
        return byte(0) << 24 | byte(1) << 16 | byte(2) << 8 | (rep.samplesPerPixel > 3 ? byte(3) : 255)
    }

    /// Mean relative luminance (0...1) of the square of `rep` from `x`,`y`
    /// points, `side` points on each side.
    private func luminance(_ rep: NSBitmapImageRep, x: Double, y: Double, side: Double) -> Double {
        let scale = Double(request.scale)
        var total = 0.0
        var count = 0.0
        for py in Int(y * scale)..<min(rep.pixelsHigh, Int((y + side) * scale)) {
            for px in Int(x * scale)..<min(rep.pixelsWide, Int((x + side) * scale)) {
                let p = rgba(rep, x: px, y: py)
                let r = Double(p >> 24 & 0xFF), g = Double(p >> 16 & 0xFF), b = Double(p >> 8 & 0xFF)
                total += (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
                count += 1
            }
        }
        return count > 0 ? total / count : 1
    }

    /// The usage panel as `DashboardPanelController.present` builds it: the
    /// non-scrolling dashboard from the local usage history the app loaded,
    /// 520 points wide, always dark, with its close button. Its see-through
    /// HUD backdrop is blended within the window over an opaque dark fill
    /// (`blendHUDWithinWindow`), and it is drawn only once two drawings half a
    /// second apart agree (the headline counts up).
    private func captureStorePanel(
        _ shot: QARenderStoreShot
    ) async -> (file: String, md5: String, settled: Bool, backdropLuminance: Double)? {
        guard let name = shot.panelFileName else { return nil }
        let archive = await DailyUsageArchiveManager.shared.snapshot()
        let panel = UsageDashboardView(archive: archive, scrollable: false)
            .frame(width: QARenderSnapshot.storePanelWidth)
            .overlay(alignment: .topTrailing) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
            .environment(\.colorScheme, .dark)
            .background(Color(red: 0.11, green: 0.11, blue: 0.12))
        guard let drawn = await drawPages(
            panel, id: name, settle: QARenderSnapshot.storePanelSettleSeconds, scrolls: false,
            prepare: { [weak self] in self?.blendHUDWithinWindow($0, id: name) }
        ), let page = drawn.pages.first else {
            manifest.warnings.append("\(name): nothing was drawn")
            return nil
        }
        await settle(drawn.hosting, seconds: 0.5)
        let again = snapshot(drawn.hosting)
        drawn.window.contentView = nil
        let settled = again.map { Self.sameBitmap($0, page) } ?? false
        if page.size.width != QARenderSnapshot.storePanelWidth {
            manifest.warnings.append("\(name): the panel is \(page.size.width) points wide")
        }
        guard let md5 = writeStoreFile(page, name: name, id: shot.id + "-panel", pageIndex: 1,
                                       pageCount: 1, kind: .panel) else {
            return nil
        }
        // The backdrop between the panel's corner and its title.
        return (name, md5, settled, luminance(page, x: 4, y: 4, side: 6))
    }

    /// `HUDWindowBackground` blends behind the window: over a desktop it is
    /// the dark frosted HUD, but an offscreen window has nothing behind it and
    /// it draws a flat mid-gray. Blending within the window instead puts the
    /// same material over the opaque dark fill the renderer gives the panel.
    private func blendHUDWithinWindow(_ root: NSView, id: String) {
        var changed = 0
        func visit(_ view: NSView) {
            if let effect = view as? NSVisualEffectView {
                effect.blendingMode = .withinWindow
                changed += 1
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        if changed == 0 {
            manifest.warnings.append("\(id): the panel's HUD backdrop was not found")
        }
    }

    private static func sameBitmap(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Bool {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh,
              let left = a.representation(using: .png, properties: [:]),
              let right = b.representation(using: .png, properties: [:])
        else {
            return false
        }
        return left == right
    }

    /// Writes one store PNG and records it in `renders`; its md5, or nil.
    private func writeStoreFile(
        _ page: NSBitmapImageRep, name: String, id: String,
        pageIndex: Int, pageCount: Int, kind: QARenderSurface.Kind
    ) -> String? {
        let url = request.outputDirectory.appendingPathComponent(name)
        do {
            try write(page, to: url)
        } catch {
            manifest.warnings.append("\(name): \(error)")
            return nil
        }
        manifest.renders.append(.init(
            id: id, kind: kind, file: name, page: pageIndex, pageCount: pageCount,
            width: Double(page.size.width), height: Double(page.size.height),
            pixelWidth: page.pixelsWide, pixelHeight: page.pixelsHigh,
            suspectBlank: looksBlank(page)
        ))
        guard let data = try? Data(contentsOf: url) else {
            manifest.warnings.append("\(name): written but unreadable")
            return nil
        }
        return Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func prepareOutputDirectory() -> Bool {
        let fileManager = FileManager.default
        let directory = request.outputDirectory
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let existing = try fileManager.contentsOfDirectory(atPath: directory.path)
                .filter { !$0.hasPrefix(".") }
            guard existing.isEmpty else {
                Self.log(
                    "\(directory.path) is not empty; give each run a new directory "
                        + "so no render from an earlier run is mistaken for this one"
                )
                return false
            }
            return true
        } catch {
            Self.log("cannot use \(directory.path): \(error)")
            return false
        }
    }

    private func restoreDefaults() {
        guard domainCleared else { return }
        if let savedDomain {
            defaults.setPersistentDomain(savedDomain, forName: domain)
        } else {
            defaults.removePersistentDomain(forName: domain)
        }
        defaults.synchronize()
    }

    // MARK: Surfaces

    private func render(_ surface: QARenderSurface, index: Int) async {
        if surface.kind == .popover {
            UserDefaultsAnonymousTelemetryStore().hasSeenDisclosure = surface != .firstLaunch
        }
        switch surface {
        case .firstLaunch:
            shapeNewInstall(onboardingV2: false, progress: nil)
            await capturePopover(surface, index: index)

        case .legacyOnboarding(let step):
            shapeNewInstall(onboardingV2: false, progress: nil)
            await capturePopover(
                surface, index: index,
                viewState: QARenderViewState(legacyOnboardingStep: step)
            )

        case .onboarding(let step):
            await captureOnboardingV2(surface, index: index, step: step, finish: nil)

        case .onboardingFinished(let mode):
            await captureOnboardingV2(surface, index: index, step: .syncMode, finish: mode)

        case .localScanConsent:
            shapeExistingUser(onboardingV2: false)
            state.isLocalMode = true
            await capturePopover(surface, index: index)
            state.isLocalMode = false

        case .signedOut(let tab):
            shapeExistingUser(onboardingV2: false)
            state.selectedTab = tab
            await capturePopover(surface, index: index)

        case .signedOutPasswordSignIn:
            shapeExistingUser(onboardingV2: false)
            state.selectedTab = .settings
            await capturePopover(
                surface, index: index,
                viewState: QARenderViewState(usePasswordLogin: true)
            )

        case .demo(let tab):
            enterDemoIfNeeded()
            shapeExistingUser(onboardingV2: false)
            state.selectedTab = tab
            await capturePopover(surface, index: index)

        case .demoSettings(let section):
            enterDemoIfNeeded()
            shapeExistingUser(onboardingV2: false)
            state.selectedTab = .settings
            await capturePopover(
                surface, index: index,
                viewState: QARenderViewState(settingsSection: section.rawValue)
            )

        case .demoUpgradePrompt:
            enterDemoIfNeeded()
            shapeExistingUser(onboardingV2: true)
            state.selectedTab = .overview
            await capturePopover(surface, index: index)

        case .demoAgentSetupRerun:
            enterDemoIfNeeded()
            shapeExistingUser(onboardingV2: true, completedV2: true)
            state.selectedTab = .settings
            await capturePopover(surface, index: index)

        case .about:
            await captureWindow(
                AboutView(), surface: surface, index: index,
                note: windowNote(L10n.about.title) + " The window hides its title bar."
            )

        case .subscription:
            // A resizable window sized by SwiftUI to a scroll view; the size
            // here is the renderer's choice, and later pages show the rest.
            await captureWindow(
                SubscriptionView(manager: state.subscriptionManager)
                    .frame(width: 460, height: 700),
                surface: surface, index: index,
                note: windowNote(L10n.settings.subscription)
                    + " Drawn at 460x700 points."
            )

        case .providerEditor(let kind):
            guard let config = state.providerConfigs.first(where: { $0.kind == kind }) else {
                manifest.skipped.append(.init(
                    id: surface.id, reason: "no \(kind.rawValue) account in the QA seed"
                ))
                return
            }
            state.editingProviderAccountID = config.accountID
            await captureWindow(
                ProviderConfigWindowContent()
                    .environmentObject(state)
                    .environmentObject(state.subscriptionManager)
                    .environmentObject(state.authState)
                    .environmentObject(state.alertState)
                    .environmentObject(state.providerState),
                surface: surface, index: index,
                note: windowNote(L10n.providerConfig.windowTitle)
                    + " Account: \(config.accountLabel ?? kind.rawValue)."
            )
            state.editingProviderAccountID = nil

        case .usageDashboardPanel:
            enterDemoIfNeeded()
            await state.refreshUsageArchive(force: true)
            await captureUsageDashboardPanel(surface, index: index)

        case .firstRunWelcome:
            await captureWindow(
                FirstRunWelcomeView(onDismiss: {}), surface: surface, index: index,
                note: windowNote(L10n.firstRun.title) + " The title is hidden."
            )
        }
    }

    /// Setup v2 pages. Welcome and privacy exist only for a new install;
    /// discovery onwards is drawn as the existing-user flow, whose discovery
    /// lists all five QA accounts, with three of them chosen.
    private func captureOnboardingV2(
        _ surface: QARenderSurface,
        index: Int,
        step: AgentSetupStep,
        finish: QARenderFinishMode?
    ) async {
        let newUserOnly: Set<AgentSetupStep> = [.welcome, .privacy]
        if newUserOnly.contains(step) {
            shapeNewInstall(
                onboardingV2: true,
                progress: AgentSetupProgress(
                    version: AgentSetupState.currentVersion,
                    step: step,
                    selectedAccountIDs: [],
                    completedAt: nil,
                    origin: .newUser
                )
            )
            await capturePopover(surface, index: index)
            return
        }
        shapeExistingUser(
            onboardingV2: true,
            progress: AgentSetupProgress(
                version: AgentSetupState.currentVersion,
                step: step,
                selectedAccountIDs: chosenAccountIDs(),
                completedAt: nil,
                origin: .existingUserUpgrade
            ),
            upgradePromptDismissed: true
        )
        await capturePopover(
            surface, index: index,
            viewState: QARenderViewState(
                onboardingRunsDiscovery: step != .discovery,
                onboardingFinish: finish
            ),
            note: "Existing-user flow (four pages). "
                + (step == .discovery ? "" : "Accounts discovered as on arrival from the discovery page.")
        )
    }

    /// Codex · Personal and both Claude accounts: two providers, and two
    /// accounts of one provider, which is what the multi-account cards are for.
    private func chosenAccountIDs() -> Set<UUID> {
        let configs = state.providerConfigs
        var chosen = Set(configs.filter { $0.kind == .claude }.map(\.accountID))
        if let codex = configs.first(where: { $0.kind == .codex }) {
            chosen.insert(codex.accountID)
        }
        return chosen
    }

    private func skippedSurfaces() -> [QARenderManifest.Skipped] {
        var skipped: [QARenderManifest.Skipped] = [
            .init(id: "menu-bar-status-item",
                  reason: "The render mode never creates a status item; its label is numbers and an icon."),
            .init(id: "terminal-window",
                  reason: "TerminalAttachView attaches to a running helper session, which the QA build does not have."),
            .init(id: "in-app-terminal-menu",
                  reason: "Offered only by Developer ID builds with live collection."),
            .init(id: "confirmation-alerts",
                  reason: "Remove-account, delete-account, sign-out and git-tracking confirmations are alerts or sheets, which need a window on screen."),
            .init(id: "pet-naming-sheet",
                  reason: "A sheet shown only after a pet hatches."),
            .init(id: "settings-companion-cli",
                  reason: "Hidden in the QA build, which may not install the helper."),
            .init(id: "settings-app-updater",
                  reason: "Developer ID builds only; the QA build is not one."),
            .init(id: "settings-pairing",
                  reason: "Shown to a signed-in account that is not paired, which needs a real sign-in."),
        ]
        if !MacControlRequests.areHonoredByThisBuild {
            skipped.append(.init(
                id: "settings-advanced-mac-control-requests",
                reason: "Advanced shows the Mac control requests switch only in a build that acts on those requests (Developer ID)."
            ))
        }
        if !RemoteControlFeature.isAvailable() {
            skipped.append(.init(
                id: "settings-remote-control",
                reason: "This build does not offer remote control, so Settings has no remote-control card."
            ))
        }
        return skipped
    }

    private func checkSettingsSectionCoverage() {
        let app = Set(SettingsTab.SettingsSection.allCases.map(\.rawValue))
        let drawn = Set(QARenderSettingsSection.allCases.map(\.rawValue))
        if app != drawn {
            manifest.warnings.append(
                "coverage: Settings sections \(app.sorted()) differ from the rendered "
                    + "\(drawn.sorted()); update QARenderSettingsSection"
            )
        }
    }

    /// The window's localized title, which a content-only render leaves out.
    private func windowNote(_ localizedTitle: String) -> String {
        "Window content only; the window's title is \"\(localizedTitle)\"."
    }

    // MARK: App state

    private func setOnboardingV2(_ enabled: Bool) {
        defaults.set(enabled, forKey: AgentSetupFeatureFlags.newUsersDefaultsKey)
        defaults.set(enabled, forKey: AgentSetupFeatureFlags.existingUsersDefaultsKey)
    }

    /// A new install: nothing `AgentSetupStateStore` counts as prior use. The
    /// QA seed's provider configs carry the setup wizard's own marker, as the
    /// configs a new user's wizard seeds do.
    private func shapeNewInstall(onboardingV2: Bool, progress: AgentSetupProgress?) {
        precondition(!enteredDemo, "signed-out surfaces must be drawn before Demo mode")
        setOnboardingV2(onboardingV2)
        defaults.removeObject(forKey: AgentSetupStateStore.legacyCompletedKey)
        defaults.removeObject(forKey: AppState.localModeEnabledKey)
        defaults.removeObject(forKey: LocalScanConsentStore.key)
        defaults.set(true, forKey: Self.wizardSeededConfigsKey)
        saveSetup(progress: progress, legacyCompleted: false,
                  upgradePromptDismissed: false, onboardingV2: onboardingV2)
    }

    /// Someone who has used the app before: the seed's provider configs are
    /// theirs, and the production setup wizard is behind them.
    private func shapeExistingUser(
        onboardingV2: Bool,
        progress: AgentSetupProgress? = nil,
        upgradePromptDismissed: Bool = false,
        completedV2: Bool = false
    ) {
        setOnboardingV2(onboardingV2)
        defaults.removeObject(forKey: Self.wizardSeededConfigsKey)
        defaults.set(true, forKey: AgentSetupStateStore.legacyCompletedKey)
        saveSetup(progress: progress, legacyCompleted: true,
                  upgradePromptDismissed: upgradePromptDismissed, onboardingV2: onboardingV2)
        if completedV2 {
            let store = AgentSetupStateStore()
            var setup = AgentSetupState(
                storedState: store.load(),
                featureFlags: AgentSetupFeatureFlags.load()
            )
            setup.complete()
            store.save(setup)
        }
    }

    private func saveSetup(
        progress: AgentSetupProgress?,
        legacyCompleted: Bool,
        upgradePromptDismissed: Bool,
        onboardingV2: Bool
    ) {
        let store = AgentSetupStateStore()
        store.resetProgress()
        store.save(AgentSetupState(
            storedState: AgentSetupStoredState(
                legacyCompleted: legacyCompleted,
                onboardingVersion: nil,
                progress: progress,
                upgradePromptDismissed: upgradePromptDismissed
            ),
            featureFlags: AgentSetupFeatureFlags(
                newUsersV2: onboardingV2,
                existingUsersV2: onboardingV2
            )
        ))
    }

    /// The QA build's local mode is Demo mode (`RuntimeExperiencePolicy`),
    /// entered the way the app enters it. There is no way back out, which is
    /// why the catalog draws every signed-out surface first.
    ///
    /// All five sample accounts are switched on first, as finishing setup with
    /// them chosen would (`OnboardingWizardView.applySelectedAccounts`), so the
    /// Providers tab and the Settings account list have cards to show. The
    /// seed leaves them off.
    private func enterDemoIfNeeded() {
        guard !enteredDemo else { return }
        var configs = state.providerState.providerConfigs
        for index in configs.indices {
            configs[index].isEnabled = true
        }
        state.providerState.providerConfigs = configs
        _ = state.saveProviderConfigMetadata()
        state.continueWithoutAccount(startRefreshing: false)
        enteredDemo = true
    }

    // MARK: Drawing

    private func capturePopover(
        _ surface: QARenderSurface,
        index: Int,
        viewState: QARenderViewState? = nil,
        note: String? = nil
    ) async {
        // The same root and environment the MenuBarExtra scene gives it. The
        // popover's own background is a window material the offscreen window
        // does not have, so an opaque window background stands in for it.
        let root = MenuBarView()
            .environmentObject(state)
            .environmentObject(state.subscriptionManager)
            .environmentObject(state.authState)
            .environmentObject(state.alertState)
            .environmentObject(state.providerState)
            .environment(\.qaRenderViewState, viewState)
            .background(Color(nsColor: .windowBackgroundColor))
        await capture(root, surface: surface, index: index, note: note)
    }

    private func captureWindow<Content: View>(
        _ content: Content,
        surface: QARenderSurface,
        index: Int,
        note: String?
    ) async {
        await capture(
            content.background(Color(nsColor: .windowBackgroundColor)),
            surface: surface, index: index, note: note
        )
    }

    /// The panel `DashboardPanelController` slides out of the popover, built
    /// the way it builds it: the non-scrolling dashboard at a width between
    /// 440 and 520 points, always dark, with a close button. Its see-through
    /// HUD backdrop is drawn over an opaque dark fill here.
    private func captureUsageDashboardPanel(_ surface: QARenderSurface, index: Int) async {
        let panel = UsageDashboardView(archive: state.usageArchive, scrollable: false)
            .frame(width: 480)
            .overlay(alignment: .topTrailing) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
            .environment(\.colorScheme, .dark)
            .background(Color(red: 0.11, green: 0.11, blue: 0.12))
        await capture(
            panel, surface: surface, index: index,
            prepare: { [weak self] in self?.blendHUDWithinWindow($0, id: surface.id) },
            note: "Panel content with the Demo archive (DemoDataProvider.dailyUsage), 480 points wide."
                + " The Demo archive is cloud-shaped and includes Gemini; the real panel reads this Mac's"
                + " local-scan archive, which holds only what the scanner records (Claude and Codex),"
                + " so the \"Claude + Codex\" caption is true there. The headline counts up over 2.2 s."
        )
    }

    private struct DrawnPages {
        let pages: [NSBitmapImageRep]
        let hosting: NSView
        let window: NSWindow
        /// The main scroll view's visible area, in points from the top of
        /// `hosting`; nil when nothing scrolls.
        let viewport: (top: Double, height: Double)?
    }

    /// Lays `content` out in an offscreen window at its fitting size and
    /// draws it page by page (unless `scrolls` is false). The caller empties
    /// `window.contentView` when it is done with the view.
    private func drawPages<Content: View>(
        _ content: Content,
        id: String,
        settle firstSettle: Double,
        scrolls: Bool = true,
        prepare: ((NSView) -> Void)? = nil
    ) async -> DrawnPages? {
        // Every root gets `displayLocaleRoot()`, as every scene root of the
        // app does, and is told it is in the key window.
        let hosting = NSHostingView(
            rootView: content
                .displayLocaleRoot()
                .environment(\.controlActiveState, .key)
        )
        let window = offscreenWindow(holding: hosting, size: NSSize(width: 420, height: 600))
        if let prepare {
            // Early, once the first layout pass has made the AppKit views, so
            // whatever the change sets off is over by the time it is drawn.
            await settle(hosting, seconds: 0.3)
            prepare(hosting)
        }
        await settle(hosting, seconds: firstSettle)

        let fitting = hosting.fittingSize
        guard fitting.width >= 1, fitting.height >= 1 else {
            manifest.warnings.append("\(id): the view has no size (\(fitting))")
            window.contentView = nil
            return nil
        }
        window.setContentSize(fitting)
        await settle(hosting, seconds: 0.4)
        manifest.windowBackingScale = Double(window.backingScaleFactor)

        var pages: [NSBitmapImageRep] = []
        var viewport: (top: Double, height: Double)?
        if let first = snapshot(hosting) { pages.append(first) }
        if scrolls, let scrollView = mainScrollView(in: hosting), let document = scrollView.documentView {
            let frame = scrollView.convert(scrollView.bounds, to: hosting)
            viewport = (
                top: Double(hosting.isFlipped ? frame.minY : hosting.bounds.height - frame.maxY),
                height: Double(frame.height)
            )
            var offset = 0.0
            while pages.count < QARenderSnapshot.maxPages,
                  let next = QARenderSnapshot.nextPageOffset(
                      after: offset,
                      contentHeight: Double(document.frame.height),
                      viewportHeight: Double(scrollView.contentView.bounds.height)
                  )
            {
                offset = next
                scrollTo(scrollView, offsetFromTop: offset)
                await settle(hosting, seconds: 0.35)
                if let page = snapshot(hosting) { pages.append(page) }
            }
            if QARenderSnapshot.nextPageOffset(
                after: offset,
                contentHeight: Double(document.frame.height),
                viewportHeight: Double(scrollView.contentView.bounds.height)
            ) != nil {
                manifest.warnings.append(
                    "\(id): stopped after \(QARenderSnapshot.maxPages) pages; the rest is not drawn"
                )
            }
        }
        return DrawnPages(pages: pages, hosting: hosting, window: window, viewport: viewport)
    }

    private func capture<Content: View>(
        _ content: Content,
        surface: QARenderSurface,
        index: Int,
        prepare: ((NSView) -> Void)? = nil,
        note: String?
    ) async {
        guard let drawn = await drawPages(content, id: surface.id, settle: 0.8, prepare: prepare) else {
            return
        }
        drawn.window.contentView = nil
        let pages = drawn.pages

        for (pageIndex, page) in pages.enumerated() {
            let number = pageIndex + 1
            let file = QARenderSnapshot.fileName(index: index, surface: surface, page: number)
            do {
                try write(page, to: request.outputDirectory.appendingPathComponent(file))
            } catch {
                manifest.warnings.append("\(file): \(error)")
                continue
            }
            manifest.renders.append(.init(
                id: surface.id,
                kind: surface.kind,
                file: file,
                page: number,
                pageCount: pages.count,
                width: Double(page.size.width),
                height: Double(page.size.height),
                pixelWidth: page.pixelsWide,
                pixelHeight: page.pixelsHigh,
                suspectBlank: looksBlank(page),
                note: note
            ))
        }
    }

    /// A borderless window holding `view`. It is never ordered in, so it is
    /// never on screen; it exists so the view has a window to lay out and
    /// draw in.
    private func offscreenWindow(holding view: NSView, size: NSSize) -> NSWindow {
        let window = QARenderWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.renderScale = CGFloat(request.scale)
        window.isReleasedWhenClosed = false
        window.appearance = NSApp.appearance
        window.contentView = view
        return window
    }

    /// Lets SwiftUI run `onAppear`, `.task` and the layout passes they cause.
    private func settle(_ view: NSView, seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        view.layoutSubtreeIfNeeded()
    }

    /// The largest scroll view with more content than it shows: the tab or
    /// window body, rather than a list nested inside it.
    private func mainScrollView(in root: NSView) -> NSScrollView? {
        var best: NSScrollView?
        var bestArea: CGFloat = 0
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView,
               let document = scroll.documentView,
               document.frame.height > scroll.contentView.bounds.height + 1
            {
                let area = scroll.frame.width * scroll.frame.height
                if area > bestArea {
                    best = scroll
                    bestArea = area
                }
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        return best
    }

    private func scrollTo(_ scrollView: NSScrollView, offsetFromTop: Double) {
        guard let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let y = document.isFlipped
            ? CGFloat(offsetFromTop)
            : max(0, document.frame.height - clip.bounds.height - CGFloat(offsetFromTop))
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    /// The view at the run's scale (`QARenderSnapshot.RenderSet.scale`) in
    /// pixels per point, whatever the backing scale of the screen the
    /// offscreen window would belong to.
    private func snapshot(_ view: NSView) -> NSBitmapImageRep? {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bounds = view.bounds
        let scale = CGFloat(request.scale)
        guard bounds.width >= 1, bounds.height >= 1,
              let rep = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: Int((bounds.width * scale).rounded()),
                  pixelsHigh: Int((bounds.height * scale).rounded()),
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: 0,
                  bitsPerPixel: 0
              )
        else {
            return nil
        }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        return rep
    }

    private func write(_ rep: NSBitmapImageRep, to url: URL) throws {
        let output = rep.converting(to: .sRGB, renderingIntent: .default) ?? rep
        guard let data = output.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
    }

    private func looksBlank(_ rep: NSBitmapImageRep) -> Bool {
        let steps = 64
        var samples: [UInt32] = []
        samples.reserveCapacity(steps * steps)
        for row in 0..<steps {
            for column in 0..<steps {
                let x = (rep.pixelsWide - 1) * column / (steps - 1)
                let y = (rep.pixelsHigh - 1) * row / (steps - 1)
                guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                func byte(_ value: CGFloat) -> UInt32 {
                    UInt32(max(0, min(255, (value * 255).rounded())))
                }
                samples.append(
                    byte(colour.redComponent) << 24 | byte(colour.greenComponent) << 16
                        | byte(colour.blueComponent) << 8 | byte(colour.alphaComponent)
                )
            }
        }
        return QARenderSnapshot.looksBlank(rgbaSamples: samples)
    }

    // MARK: Language menu

    /// The globe menu in the popover footer. SwiftUI builds its items only
    /// when the menu is about to open; the popup button's delegate does that
    /// in `popUpButtonCell:willShowMenu:`, which fills the real `NSMenu`
    /// without showing it. If that hook is missing (a different SwiftUI), the
    /// items are rebuilt the way `LanguagePickerMenu` builds them, and the
    /// manifest says so.
    private func captureLanguageMenu(index: Int) async {
        enterDemoIfNeeded()
        shapeExistingUser(onboardingV2: false)
        state.selectedTab = .overview
        let hosting = NSHostingView(
            rootView: MenuBarView()
                .environmentObject(state)
                .environmentObject(state.subscriptionManager)
                .environmentObject(state.authState)
                .environmentObject(state.alertState)
                .environmentObject(state.providerState)
                .displayLocaleRoot()
                .environment(\.controlActiveState, .key)
        )
        let window = offscreenWindow(holding: hosting, size: NSSize(width: 380, height: 580))
        await settle(hosting, seconds: 0.8)

        let nativeNames = Set(LocaleOverrideStore.languageOptions.map(\.nativeName))
        var menuItems: [QARenderManifest.MenuItem]?
        var menuFontSize: Double?
        var popups: [NSPopUpButton] = []
        func visit(_ view: NSView) {
            if let popup = view as? NSPopUpButton { popups.append(popup) }
            view.subviews.forEach(visit)
        }
        visit(hosting)
        let fill = NSSelectorFromString("popUpButtonCell:willShowMenu:")
        for popup in popups {
            guard let menu = popup.menu else { continue }
            if let delegate = menu.delegate as? NSObject, delegate.responds(to: fill) {
                _ = delegate.perform(fill, with: popup.cell, with: menu)
            }
            let titles = Set(menu.items.map(\.title))
            guard nativeNames.isSubset(of: titles) else { continue }
            let font: NSFont? = menu.font
            menuFontSize = font.map { Double($0.pointSize) }
            menuItems = menu.items.map {
                QARenderManifest.MenuItem(
                    title: $0.title,
                    checked: $0.state == .on,
                    separator: $0.isSeparatorItem,
                    enabled: $0.isEnabled
                )
            }
            break
        }
        window.contentView = nil

        let menu: QARenderManifest.LanguageMenu
        if let menuItems {
            menu = .init(
                source: "nsmenu",
                note: "Read from the NSMenu the popover footer's globe button builds, filled "
                    + "without opening it. Titles in menu order; checked is the menu's own "
                    + "checkmark. The picture is drawn from these items, not a screenshot "
                    + "of the open menu; fontPointSize is the size the real menu draws them in.",
                items: menuItems,
                fontPointSize: menuFontSize
            )
            // The picture cannot show the size the real menu opens in, so check
            // it here: `.controlSize(.mini)` on the globe once made it 9 pt.
            if let menuFontSize, menuFontSize < Double(NSFont.systemFontSize) {
                manifest.warnings.append(
                    "language menu: its items are drawn at \(menuFontSize) pt, below the "
                        + "system's \(Double(NSFont.systemFontSize)) pt")
            } else if menuFontSize == nil {
                manifest.warnings.append("language menu: the real NSMenu has no font to check")
            }
        } else {
            let override = LocaleOverrideStore.shared.override
            var items: [QARenderManifest.MenuItem] = [
                .init(title: L10n.language.systemDefault, checked: override == nil,
                      separator: false, enabled: true),
                .init(title: "", checked: false, separator: true, enabled: false),
            ]
            items += LocaleOverrideStore.languageOptions.map {
                .init(title: $0.nativeName, checked: $0.id == override,
                      separator: false, enabled: true)
            }
            items += [
                .init(title: "", checked: false, separator: true, enabled: false),
                .init(title: L10n.language.systemTextAfterRestart, checked: false,
                      separator: false, enabled: false),
            ]
            menu = .init(
                source: "languageOptions-fallback",
                note: "FALLBACK: the globe button's NSMenu could not be filled offscreen "
                    + "(found \(popups.count) popup button(s)). These items are rebuilt "
                    + "the way LanguagePickerMenu builds them, from "
                    + "LocaleOverrideStore.languageOptions and the catalogue, and are not "
                    + "read from the real menu.",
                items: items
            )
            manifest.warnings.append("language menu: fallback used; the real NSMenu was not reachable")
        }
        manifest.languageMenu = menu

        let surfaceID = menu.source == "nsmenu" ? "language-menu" : "language-menu-fallback"
        let file = String(format: "%02d", index + 1) + "-\(surfaceID).png"
        let pictureHost = NSHostingView(
            rootView: QARenderMenuPicture(items: menu.items)
                .displayLocaleRoot()
                .background(Color(nsColor: .windowBackgroundColor))
        )
        let pictureWindow = offscreenWindow(holding: pictureHost, size: NSSize(width: 260, height: 300))
        await settle(pictureHost, seconds: 0.3)
        pictureWindow.setContentSize(pictureHost.fittingSize)
        await settle(pictureHost, seconds: 0.2)
        if let rep = snapshot(pictureHost) {
            do {
                try write(rep, to: request.outputDirectory.appendingPathComponent(file))
                manifest.languageMenu?.image = file
                manifest.renders.append(.init(
                    id: surfaceID,
                    kind: .menu,
                    file: file,
                    page: 1,
                    pageCount: 1,
                    width: Double(rep.size.width),
                    height: Double(rep.size.height),
                    pixelWidth: rep.pixelsWide,
                    pixelHeight: rep.pixelsHigh,
                    suspectBlank: looksBlank(rep),
                    note: menu.note
                ))
            } catch {
                manifest.warnings.append("\(file): \(error)")
            }
        }
        pictureWindow.contentView = nil
    }
}

/// The offscreen window, at the run's scale whatever screen the Mac has.
///
/// Views rasterize their layers at their window's backing scale, and a window
/// that is never ordered in takes that of the main screen: 1 on a Mac whose
/// main display is not Retina (or while its display sleeps), where a 3x
/// snapshot came out as 1x text blown up threefold. Drawing into a bitmap of
/// the run's scale is not enough; the window has to report it too.
final class QARenderWindow: NSWindow {
    var renderScale: CGFloat = 2

    override var backingScaleFactor: CGFloat { renderScale }
}

/// A picture of menu items: checkmark column, title, separators. Leading,
/// trailing and repeated separators are dropped, as AppKit does when it shows
/// a menu.
private struct QARenderMenuPicture: View {
    let items: [QARenderManifest.MenuItem]

    private var visibleItems: [QARenderManifest.MenuItem] {
        var result: [QARenderManifest.MenuItem] = []
        for item in items {
            if item.separator {
                guard let last = result.last, !last.separator else { continue }
            }
            result.append(item)
        }
        while result.last?.separator == true { result.removeLast() }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(visibleItems.enumerated()), id: \.offset) { _, item in
                if item.separator {
                    Divider().padding(.vertical, 4)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .opacity(item.checked ? 1 : 0)
                            .accessibilityHidden(true)
                        Text(verbatim: item.title)
                            .font(.system(size: 13))
                            .foregroundStyle(item.enabled ? .primary : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: 260, alignment: .leading)
    }
}

/// Refuses every request made through the shared URL session while the
/// renderer runs, and remembers where it would have gone (scheme, host and
/// path; never the query). The QA runtime already blocks production
/// endpoints and collectors; this lists what reached `URLSession.shared`
/// anyway. It does not see sessions built from their own configuration, such
/// as APIClient's, so an empty list is not proof that nothing went out; the
/// process's sockets are (docs/qa/macos-offscreen-renders.md).
final class QARenderRefusingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var refusedURLs: [String] = []

    static var refused: [String] {
        lock.lock()
        defer { lock.unlock() }
        return refusedURLs
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let url = request.url {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.query = nil
            components?.fragment = nil
            components?.user = nil
            components?.password = nil
            Self.lock.lock()
            Self.refusedURLs.append(components?.string ?? url.absoluteString)
            Self.lock.unlock()
        }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}
#endif
