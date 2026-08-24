#if os(macOS)
import Foundation

/// What one row of Settings › CLI Tool Access should say and offer.
///
/// v1.50 W0. The list used to have two states and needed three, and the missing
/// one was the common one on the Mac App Store build.
public enum FolderAccessRowState: Equatable, Sendable {
    /// A bookmark is held. The app can read this directory.
    case granted
    /// No bookmark. The directory may or may not exist — offer Grant.
    case grantable
    /// The app can see this part of the filesystem, and there is nothing here.
    case notInstalled
}

public enum FolderAccessRowPolicy {

    /// v1.50 W0 — never say "Not installed" when the truth is "not permitted".
    ///
    /// `KnownDirectory.isInstalled` is `FileManager.fileExists`, and its own doc
    /// comment admits it is "unreliable inside the sandbox for dirs that haven't
    /// been granted a bookmark yet". `alwaysShow` was added to stop those rows
    /// being filtered out of the list — the chicken-and-egg where the only way
    /// to grant a bookmark is a button that the missing bookmark hides.
    ///
    /// One line later, the fix was undone. `FolderAccessView` rendered
    /// `alwaysShow && !isInstalled` as the text "Not installed" **and no Grant
    /// button** — reinstating the same dead end for exactly the rows the flag
    /// exists to rescue, and telling the user something false on the way: their
    /// Codex logs are there, the sandbox simply cannot see them yet.
    ///
    /// The missing distinction is not "does it exist" but **"can we tell?"**.
    /// A sandboxed process with no bookmark cannot tell, and "I cannot see it"
    /// is not evidence of absence. Only a build that can actually read the path
    /// — unsandboxed, or already holding the bookmark — may claim `notInstalled`.
    ///
    /// This also widens the fix past the `alwaysShow` rows. Under the sandbox
    /// `existsOnDisk` is false for *every* ungranted directory, so the list's
    /// `isInstalled || alwaysShow` filter was hiding genuinely-present ones too
    /// — `~/.codex/` among them. Those rows come back.
    public static func state(
        hasAccess: Bool,
        existsOnDisk: Bool,
        isSandboxed: Bool
    ) -> FolderAccessRowState {
        if hasAccess { return .granted }
        if existsOnDisk { return .grantable }
        return isSandboxed ? .grantable : .notInstalled
    }

    /// Whether the row appears at all.
    ///
    /// A directory we can see is absent stays hidden unless it is `alwaysShow` —
    /// listing every CLI the user does not have would bury the ones they do.
    /// Everything else is listed, because everything else is actionable.
    public static func isVisible(
        state: FolderAccessRowState,
        alwaysShow: Bool
    ) -> Bool {
        state != .notInstalled || alwaysShow
    }
}
#endif
