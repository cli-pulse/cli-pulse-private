#if canImport(AppKit)
import AppKit
import SwiftUI
import XCTest
@testable import CLIPulseCore

/// The heatmap ramp was written for the dark dashboard panel. On the light
/// Overview card its level 0 (white at 5%) disappeared into the card, so the
/// grid looked full of holes, and level 4 (opaque pale cyan) came out lighter
/// than level 3, so the busiest days looked like quiet ones. Each scheme's ramp
/// must now step one way over its own card: darker in light mode, lighter in
/// dark, with level 0 still visible against the card.
final class UsageHeatmapPaletteTests: XCTestCase {

    /// Relative luminance (0…1) of `color` drawn over an opaque `background`.
    private func luminance(_ color: Color, over background: (r: Double, g: Double, b: Double)) throws -> Double {
        let ns = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
        let a = Double(ns.alphaComponent)
        func mix(_ c: CGFloat, _ bg: Double) -> Double { Double(c) * a + bg * (1 - a) }
        return 0.2126 * mix(ns.redComponent, background.r)
            + 0.7152 * mix(ns.greenComponent, background.g)
            + 0.0722 * mix(ns.blueComponent, background.b)
    }

    func test_light_ramp_darkens_level_by_level_and_level0_shows_on_the_card() throws {
        let card = (r: 0.98, g: 0.98, b: 0.98)
        let levels = try (0...4).map { try luminance(UsageHeatmapPalette.color($0, scheme: .light), over: card) }
        for level in 1...4 {
            XCTAssertLessThan(levels[level], levels[level - 1] - 0.03,
                              "light level \(level) is not clearly darker than level \(level - 1): \(levels)")
        }
        XCTAssertLessThan(levels[0], 0.98 - 0.04, "light level 0 vanishes into the card: \(levels[0])")
    }

    func test_dark_ramp_is_unchanged_and_brightens_level_by_level() throws {
        let panel = (r: 0.11, g: 0.11, b: 0.11)
        let levels = try (0...4).map { try luminance(UsageHeatmapPalette.color($0, scheme: .dark), over: panel) }
        for level in 1...4 {
            XCTAssertGreaterThan(levels[level], levels[level - 1],
                                 "dark level \(level) is not brighter than level \(level - 1): \(levels)")
        }
        XCTAssertGreaterThan(levels[0], 0.11, "dark level 0 vanishes into the panel")
        // The default stays the dark ramp, which the always-dark panel relies on.
        for level in 0...4 {
            XCTAssertEqual(try luminance(UsageHeatmapPalette.color(level), over: panel), levels[level], accuracy: 1e-9)
        }
        // And the dark ramp is the token-monitor ramp it was before the light one
        // was added, value for value: brightening level by level alone would let
        // a changed ramp through.
        let tokenMonitor: [(r: Double, g: Double, b: Double, a: Double)] = [
            (255, 255, 255, 0.05), (90, 170, 255, 0.18), (120, 190, 255, 0.45),
            (150, 210, 255, 0.8), (180, 230, 255, 1.0),
        ]
        for (level, expected) in tokenMonitor.enumerated() {
            let ns = try XCTUnwrap(NSColor(UsageHeatmapPalette.color(level, scheme: .dark)).usingColorSpace(.sRGB))
            XCTAssertEqual(Double(ns.redComponent) * 255, expected.r, accuracy: 0.5, "dark level \(level) red")
            XCTAssertEqual(Double(ns.greenComponent) * 255, expected.g, accuracy: 0.5, "dark level \(level) green")
            XCTAssertEqual(Double(ns.blueComponent) * 255, expected.b, accuracy: 0.5, "dark level \(level) blue")
            XCTAssertEqual(Double(ns.alphaComponent), expected.a, accuracy: 0.002, "dark level \(level) alpha")
        }
    }
}
#endif
