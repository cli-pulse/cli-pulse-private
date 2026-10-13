// The row's content follows steipete/CodexBar
// Sources/CodexBar/MenuCardView+CodexResetCredits.swift (`LimitResetCreditsContent`:
// the title, the count, a clock and the countdown summary, every credit in the
// tooltip), taken at upstream commit 25bba9b7, 2026-09-28
// (https://github.com/steipete/CodexBar).
//
// Not verbatim: one line instead of two, to keep the card's growth to one row;
// the tier rows' type sizes; countdowns folded into "+N" to fit the width; and
// the App Store build's folder-access state, which upstream does not have.
//
// ─── MIT License (full notice required by upstream) ───────────────
//
// MIT License
//
// Copyright (c) 2026 Peter Steinberger
//
// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use, copy,
// modify, merge, publish, distribute, sublicense, and/or sell copies
// of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
// OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
// HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
// WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.

#if os(macOS)
import SwiftUI

/// The Codex card's limit-reset-credits line (v1.57), one line high in every
/// state that draws anything, so the card grows by one row at most:
///
///     Limit reset credits          2 available  🕒 6d 4h · 21d 9h
///     Limit reset credits                  Allow access to ~/.codex
///
/// The tier rows' type sizes (`UsageBar`, `BalanceRow`): the title at 11 pt,
/// the detail at 10. The title and the count never truncate. The countdowns
/// take what width is left: four of them when they fit, otherwise as many as
/// fit with "+N" for the rest, and only past one countdown does the text
/// shrink and then truncate. The tooltip lists every credit.
public struct CodexResetCreditsRow: View {
    public let state: CodexResetCreditsCardState
    public let onAllowCodexFolder: () -> Void

    public init(state: CodexResetCreditsCardState, onAllowCodexFolder: @escaping () -> Void) {
        self.state = state
        self.onAllowCodexFolder = onAllowCodexFolder
    }

    public var body: some View {
        switch state {
        case .hidden:
            EmptyView()
        case .inventory(let presentation):
            inventoryRow(presentation)
        case .needsCodexFolderAccess:
            folderAccessRow
        }
    }

    private var title: some View {
        Text(L10n.resetCredits.title)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .fixedSize()
    }

    private func inventoryRow(_ presentation: CodexResetCreditsPresentation) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            title
            Spacer(minLength: 6)
            Text(presentation.text)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            // Four, three, two, one countdown(s): the first that fits whole.
            // `visibleCountdowns` is 4; `expirySummaryText(showing:)` caps it.
            ViewThatFits(in: .horizontal) {
                countdowns(presentation.expirySummaryText(showing: 4)).fixedSize()
                countdowns(presentation.expirySummaryText(showing: 3)).fixedSize()
                countdowns(presentation.expirySummaryText(showing: 2)).fixedSize()
                countdowns(presentation.expirySummaryText(showing: 1)).fixedSize()
                countdowns(presentation.expirySummaryText(showing: 1))
                    .minimumScaleFactor(0.75)
            }
        }
        .help(presentation.helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    private func countdowns(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Image(systemName: "clock")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var folderAccessRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            title
            Spacer(minLength: 6)
            Button(action: onAllowCodexFolder) {
                Text(L10n.resetCredits.allowCodexFolder)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .buttonStyle(.link)
        }
        .help(L10n.resetCredits.allowCodexFolderHelp)
    }
}

/// The Codex CLI folder grant the App Store build needs to read the Codex
/// sign-in (`BookmarkManager`'s "codex" entry, `~/.codex`). The session-log
/// grants are separate entries and are not asked here.
@MainActor
public enum CodexResetCreditsFolder {
    static var directory: BookmarkManager.KnownDirectory {
        BookmarkManager.knownDirectories.first { $0.id == "codex" }
            ?? BookmarkManager.KnownDirectory(
                id: "codex", path: "~/.codex/", displayName: "Codex CLI", detectionFile: "auth.json"
            )
    }

    public static var hasAccess: Bool {
        BookmarkManager.shared.hasAccess(to: directory.expandedPath)
    }

    /// The folder panel, rooted at `~/.codex`. True when the user granted it.
    public static func requestAccess() -> Bool {
        BookmarkManager.shared.requestAccessViaPanel(directory: directory)
    }
}
#endif
