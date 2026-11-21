#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// Settings › Display › Window background: one 0…1 level decides how much of the
/// frosted material and of the solid window colour sit over the system glass.
final class PopoverBackgroundTests: XCTestCase {

    private func assertLayers(_ level: Double, frost: Double, solid: Double,
                              file: StaticString = #filePath, line: UInt = #line) {
        let layers = PopoverBackground.layers(at: level)
        XCTAssertEqual(layers.frost, frost, accuracy: 1e-9, "frost at \(level)", file: file, line: line)
        XCTAssertEqual(layers.solid, solid, accuracy: 1e-9, "solid at \(level)", file: file, line: line)
    }

    /// The left end adds nothing, so the window looks as it did before the setting.
    func testClearEndLeavesTheSystemGlassAlone() {
        assertLayers(0, frost: 0, solid: 0)
    }

    /// The owner asked for frosted glass by default (2026-11-21).
    func testDefaultIsFullyFrostedAndNotSolid() {
        XCTAssertEqual(PopoverBackground.defaultLevel, 0.5)
        assertLayers(PopoverBackground.defaultLevel, frost: 1, solid: 0)
    }

    func testFrostFadesInFirstThenTheSolidColour() {
        assertLayers(0.25, frost: 0.5, solid: 0)
        assertLayers(0.75, frost: 1, solid: 0.5)
        assertLayers(1, frost: 1, solid: 1)
    }

    func testOutOfRangeIsClampedAndANonNumberReadsAsTheDefault() {
        assertLayers(-1, frost: 0, solid: 0)
        assertLayers(3, frost: 1, solid: 1)
        assertLayers(.nan, frost: 1, solid: 0)
        assertLayers(.infinity, frost: 1, solid: 0)
    }

    /// Asserted in Simplified Chinese: in English a broken lookup falls back to
    /// the English text and would pass anyway.
    func testSettingsTextIsTranslated() {
        let store = LocaleOverrideStore.shared
        let previous = store.override
        store.set("zh-Hans")
        defer { store.set(previous) }
        XCTAssertEqual(L10n.display.windowBackground, "窗口背景")
        XCTAssertEqual(L10n.display.windowBackgroundClear, "透明")
        XCTAssertEqual(L10n.display.windowBackgroundSolid, "不透明")
        XCTAssertTrue(L10n.display.windowBackgroundHint.contains("磨砂玻璃"))
    }
}
#endif
