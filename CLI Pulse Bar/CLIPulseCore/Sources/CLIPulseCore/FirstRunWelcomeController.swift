// FirstRunWelcomeController — v1.49 first-run visibility.
//
// Presents `FirstRunWelcomeView` in a real, centered, activating window on the
// first launch of a brand-new install. See `FirstRunPresentation` for why the
// silence this replaces was the most expensive step in the funnel.
//
// WHY AppKit AND NOT A SwiftUI `Window` SCENE
// ------------------------------------------
// Two independent blockers, either one fatal:
//
//   * `openWindow(id:)` has to be called from something that renders, and the
//     only thing this app renders is `MenuBarExtra`, whose content is built
//     LAZILY — the first time the user opens the popover. Hanging first-run
//     presentation off it would mean the window that exists to get the user to
//     the menu only appears once they have already found the menu.
//   * `Scene.defaultLaunchBehavior(.presented)` would solve it, and is macOS 15+.
//     This app targets macOS 13.
//
// So the window is built directly, matching `DashboardPanelController` and
// `PetPanelController`, which are AppKit controllers in this package for
// similar reasons.
//
// Unlike those two this is a normal activating `NSWindow`, not a non-activating
// `NSPanel`: stealing focus is the entire point. An `LSUIElement` app is not
// frontmost at launch, so a polite window would open behind the user's editor
// and reproduce the invisibility it is meant to cure.

#if os(macOS)
import AppKit
import SwiftUI

@MainActor
public final class FirstRunWelcomeController {
    public static let shared = FirstRunWelcomeController()

    private var window: NSWindow?

    public init() {}

    public var isVisible: Bool { window != nil }

    /// Presents the window, unless it is already up.
    ///
    /// The decision of *whether* this launch deserves it belongs to
    /// `FirstRunPresentation` and is taken in `CLIPulseBarApp.init`, before the
    /// app writes any defaults of its own. This method only presents.
    public func present(onDismiss: @escaping () -> Void = {}) {
        guard window == nil else { return }

        let hosting = NSHostingView(
            rootView: FirstRunWelcomeView { [weak self] in
                onDismiss()
                self?.dismiss()
            }
        )

        // Sizing, carefully. `fittingSize` on a hosting view that has never been
        // in a window can come back zero or partially resolved, and a zero-size
        // window is indistinguishable from no window at all — the precise
        // failure this feature exists to prevent, reintroduced one level down.
        // So: start from a known-good rect, attach, force layout, and only then
        // adopt the measured size, and only if it is sane.
        let fallback = NSSize(width: 420, height: 300)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: fallback),
            // Closable and titled so the standard red button works. A brand-new
            // user who does not trust the button must still have the ordinary
            // way out; a window they cannot dismiss is worse than no window.
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let measured = hosting.fittingSize
        if measured.width >= 200, measured.height >= 120 {
            window.setContentSize(measured)
        }
        window.title = L10n.firstRun.title
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        // Not `.floating`: this must not sit above every other app forever. It
        // is a one-time greeting, not a HUD.
        window.level = .normal
        window.center()
        // The app is LSUIElement, so it has no Dock icon and no menu of its own
        // to return to. Releasing on close keeps no zombie window around.
        window.isReleasedWhenClosed = false
        window.delegate = closeObserver

        self.window = window
        closeObserver.onClose = { [weak self] in
            // Covers the red close button, Cmd-W and the window being closed by
            // the system. The "Got it" button routes through `dismiss()` which
            // closes the window and lands here too, so marking is idempotent.
            onDismiss()
            self?.window = nil
        }

        window.makeKeyAndOrderFront(nil)
        // Both calls are needed. `makeKeyAndOrderFront` alone leaves an
        // LSUIElement app's window behind the frontmost application.
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    public func dismiss() {
        window?.close()
        window = nil
    }

    private let closeObserver = CloseObserver()

    /// `NSWindowDelegate` has to be an `NSObject`, which this controller is not.
    private final class CloseObserver: NSObject, NSWindowDelegate {
        var onClose: (() -> Void)?
        func windowWillClose(_ notification: Notification) {
            onClose?()
            onClose = nil
        }
    }
}
#endif
