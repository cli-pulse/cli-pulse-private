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

        let usage = formatUsage(snapshot.totalUsageToday)
        let cost = formatCost(snapshot.totalCostToday)
        let sessions = snapshot.activeSessions
        let alerts = snapshot.unresolvedAlerts

        // Whole clauses joined by the locale's own separator. This used to be one
        // English string grown by `+=` with inline plurals, which no translation
        // can follow; the English output is unchanged.
        var clauses = [L10n.intents.statusToday(usage, cost)]
        if sessions > 0 {
            clauses.append(L10n.intents.activeSessions(sessions))
        }
        clauses.append(alerts > 0 ? L10n.intents.openAlerts(alerts) : L10n.intents.noOpenAlerts)
        let spoken = clauses.joined(separator: L10n.intents.clauseSeparator) + L10n.intents.sentenceEnd

        let dialog = IntentDialog(stringLiteral: spoken)
        return .result(value: spoken, dialog: dialog)
    }

    private func formatUsage(_ usage: Int) -> String {
        if usage >= 1_000_000 {
            return String(format: "%.1fM", Double(usage) / 1_000_000)
        } else if usage >= 1_000 {
            return String(format: "%.0fK", Double(usage) / 1_000)
        }
        return "\(usage)"
    }

    private func formatCost(_ cost: Double) -> String {
        // Stays USD, deferred with the widget/watch to a future app-group
        // currency-sync pass. (An earlier note here said this intent ran in a
        // separate extension process without CLIPulseCore. It does not: it is
        // compiled into the iOS app target, which links CLIPulseCore — checked
        // against the project's target membership.)
        if cost < 0.01 { return L10n.intents.lessThanOneCent }
        return String(format: "$%.2f", cost)
    }
}
