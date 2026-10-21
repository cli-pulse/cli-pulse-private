import XCTest
import SwiftUI
@testable import CLIPulseCore

#if os(macOS)

/// v1.58: the usage panel turns its own scrolling off without turning off
/// the scroll views inside it, and still measures its content's natural
/// height.
///
/// The panel scrolls only when it is taller than the screen allows. It used
/// to turn scrolling off with `.scrollDisabled(fits)`, which travels down the
/// environment and, as documented from macOS 13, turns off every scroll view
/// inside too: on a screen tall enough for the panel, a day's model list that
/// shows some of its rows would keep the rest out of reach. Nothing below can
/// undo it (measured on macOS 27: neither `.scrollDisabled(false)` nor
/// setting `isScrollEnabled` to true below turns it back on for the views
/// there). So the panel's scroll view loses its axes instead
/// (`UsagePanelScroller`), as `MenuBarView` does for the setup wizard.
///
/// macOS 27 spares nested scroll views by itself (a `ScrollView` tells its
/// content scrolling is on, whatever it was told), so no rendering test on
/// this Mac or a newer runner can show the old failure; the source check
/// keeps the modifier out, and the measuring test checks what losing the
/// axes could have broken.
@MainActor
final class UsagePanelScrollTests: XCTestCase {

    /// `…/CLIPulseCore/Sources/CLIPulseCore`.
    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()    // …/Tests/CLIPulseCoreTests
        .deletingLastPathComponent()    // …/Tests
        .deletingLastPathComponent()    // …/CLIPulseCore
        .appending(path: "Sources/CLIPulseCore")

    /// No view of the shared core turns scrolling off with `.scrollDisabled`:
    /// in the panel it would turn its lists off too, and the core's views are
    /// hosted in the panel, the popover and the windows alike.
    func testNoViewTurnsScrollingOffWithScrollDisabled() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 50, "the sources were not found at \(Self.sources.path)")
        var found: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (number, line) in lines.enumerated() {
                let code = line.components(separatedBy: "//").first ?? line
                if code.contains(".scrollDisabled(") { found.append("\(file.lastPathComponent):\(number + 1)") }
            }
        }
        XCTAssertEqual(found, [], "use a scroll view without axes instead (UsagePanelScroller)")

        let panel = try String(contentsOf: Self.sources.appending(path: "UsagePanel.swift"), encoding: .utf8)
        XCTAssertTrue(panel.contains("UsagePanelScroller(fits: fits)"), "the panel's root no longer uses UsagePanelScroller")
        XCTAssertTrue(panel.contains("ScrollView(fits ? [] : .vertical)"))
    }

    /// The root measures the content's natural height whether the panel
    /// scrolls or not: without a vertical axis the scroll view proposes its
    /// own height, and content that could shrink to it would be measured at
    /// the panel's old height, so a panel whose content grew would not grow.
    func testThePanelsContentIsMeasuredAtItsNaturalHeight() {
        for fits in [true, false] {
            let measured = Measured()
            let content = UsagePanelScroller(fits: fits) {
                // Content that can be squeezed: 100 points at least, 500 if
                // it may.
                Color.clear
                    .frame(width: 100)
                    .frame(minHeight: 100, idealHeight: 500)
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: MeasuredHeight.self, value: geo.size.height)
                    })
            }
            .onPreferenceChange(MeasuredHeight.self) { measured.height = $0 }
            layOut(content, height: 200)
            XCTAssertEqual(measured.height, 500, accuracy: 0.5, "fits: \(fits)")
        }
    }

    // MARK: - Hosting

    private final class Measured {
        var height: CGFloat = 0
    }

    private struct MeasuredHeight: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    /// Lays `content` out in an off-screen window `height` points tall, so
    /// SwiftUI evaluates and measures it.
    private func layOut<Content: View>(_ content: Content, height: CGFloat) {
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 200, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content.frame(width: 200, height: height))
        window.orderFrontRegardless()
        defer { window.close() }
        let deadline = Date().addingTimeInterval(0.5)
        window.contentView?.layoutSubtreeIfNeeded()
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }
}

#endif
