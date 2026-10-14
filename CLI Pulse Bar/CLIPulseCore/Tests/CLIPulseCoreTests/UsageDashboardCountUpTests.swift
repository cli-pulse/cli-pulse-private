#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import CLIPulseCore

/// The usage panel's headline (`CountUpNumber`) counts up for 2.2 s when the
/// panel appears. The QA renderer draws a page about 1.2 s after it appears
/// (`QASnapshotRenderer.drawPages`: 0.8 s, the window fitted to the view,
/// 0.4 s), so the review set caught the headline part of the way up (12.0M
/// beside a 12.5M tile). The renderer now draws every view with
/// `EnvironmentValues.countsUp` off; the app keeps its count-up.
///
/// The panel is drawn here the way the renderer draws it: dark, in a
/// borderless offscreen window fitted to it, at the renderer's moment, and
/// its header compared as pixels with the same panel once the count-up has
/// ended.
@MainActor
final class UsageDashboardCountUpTests: XCTestCase {

    private static var archive: DailyUsageArchive {
        QARenderSnapshot.storeLocalScanArchive(
            today: Date(timeIntervalSince1970: 1_791_342_000),
            calendar: DayKey.calendar(in: TimeZone(identifier: "Asia/Tokyo")!))
    }

    func test_aRenderDrawsTheSettledHeadline_andTheAppStillCountsUp() throws {
        let archive = Self.archive
        XCTAssertGreaterThan(DailyUsageStats.totalTokens(archive), 1_000_000, "a headline too small to count up visibly")

        // The app: part of the way up at the renderer's moment, then settled.
        let app = PanelWindow(archive, countsUp: true)
        defer { app.close() }
        let early = app.drawAsTheRendererDoes()
        app.pump(for: 2.5)   // the count-up is 2.2 s from appearing; this is past 3.5 s
        let settled = try XCTUnwrap(app.pixels(in: RendererTiming.header), "the panel drew no header")
        app.pump(for: 0.4)
        XCTAssertEqual(app.pixels(in: RendererTiming.header), settled,
                       "the app's headline still moves after 3.5 s, so this is not its settled figure")
        XCTAssertNotEqual(early, settled,
                          "the app's headline has already settled when a render is taken, so this test cannot see a count-up")

        // The renderer's environment: the settled figure when it draws.
        let render = PanelWindow(archive, countsUp: false)
        defer { render.close() }
        XCTAssertEqual(render.drawAsTheRendererDoes(), settled,
                       "the render caught the usage panel's headline part of the way up")
    }

    /// The test above is only about the renderer if the renderer is what sets
    /// the flag, and only about the app if nothing else does: the app's
    /// windows and panels never set it, so they keep the default (count up).
    func test_onlyTheRendererTurnsTheCountUpOff() throws {
        XCTAssertTrue(EnvironmentValues().countsUp, "the app's default must be to count up")

        let appsRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // …/Tests/CLIPulseCoreTests
            .deletingLastPathComponent()    // …/Tests
            .deletingLastPathComponent()    // …/CLIPulseCore
            .deletingLastPathComponent()    // …/CLI Pulse Bar
        let directories = [
            "CLI Pulse Bar", "CLI Pulse Bar iOS", "CLI Pulse Bar Watch", "CLI Pulse Widgets",
            "CLIPulseCore/Sources",
        ].map { appsRoot.appending(path: $0) }
        // `.environment(\.countsUp, …)`, or `….countsUp = …` in a closure
        // that edits the environment. Reading it (`@Environment(\.countsUp)`)
        // is not setting it.
        let setter = try NSRegularExpression(
            pattern: #"\.environment\(\s*\\\.countsUp\b|\.countsUp\s*=[^=]"#)

        var setters: [String] = []
        for directory in directories where FileManager.default.fileExists(atPath: directory.path) {
            let files = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
            for case let file as URL in files where file.pathExtension == "swift" {
                let source = try String(contentsOf: file, encoding: .utf8)
                let range = NSRange(source.startIndex..., in: source)
                for match in setter.matches(in: source, range: range) {
                    let line = source[..<Range(match.range, in: source)!.lowerBound].filter { $0 == "\n" }.count + 1
                    setters.append("\(file.lastPathComponent):\(line)")
                }
            }
        }
        XCTAssertEqual(setters.count, 1, "`countsUp` is set outside the renderer, or not at all: \(setters)")
        XCTAssertTrue(setters.first?.hasPrefix("QASnapshotRenderer.swift:") ?? false, "\(setters)")

        let renderer = try String(
            contentsOf: appsRoot.appending(path: "CLI Pulse Bar/QASnapshotRenderer.swift"), encoding: .utf8)
        let drawPages = try XCTUnwrap(renderer.range(of: "private func drawPages<"), "drawPages moved")
        let hostingRoot = try XCTUnwrap(
            renderer.range(of: "let hosting = NSHostingView(", range: drawPages.upperBound..<renderer.endIndex))
        let rootEnd = try XCTUnwrap(renderer.range(of: "\n        )\n", range: hostingRoot.upperBound..<renderer.endIndex))
        XCTAssertTrue(renderer[hostingRoot.upperBound..<rootEnd.lowerBound].contains(".environment(\\.countsUp, false)"),
                      "drawPages, which draws every page of both sets, no longer turns the count-up off on its root")
    }
}

// MARK: - The panel as the renderer draws it

/// `QASnapshotRenderer.captureUsageDashboardPanel`'s view: the non-scrolling
/// dashboard, 480 points wide, dark over an opaque fill, under the renderer's
/// root modifiers, in a borderless window that is never shown.
@MainActor
private final class PanelWindow {
    private let window: NSWindow
    private let hosting: NSView

    init(_ archive: DailyUsageArchive, countsUp: Bool) {
        let view = UsageDashboardView(archive: archive, scrollable: false)
            .frame(width: 480)
            .environment(\.colorScheme, .dark)
            .background(Color(red: 0.11, green: 0.11, blue: 0.12))
            .displayLocaleRoot()
            .environment(\.controlActiveState, .key)
            .environment(\.countsUp, countsUp)
        let hosting = NSHostingView(rootView: view)
        window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 420, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        self.hosting = hosting
    }

    func close() { window.close() }

    /// The header as the renderer would draw it: after the renderer's first
    /// settle, the window fitted to the view, and its second settle.
    func drawAsTheRendererDoes() -> Data? {
        pump(for: RendererTiming.firstSettle)
        let fitting = hosting.fittingSize
        if fitting.width >= 1, fitting.height >= 1 { window.setContentSize(fitting) }
        pump(for: RendererTiming.afterFit)
        return pixels(in: RendererTiming.header)
    }

    /// Spins the run loop, where SwiftUI applies updates and advances
    /// animations, for `seconds`.
    func pump(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        hosting.layoutSubtreeIfNeeded()
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            hosting.layoutSubtreeIfNeeded()
        }
    }

    /// What the window draws in `rect`, measured from the top left, or `nil`
    /// when it drew nothing there.
    func pixels(in rect: CGRect) -> Data? {
        hosting.layoutSubtreeIfNeeded()
        let local = hosting.isFlipped
            ? rect
            : CGRect(x: rect.minX, y: hosting.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: local) else { return nil }
        hosting.cacheDisplay(in: local, to: rep)
        guard let bytes = rep.bitmapData else { return nil }
        let data = Data(bytes: bytes, count: rep.bytesPerRow * rep.pixelsHigh)
        return Set(data).count > 1 ? data : nil
    }
}

private enum RendererTiming {
    /// `drawPages`: settle 0.8 s, fit the window to the view, settle 0.4 s.
    static let firstSettle = 0.8
    static let afterFit = 0.4
    /// The panel's title, headline and scope line, inside its padding.
    static let header = CGRect(x: 0, y: 0, width: 330, height: 96)
}
#endif
