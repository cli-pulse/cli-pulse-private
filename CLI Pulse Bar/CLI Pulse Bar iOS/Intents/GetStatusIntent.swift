import AppIntents
import CLIPulseCore
import Foundation

@available(iOS 17.0, *)
struct GetStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Get CLI Pulse Status"
    static var description = IntentDescription(
        "Get today's total usage, cost, active sessions, and unresolved alerts across all providers.",
        categoryName: "Status"
    )

    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        guard let snapshot = CLIPulseIntentCache.load() else {
            let dialog = IntentDialog(stringLiteral: L10n.intents.noDataDialog)
            return .result(value: L10n.intents.noDataValue, dialog: dialog)
        }

        let usage = TokenFormatter.format(snapshot.totalUsageToday)
        // In the currency the app shows. This intent is compiled into the iOS
        // app target, so it runs in the app's process and reads the app's own
        // defaults; it reads the choice directly because Siri can run it without
        // the app's `AppState` ever having applied it.
        let cost = CurrencyConverter.shared.spokenFormat(snapshot.totalCostToday, as: .stored())
        // Composed in CLIPulseCore, where `IntentSpeechTests` exercises this exact
        // function; `IntentSpeechTests` also reads this file and fails if the
        // answer is ever assembled here again.
        let spoken = L10n.intents.statusSummary(
            usage: usage,
            cost: cost,
            sessions: snapshot.activeSessions,
            alerts: snapshot.unresolvedAlerts
        )

        let dialog = IntentDialog(stringLiteral: spoken)
        return .result(value: spoken, dialog: dialog)
    }
}
