// The card on the Mac's Overview that says Codex figures changed, and why.
// Everything it says, and whether it shows at all, is decided by
// `CodexEstimateChangeNote`; this only lays the strings out. Not a pop-up: it
// sits among the other one-time notices at the top of the Overview, and "Got
// it" removes it for good.

#if os(macOS)
import SwiftUI

public struct CodexEstimateChangeNoteCard: View {
    /// Written by `DailyUsageArchiveManager` in the standard defaults. Read
    /// through `@AppStorage` so the card appears when the first scan after
    /// the update records the change, without a refresh of its own.
    @AppStorage(CodexEstimateChangeNote.defaultsKey) private var noteData: Data?
    @AppStorage(CodexEstimateChangeNote.dismissedKey) private var dismissed = false

    /// Demo mode shows sample numbers, which never changed; the note would be
    /// about someone else's history, and would sit in the App Store shots.
    private let hidden: Bool

    public init(hidden: Bool) { self.hidden = hidden }

    public var body: some View {
        if !hidden,
           let note = CodexEstimateChangeNote.decode(noteData),
           let p = note.presentation(todayKey: DayKey.string(from: Date()), dismissed: dismissed) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle")
                    .foregroundStyle(PulseTheme.accent)
                    .font(.system(size: 14))
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.title)
                        .font(.system(size: 11, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(p.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(p.footer)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(p.dismiss) { dismissed = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(PulseTheme.accent.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
#endif
