// DashboardPanelController — v1.40 UX refine. Presents the Usage Dashboard as a
// borderless panel that slides out to the LEFT of the menu-bar popover
// ("extending" from it) instead of opening a separate centered window.
//
// The panel is a non-activating floating NSPanel, so ordering it in front does
// NOT steal key from the MenuBarExtra popover (which would dismiss it). It's
// anchored to the popover's screen frame (right edge ~ popover left edge,
// top-aligned) and clamped to the space available to the left, then re-tapping
// the card, the popover closing, or the app resigning active dismisses it.
//
// v1.57 (P1-2): two modes (`UsagePanelModel.Mode`). The Overview's Activity
// card opens the Usage Dashboard for every provider; a provider card's small
// chart (or, while the card draws none, a button in its header) opens that
// provider's last 30 days. The content is
// live (D11): the archive is read again whenever it is written, and the
// provider mode follows the refresh's scan. The panel follows its content's
// height as that changes.

#if os(macOS)
import AppKit
import SwiftUI

@MainActor
public final class DashboardPanelController {
    public static let shared = DashboardPanelController()

    private var panel: NSPanel?
    private var observers: [NSObjectProtocol] = []
    /// True from the moment show() starts until the panel exists — guards the
    /// `await` snapshot window against a second toggle spawning a duplicate.
    private var isPreparing = false
    /// Set when the user toggles again DURING the async prepare window (before the
    /// panel exists, so isVisible is still false). Without it, that dismissing tap
    /// would spawn a second (no-op) show() and the panel would still appear when
    /// the snapshot() await resolves — an open-against-intent orphan.
    private var wantsHide = false
    /// What the panel shows, kept live while it is open.
    let model = UsagePanelModel()
    /// The app state the provider mode reads its scan and synced rows from.
    private weak var state: AppState?
    /// The tallest the panel may be on its screen.
    private var maxHeight: CGFloat = 0
    /// Where the panel is sliding to while it slides out: a resize in that
    /// time keeps this x, not the x the slide has reached.
    private var slidingToX: CGFloat?

    public init() {}

    public var isVisible: Bool { panel != nil }

    /// Gives the provider mode its data. The popover calls this when it
    /// appears; the provider cards pass the state again when they open it.
    public func attach(_ state: AppState) {
        guard self.state !== state else { return }
        self.state = state
        model.follow(state)
    }

    /// The Usage Dashboard (every provider): show the panel if hidden, hide it
    /// if shown in that mode, switch to it if shown in another.
    public func toggle() {
        toggle(.allProviders)
    }

    /// One provider's usage history, toggled the same way. `scope`: the
    /// scope the provider card's figures are labelled with, which the panel
    /// opens on (`UsagePanelModel.prefer(_:for:)`). `basis`: how the panel
    /// counts tokens; a provider card passes its own
    /// (`ProviderCardUsage.tokenBasis`), so the panel's days and total are
    /// the card's figures. Clicking again while that provider is shown hides
    /// the panel and leaves both alone.
    public func toggle(
        provider: String, state: AppState, scope: UsageDataScope? = nil,
        basis: ProviderUsageDays.TokenBasis = .eachOnce
    ) {
        attach(state)
        let mode = UsagePanelModel.Mode.provider(provider)
        if !(isVisible && model.mode == mode) {
            model.open(provider, scope: scope, basis: basis)
        }
        toggle(mode)
    }

    private func toggle(_ mode: UsagePanelModel.Mode) {
        if isVisible {
            if model.mode == mode {
                hide()
            } else {
                model.mode = mode
            }
        } else if isPreparing {
            wantsHide = true   // dismiss requested mid-prepare; honored after the await
        } else {
            wantsHide = false
            model.mode = mode
            Task { await show() }
        }
    }

    private func show() async {
        guard panel == nil, !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }
        // Read the archive up front so the size probe (and the panel itself)
        // render the LOADED dashboard, not the async loading spinner —
        // otherwise the panel would open at the ~400pt ProgressView's height.
        // A reload started during the read is newer than it (the archive
        // was written meanwhile), and the seed leaves it to win.
        let readStartedAt = model.reloadGeneration
        model.seed(archive: await DailyUsageArchiveManager.shared.snapshot(), readStartedAt: readStartedAt)
        // Honor a hide()/re-toggle that raced during the await.
        guard panel == nil, !wantsHide else { wantsHide = false; return }
        present()
    }

    /// Synchronous panel construction — kept out of the `async show()` so
    /// `NSAnimationContext.runAnimationGroup`'s trailing closure resolves to the
    /// non-async overload.
    private func present() {
        // The popover is key when the user taps the card inside it.
        let anchor = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey })
        let screen = anchor?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        // A compact companion panel — kept narrow, to the left of the popover.
        let leftEdge = anchor?.frame.minX ?? (visible.maxX - 420)
        let available = leftEdge - visible.minX - 16
        let width = min(520, max(440, available))

        // Size the panel to the content's NATURAL height, so it has no
        // vertical scrollbar while it fits the screen. Probe a copy at this
        // width; the panel scrolls only when the content is taller than the
        // screen: a provider's mode with its Projects and (v1.58) Sessions
        // cards is about 1,200 points, so on every laptop screen it scrolls,
        // as one page (the Sessions card has no scroll view of its own).
        // Later changes of height are followed through `fit(height:)`.
        let maxHeight = visible.height - 24
        let probe = NSHostingView(rootView:
            UsagePanelContent(model: model)
                .frame(width: width)
                .environment(\.colorScheme, .dark)
                .displayLocaleRoot())
        probe.layoutSubtreeIfNeeded()
        let naturalHeight = probe.fittingSize.height
        let height = naturalHeight > 1 ? min(naturalHeight, maxHeight) : maxHeight

        let hosting = NSHostingView(rootView:
            UsagePanelRootView(
                model: model, width: width, maxHeight: maxHeight,
                onHeightChange: { [weak self] height in
                    // After the update that measured it: the panel's frame is
                    // AppKit's, not SwiftUI state.
                    DispatchQueue.main.async { self?.fit(height: height) }
                },
                onClose: { [weak self] in self?.hide() },
                // The provider mode's folder-access state: the popover's
                // Settings is where the log folders are granted.
                onOpenSettings: { [weak self] in self?.state?.selectedTab = .settings })
                .displayLocaleRoot())
        // The panel's size is set here, from the measured content; the
        // hosting view must not size the window itself.
        hosting.sizingOptions = []
        hosting.wantsLayer = true
        // Round the window's own layer instead of clip-shaping the content (which
        // was centering + clipping the dashboard when its minWidth exceeded the panel).
        hosting.layer?.cornerRadius = 16
        hosting.layer?.masksToBounds = true

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = anchor?.level ?? .floating
        p.contentView = hosting
        p.isMovableByWindowBackground = true

        // Top-align with the popover, but clamp so a tall (full-height) panel
        // never spills below the screen's visible area.
        let top = min(anchor?.frame.maxY ?? visible.maxY, visible.maxY)
        let targetY = max(visible.minY, top - height)
        let targetX = leftEdge - width - 8
        self.maxHeight = maxHeight
        // Start tucked behind the popover, then slide out to the left.
        p.setFrame(NSRect(x: leftEdge - width + 24, y: targetY, width: width, height: height), display: false)
        p.alphaValue = 0
        p.orderFront(nil)
        slidingToX = targetX
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().setFrame(NSRect(x: targetX, y: targetY, width: width, height: height), display: true)
            p.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            // Only this slide's target: the panel may have been hidden and
            // shown again, with a slide of its own, before this one ended.
            MainActor.assumeIsolated {
                guard let self, self.panel === p else { return }
                self.slidingToX = nil
            }
        })
        panel = p

        // Dismiss when the app resigns active (user clicks another app). NOTE: we
        // deliberately do NOT tie the panel to the popover's willClose — a
        // MenuBarExtra popover dismisses on any click outside its bounds, so
        // interacting with this panel would otherwise close it instantly. The
        // panel is dismissed by re-tapping the card, its close button, or this.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            })
    }

    /// Resizes the open panel to `height`, keeping its top edge where it is
    /// (the panel hangs from the popover's top, or wherever it was dragged),
    /// and its bottom on screen.
    private func fit(height: CGFloat) {
        guard let p = panel, height > 1 else { return }
        var current = p.frame
        if let slidingToX { current.origin.x = slidingToX }
        let target = Self.frame(fitting: min(height, maxHeight), in: current, top: current.maxY,
                                screenBottom: p.screen?.visibleFrame.minY ?? 0)
        guard abs(target.height - p.frame.height) >= 0.5 || abs(target.minY - p.frame.minY) >= 0.5 else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            p.animator().setFrame(target, display: true)
        }
    }

    /// The panel's frame at `height`: the same x and width, the top at `top`
    /// unless that would put the bottom below `screenBottom`, in which case it
    /// moves up just enough.
    static func frame(fitting height: CGFloat, in frame: NSRect, top: CGFloat, screenBottom: CGFloat) -> NSRect {
        let y = max(screenBottom, top - height)
        return NSRect(x: frame.minX, y: y, width: frame.width, height: height)
    }

    public func hide() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        guard let p = panel else { return }
        panel = nil
        slidingToX = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            p.animator().alphaValue = 0
        }, completionHandler: {
            p.orderOut(nil)
        })
    }
}
#endif
