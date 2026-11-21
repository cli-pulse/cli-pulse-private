// PopoverBackdrop — what the menu-bar window draws behind its content, set by
// Settings › Display › Window background.
//
// From macOS 26 the system draws a MenuBarExtra window as Liquid Glass, clear
// enough that a bright wallpaper or window behind it washes out the secondary
// and tertiary text (owner, 2026-11-21). One value from 0 to 1 decides what is
// laid over that glass:
//
//   0          nothing: the system glass alone, as before this setting existed
//   0 → 0.5    a behind-window frosted material fades in; 0.5 is fully frosted
//              and is the default
//   0.5 → 1    the window background colour fades in over it; 1 is solid
//
// Every layer sits inside the window, so the window's own rounded shape clips it.
// NSVisualEffectView only: no macOS 26 API, so the macos-15 CI runners build it.

#if os(macOS)
import SwiftUI
import AppKit

public enum PopoverBackground {
    /// UserDefaults key of the 0…1 level. Settings writes it; the window reads it.
    public static let defaultsKey = "cli_pulse_popover_background"
    /// Fully frosted, nothing solid.
    public static let defaultLevel = 0.5

    /// How opaque each layer is at `level`. A level outside 0…1 is clamped; one
    /// that is not a number (a hand-edited defaults file) reads as the default.
    public static func layers(at level: Double) -> (frost: Double, solid: Double) {
        let value = level.isFinite ? min(max(level, 0), 1) : defaultLevel
        return (frost: min(1, value / 0.5), solid: max(0, (value - 0.5) / 0.5))
    }
}

/// Put behind the menu-bar window's root view. Reads the level itself, so a
/// change in Settings shows at once in the open window.
public struct PopoverBackdrop: View {
    @AppStorage(PopoverBackground.defaultsKey) private var level = PopoverBackground.defaultLevel

    public init() {}

    public var body: some View {
        let layers = PopoverBackground.layers(at: level)
        ZStack {
            if layers.frost > 0 {
                FrostedMaterial().opacity(layers.frost)
            }
            if layers.solid > 0 {
                Color(nsColor: .windowBackgroundColor).opacity(layers.solid)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The frosted glass macOS drew behind popovers before Liquid Glass. `.active`
/// keeps it frosted while the window is not key.
private struct FrostedMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
#endif
