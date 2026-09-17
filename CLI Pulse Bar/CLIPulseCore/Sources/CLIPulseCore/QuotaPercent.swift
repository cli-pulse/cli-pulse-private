import Foundation

/// The two percentages a quota window is read as: how much is used and how
/// much is left.
///
/// WHY ONE RULE
/// Two rules used to meet on the same window. The quota alert rounded USED
/// ("92% used (8% remaining)"), while the provider cards on iPhone and Mac and
/// every Watch surface truncated LEFT ("7% left"). A window 92.1% used then
/// read 8% left in the alert and 7% left on the card beside it, and the card's
/// number did not add up with the alert's.
///
/// Rounding USED is the rule that was already stored: every quota alert row in
/// the cloud carries it in its title and message, so keeping it leaves those
/// rows byte-identical. LEFT is derived from USED, never rounded on its own, so
/// the two always add up to 100 on a window that is not over its quota.
///
/// THE EDGES
/// * More remaining than the quota is 0% used and 100% left.
/// * Less than nothing remaining is over quota. USED keeps the overage ("120%
///   used"), which the alert has always printed, and LEFT stops at 0.
/// * A quota of zero or less has no percentage (`nil`).
public struct QuotaPercent: Equatable, Sendable {
    public let used: Int
    public let left: Int

    /// A known pair, for tests. Everything else goes through `usedAndLeft`.
    init(used: Int, left: Int) {
        self.used = used
        self.left = left
    }

    /// From the window's own counts. Use this whenever the counts are at hand.
    public static func usedAndLeft(quota: Int, remaining: Int) -> QuotaPercent? {
        guard quota > 0 else { return nil }
        // Subtracting as Doubles cannot trap, and it is exact for any count a
        // provider reports (below 2^53), so the alert keeps its old numbers.
        return QuotaPercent(usedPercent: 100.0 * (Double(quota) - Double(remaining)) / Double(quota))
    }

    /// From a consumption fraction (`0.921` is 92.1% used), for the surfaces
    /// that only receive a fraction, such as the Watch rings and the lock-screen
    /// complication. Agrees with `usedAndLeft(quota:remaining:)` for the same
    /// window: see `init(usedPercent:)`.
    public static func usedAndLeft(usedFraction: Double) -> QuotaPercent {
        QuotaPercent(usedPercent: usedFraction.isFinite ? usedFraction * 100 : 0)
    }

    /// The fraction path reaches a percentage through one more division, and a
    /// window exactly half a point from a whole number can land one ulp short
    /// of it: 115 of 200 used is 57.5 from the counts but 57.49999999999999
    /// from `0.575 * 100`, which rounds to 57 instead of 58. Measured over every
    /// window up to a quota of 1,500, 58 windows disagreed that way.
    ///
    /// Snapping to 1e-11 of a point first removes the drift (about 1e-14)
    /// without moving any real value: a percentage of counts below 50 billion
    /// that is not exactly on a half is at least 1e-11 away from it. So the
    /// counts path gives the numbers the alert always gave, and the fraction
    /// path gives the same ones.
    private init(usedPercent raw: Double) {
        let snapped = (raw * 1e11).rounded() / 1e11
        // Clamped before `Int(_:)`, which traps outside Int's range.
        let used = Int(min(max(snapped.rounded(), 0), Double(Int32.max)))
        self.used = used
        self.left = max(0, 100 - used)
    }
}
