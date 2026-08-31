import Foundation

/// Price arithmetic for CLI Pulse's own paywall.
///
/// Distinct from `SubscriptionPricing`, which is the table of what *provider*
/// plans (Claude Pro, ChatGPT Plus, …) cost — that one answers "how much is
/// the user already spending", this one answers "what may we claim about our
/// own plans".
///
/// **Why it exists.** "Yearly (Save 17%)" was a hardcoded literal in six
/// locales, plus a seventh copy in `SubscriptionSection`. 17% was correct
/// once, for $4.99/month against $49.99/year. When the App Store prices became
/// $0.99/month and $12.99/year the literal stayed — and by then it was not
/// merely stale but inverted: twelve monthly payments come to $11.88, so the
/// yearly plan costs $1.11 **more**. The app advertised a discount for
/// choosing the more expensive option, in six languages, and the same claim
/// was baked into the App Store screenshot queued for upload.
///
/// A number derived from prices cannot be written down beside the prices; it
/// has to be computed from them, or it is only ever accidentally true.
public enum PaywallPricing {

    /// Whole-percent saving of one yearly payment against twelve monthly ones.
    ///
    /// Returns `nil` when there is nothing honest to advertise — a missing or
    /// non-positive price, a yearly plan that costs the same or more, or a
    /// saving that rounds to 0%. Callers show a plain "Yearly" label then,
    /// rather than a badge claiming 0%.
    public static func yearlySavingPercent(monthly: Decimal, yearly: Decimal) -> Int? {
        guard monthly > 0, yearly > 0 else { return nil }
        let twelveMonths = monthly * 12
        guard yearly < twelveMonths else { return nil }
        let fraction = (twelveMonths - yearly) / twelveMonths
        let percent = (fraction as NSDecimalNumber).doubleValue * 100
        guard percent.isFinite else { return nil }
        let rounded = Int(percent.rounded())
        return rounded > 0 ? rounded : nil
    }
}
