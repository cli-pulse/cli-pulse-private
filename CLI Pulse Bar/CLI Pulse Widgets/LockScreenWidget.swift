import WidgetKit
import SwiftUI
import CLIPulseCore

// MARK: - Lock Screen Widget (iOS 17+)

@available(iOSApplicationExtension 17.0, *)
struct UsageLockScreenWidget: Widget {
    let kind = "UsageLockScreenWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CLIPulseTimelineProvider()) { entry in
            LockScreenWidgetView(entry: entry)
        }
        .configurationDisplayName(L10n.widget.usageTitle)
        .description(L10n.widget.usageDescription)
        #if os(iOS)
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
        #endif
    }
}

// MARK: - Lock Screen Views

@available(iOSApplicationExtension 17.0, *)
struct LockScreenWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: CLIPulseEntry

    var body: some View {
        // v1.30 — lock-screen widgets are Pro-only (fail-open on nil).
        if entry.data.isPro == false {
            switch family {
            case .accessoryInline:
                lockedInline
            case .accessoryRectangular:
                lockedRectangular
            default:
                lockedCircular
            }
        } else {
            switch family {
            case .accessoryCircular:
                circularView
            case .accessoryRectangular:
                rectangularView
            case .accessoryInline:
                inlineView
            default:
                circularView
            }
        }
    }

    // MARK: - Locked (free tier)

    private var lockedCircular: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: "lock.fill")
                .font(.system(size: 15, weight: .semibold))
        }
    }

    private var lockedRectangular: some View {
        HStack(spacing: 4) {
            Image(systemName: "lock.fill")
                .font(.system(size: 10))
            Text(L10n.widget.proLockedTitle)
                .font(.caption2.weight(.bold))
            Spacer(minLength: 0)
        }
    }

    private var lockedInline: some View {
        Label(L10n.widget.proLockedTitle, systemImage: "lock.fill")
    }

    // MARK: - Circular: Usage gauge

    private var circularView: some View {
        let topProvider = entry.data.providers.first
        let percent = topProvider?.usagePercent ?? 0
        let usedPercent = Int(percent * 100)

        return ZStack {
            AccessoryWidgetBackground()

            Gauge(value: min(percent, 1.0)) {
                Image(systemName: topProvider?.iconName ?? "waveform.path.ecg")
                    .font(.system(size: 10))
            } currentValueLabel: {
                Text("\(usedPercent)")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
            }
            .gaugeStyle(.accessoryCircular)
        }
        // The gauge's only label is a provider icon, so VoiceOver read a bare
        // number: say whose it is and that it is the USED share. With no
        // provider it draws 0 but says "No data".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.a11y.percentUsedOrNoData(topProvider?.name, usedPercent))
    }

    // MARK: - Rectangular: Provider summary

    private var rectangularView: some View {
        let providers = Array(entry.data.providers.prefix(2))

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 8))
                Text(L10n.auth.title)
                    .font(.caption2.weight(.bold))
            }

            if providers.isEmpty {
                Text(L10n.widget.noData)
                    .font(.caption2)
            } else {
                ForEach(providers) { p in
                    let usedPercent = Int(p.usagePercent * 100)
                    HStack(spacing: 4) {
                        Text(p.name)
                            .font(.caption2)
                            .lineLimit(1)
                        Spacer()
                        Text("\(usedPercent)%")
                            .font(.caption2.weight(.bold).monospacedDigit())

                        Gauge(value: min(p.usagePercent, 1.0)) {
                            EmptyView()
                        }
                        .gaugeStyle(.accessoryLinear)
                        .frame(width: 40)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L10n.a11y.percentUsed(p.name, usedPercent))
                }
            }
        }
    }

    // MARK: - Inline: Text summary

    private var inlineView: some View {
        let topProvider = entry.data.providers.first
        let percent = topProvider.map { Int($0.usagePercent * 100) } ?? 0
        let name = topProvider?.name ?? L10n.auth.title

        return Text(verbatim: "\(name) \(percent)% • \(L10n.watch.sessionsCount(entry.data.activeSessions))")
            // The terse line says neither that the share is used (the circular
            // and rectangular families do) nor what the count is; VoiceOver
            // gets the whole clauses instead ("No data" in place of the 0%
            // drawn when there is no provider).
            .accessibilityLabel(L10n.a11y.usageAndSessions(
                topProvider?.name, percentUsed: percent, activeSessions: entry.data.activeSessions))
    }
}

// MARK: - Preview

#if os(iOS)
@available(iOSApplicationExtension 17.0, *)
#Preview(as: .accessoryCircular) {
    UsageLockScreenWidget()
} timeline: {
    CLIPulseEntry(date: .now, data: .preview)
}

@available(iOSApplicationExtension 17.0, *)
#Preview(as: .accessoryRectangular) {
    UsageLockScreenWidget()
} timeline: {
    CLIPulseEntry(date: .now, data: .preview)
}
#endif
