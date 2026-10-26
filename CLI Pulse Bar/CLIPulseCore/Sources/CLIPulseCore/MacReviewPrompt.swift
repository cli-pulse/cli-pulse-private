// macOS-only: the rule is the Mac App Store build's, and its one caller is a
// provider card on the Mac.
#if os(macOS)
import Foundation

/// 1.59 (59-16): when the Mac App Store build asks for a rating.
///
/// The Mac users who have seen what the app is for are the ones whose
/// provider cards show a cost, and that view does not depend on sync
/// working. So the app asks them, through the system's rating prompt, and
/// nobody else:
///
/// - only in the Mac App Store build. The Developer ID build never asks: it
///   has no App Store page to rate. `isAppStoreBuild` is false there at
///   compile time, and in a QA build at run time;
/// - only once a provider card has shown a cost above zero on at least
///   `costDaysNeeded` different days (`DayKey`, the device's days). Days
///   count from 1.59 on, and Try Demo's figures never count;
/// - never in the app's first session on this Mac: the launch
///   `FirstRunPresentation` calls a new install, all of it, however many days
///   it runs;
/// - at most once per app version.
///
/// The system decides whether the prompt actually appears (it shows it at
/// most a few times a year); the version is recorded as asked either way, so
/// a version never asks twice. No copy of our own, nothing sent anywhere.
public enum MacReviewPromptPolicy {
    /// Different days on which a card showed a cost, before the app asks.
    public static let costDaysNeeded = 3

    /// Whether to ask now. Pure, so a test can walk every case.
    public static func shouldAsk(
        costDays: Int,
        askedVersion: String?,
        appVersion: String,
        isFirstSession: Bool,
        isAppStoreBuild: Bool
    ) -> Bool {
        guard isAppStoreBuild, !isFirstSession, !appVersion.isEmpty else { return false }
        guard askedVersion != appVersion else { return false }
        return costDays >= costDaysNeeded
    }

    /// Whether a provider card shows a cost the rule counts: the cost
    /// figures are drawn (costs on, the usage totals not hidden on the
    /// card) and one of Today, This Week or 30 Days is above zero. A "—" or
    /// a $0.00 is not a cost shown, and neither is anything in Try Demo.
    public static func cardShowsCost(
        _ usage: ProviderCardUsage, showsCost: Bool, totalsVisible: Bool, isDemoMode: Bool
    ) -> Bool {
        guard showsCost, totalsVisible, !isDemoMode else { return false }
        return ProviderUsageWindow.allCases.contains { (usage.cell($0).cost ?? 0) > 0 }
    }

    /// The App Store build, in production. False in the Developer ID build
    /// whatever the run time says, and in a QA build (its own bundle
    /// identifier, `CLIPulseRuntimeEnvironment.Channel.qa`).
    public static func isAppStoreBuild(
        runtimeChannel: CLIPulseRuntimeEnvironment.Channel,
        distribution: DistributionChannel
    ) -> Bool {
        #if DEVID_BUILD
        return false
        #else
        return runtimeChannel == .production && distribution == .mas
        #endif
    }
}

/// The days and the version the rule reads, in this app's defaults.
///
/// Both keys carry the app-owned prefix (`UnsandboxedDataMigration`), like
/// every other key of the app's. Written only in the App Store build, and
/// only after `FirstRunPresentation` has read the defaults at launch.
@MainActor
public final class MacReviewPrompt {
    public static let shared = MacReviewPrompt()

    /// The most recent days on which a card showed a cost, as `DayKey`s.
    public static let costDaysKey = "cli_pulse_review_prompt_cost_days"
    /// The app version that last asked.
    public static let askedVersionKey = "cli_pulse_review_prompt_asked_version"
    /// Only "at least `costDaysNeeded`" matters; the list keeps the latest
    /// few so it cannot grow.
    static let keptDays = 10

    private let defaults: UserDefaults
    private var appVersion = ""
    private var isFirstSession = true
    private var isAppStoreBuild = false

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Called once at launch (`CLIPulseBarApp.init`). Until it is, the
    /// prompt never asks and writes nothing.
    public func begin(appVersion: String, isFirstSession: Bool, isAppStoreBuild: Bool) {
        self.appVersion = appVersion
        self.isFirstSession = isFirstSession
        self.isAppStoreBuild = isAppStoreBuild
    }

    /// The days recorded so far, oldest first.
    public var costDays: [String] {
        defaults.stringArray(forKey: Self.costDaysKey) ?? []
    }

    /// A provider card showed a cost on `day` (a `DayKey`). Records the day,
    /// and returns true when the app should ask for a rating now; the
    /// version is then recorded as asked, so it returns true once a version.
    @discardableResult
    public func costShown(onDay day: String) -> Bool {
        guard isAppStoreBuild, !day.isEmpty else { return false }
        var days = costDays
        if !days.contains(day) {
            days.append(day)
            days.sort()
            if days.count > Self.keptDays {
                days.removeFirst(days.count - Self.keptDays)
            }
            defaults.set(days, forKey: Self.costDaysKey)
        }
        let ask = MacReviewPromptPolicy.shouldAsk(
            costDays: days.count,
            askedVersion: defaults.string(forKey: Self.askedVersionKey),
            appVersion: appVersion,
            isFirstSession: isFirstSession,
            isAppStoreBuild: isAppStoreBuild
        )
        if ask {
            defaults.set(appVersion, forKey: Self.askedVersionKey)
        }
        return ask
    }
}
#endif
