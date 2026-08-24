#if os(macOS)
import SwiftUI
import AppKit

/// Settings section for managing folder access permissions.
/// Users grant access to CLI tool credential directories via NSOpenPanel.
public struct FolderAccessView: View {
    @EnvironmentObject var state: AppState
    @State private var statuses: [(directory: BookmarkManager.KnownDirectory, hasAccess: Bool, isInstalled: Bool)] = []
    @State private var isRescanning = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "folder.badge.gearshape")
                    .foregroundStyle(.secondary)
                Text(L10n.folderAccess.title)
                    .font(.system(size: 13, weight: .semibold))
            }

            Text(L10n.folderAccess.intro)
                .font(.caption)
                .foregroundStyle(.secondary)

            // v1.9.4: show a row when the dir exists on disk OR when the
            // entry is flagged `alwaysShow` (sandbox hides session-log dirs
            // until a bookmark is granted → filter would strip the only way
            // to grant the bookmark → chicken-and-egg).
            //
            // v1.50 W0: that filter asked `isInstalled`, which under the sandbox
            // is false for every directory without a bookmark — including the
            // ones that are right there on disk. Route both the filter and the
            // trailing control through `FolderAccessRowPolicy` so "cannot see"
            // stops being reported as "not installed".
            ForEach(visibleRows, id: \.directory.id) { item in
                HStack {
                    Image(systemName: item.hasAccess ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(item.hasAccess ? .green : .orange)
                        .font(.system(size: 14))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.directory.displayName)
                            .font(.system(size: 12, weight: .medium))
                        Text(item.directory.path)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    switch rowState(for: item) {
                    case .granted:
                        Text(L10n.folderAccess.granted)
                            .font(.caption)
                            .foregroundStyle(.green)
                    case .notInstalled:
                        // An `alwaysShow` dir that genuinely is not on this Mac
                        // (e.g. ~/.config/claude/projects when the user does not
                        // set CLAUDE_CONFIG_DIR). Grant would fail; a subtle
                        // label beats a dead button.
                        //
                        // v1.50 W0: reachable only when the app can actually see
                        // the path. Under the sandbox with no bookmark this
                        // branch used to swallow every ungranted row, so a user
                        // whose Codex logs were sitting right there was told they
                        // were not installed and given no way to say otherwise.
                        Text(L10n.folderAccess.notInstalled)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    case .grantable:
                        Button(L10n.folderAccess.grant) {
                            let success = BookmarkManager.shared.requestAccessViaPanel(
                                directory: item.directory
                            )
                            if success {
                                refreshStatuses()
                                // Auto re-scan so usage appears immediately
                                // (forceRescanTokenCache re-activates bookmarks).
                                Task { await state.forceRescanTokenCache() }
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 2)
            }

            if visibleRows.filter({ rowState(for: $0) == .grantable }).count > 1 {
                Divider()
                Button {
                    grantAll()
                } label: {
                    HStack {
                        Image(systemName: "folder.badge.plus")
                        Text(L10n.folderAccess.grantAll)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            // v1.9.4: force a full rescan of JSONL logs. Wipes the on-disk
            // scanner cache and re-parses from scratch. Needed after a
            // long stretch of sandbox-blocked runs (v1.9.2 / v1.9.3) that
            // may have recorded negative deltas that normal incremental
            // scans won't unwind — symptom: token totals stuck lower than
            // ground-truth.
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.folderAccess.rescanTitle)
                        .font(.system(size: 12, weight: .medium))
                    Text(L10n.folderAccess.rescanDetail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task {
                        isRescanning = true
                        defer { isRescanning = false }
                        await state.forceRescanTokenCache()
                    }
                } label: {
                    if isRescanning {
                        ProgressView().controlSize(.small)
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text(L10n.folderAccess.forceRescan)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRescanning)
            }
        }
        .onAppear { refreshStatuses() }
    }

    /// v1.50 W0: one place that turns a raw status tuple into the three-state
    /// answer, so the row's label, the row's control and the "Grant All"
    /// threshold cannot drift apart. They had: the filter said `isInstalled ||
    /// alwaysShow` while the trailing control said `alwaysShow && !isInstalled`,
    /// and their overlap was a row that appeared with nothing to press.
    private func rowState(
        for item: (directory: BookmarkManager.KnownDirectory, hasAccess: Bool, isInstalled: Bool)
    ) -> FolderAccessRowState {
        FolderAccessRowPolicy.state(
            hasAccess: item.hasAccess,
            existsOnDisk: item.isInstalled,
            isSandboxed: MASSandboxGate.isSandboxed
        )
    }

    private var visibleRows: [(directory: BookmarkManager.KnownDirectory, hasAccess: Bool, isInstalled: Bool)] {
        statuses.filter {
            FolderAccessRowPolicy.isVisible(
                state: rowState(for: $0),
                alwaysShow: $0.directory.alwaysShow
            )
        }
    }

    private func refreshStatuses() {
        guard state.runtimeEnvironment.capabilities.allowsLiveCollection else {
            statuses = []
            return
        }
        statuses = BookmarkManager.shared.accessStatus()
    }

    private func grantAll() {
        guard state.runtimeEnvironment.capabilities.allowsLiveCollection else {
            return
        }
        // Open panel at home directory — grants access to all subdirectories
        let panel = NSOpenPanel()
        panel.message = L10n.folderAccess.panelMessage
        panel.prompt = L10n.folderAccess.panelPrompt
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = URL(fileURLWithPath: realUserHome())

        if panel.runModal() == .OK, let url = panel.url {
            BookmarkManager.shared.storeBookmark(for: url)
            // After we hold a bookmark to the root, `FileManager.fileExists`
            // reports truthfully for subdirs. Only store bookmarks for dirs
            // that ACTUALLY exist — `storeBookmark` on a nonexistent path
            // logs "scoped bookmarks can only be created for existing files"
            // and clutters the log even though it's harmless.
            // (`alwaysShow` governs UI visibility, not bookmark creation.)
            let rootURL = url
            let rootStarted = rootURL.startAccessingSecurityScopedResource()
            defer { if rootStarted { rootURL.stopAccessingSecurityScopedResource() } }

            // v1.50 W0: iterate every known directory, not the `isInstalled ||
            // alwaysShow` subset. `isInstalled` was computed BEFORE the root
            // bookmark existed, so under the sandbox it was false for every
            // directory including the ones sitting right there — and Grant All
            // silently skipped them. The `fileExists` guard on the next line is
            // the correct filter and, unlike the old one, it runs while the root
            // bookmark is held, which is exactly when the answer is truthful.
            for status in statuses {
                let subURL = URL(fileURLWithPath: status.directory.expandedPath)
                guard FileManager.default.fileExists(atPath: subURL.path) else {
                    continue
                }
                BookmarkManager.shared.storeBookmark(for: subURL)
            }
            refreshStatuses()
            // Auto re-scan so usage appears right after a "grant all" (the
            // rescan re-activates the just-stored bookmarks via
            // resolveAllBookmarks), instead of needing a separate manual
            // "Force re-scan" tap.
            Task { await state.forceRescanTokenCache() }
        }
    }
}
#endif
