#if os(macOS)
import AppKit
import Darwin
import Foundation
import ServiceManagement

/// 1.58: the Mac app empties its LoginItem helper's web cache and cookie file
/// once, for a helper that does not start.
///
/// Since 1.57 the helper empties both itself, the first time it starts after
/// the update (`CredentialedURLSession.purgeLegacyStorageIfNeeded()` in
/// `HelperAppDelegate`). With background sync off it never starts, so what
/// 1.56 and earlier stored there stays: on a Developer ID Mac running 1.57
/// with background sync off, every entry in the helper's `Cache.db` still
/// carried a bearer token (the Codex, Claude and Gemini usage reads).
///
/// Where each build's helper keeps them, and whether the app reaches there:
/// - **Developer ID.** The helper is not sandboxed: `~/Library/Caches/` and
///   `~/Library/HTTPStorages/` under the real home. The app is not sandboxed
///   either and reaches both.
/// - **App Store.** The helper is sandboxed, so the same two places sit in its
///   own container, `~/Library/Containers/yyh.CLI-Pulse.helper/Data`. The
///   sandboxed app reaches its own container and the app group's folder,
///   neither of which holds them: it does nothing, and the helper still
///   empties its own when it starts.
///
/// Which applies is worked out from the paths (`canReach`), before any file
/// call, not assumed per build. An unsandboxed process never touches anything
/// under `~/Library/Containers` or `~/Library/Group Containers`: opening
/// another app's folder there makes macOS ask the user whether CLI Pulse may
/// access data from other apps (see `scripts/check_helper_no_container_touch.sh`
/// for that measurement). So a Mac that moved from the App Store build keeps
/// that build's copies, which PRIVACY.md names for the user to delete.
///
/// Nothing to do once the helper has emptied its own: its 1.57 done-flag, in
/// its own defaults, says so, and the app records that and stops looking.
///
/// Never while the helper may be using them. Not while it runs, and not while
/// its LoginItem is on: launchd may start it at any moment, and it then
/// empties its own. Both sides also take a `flock` on a file in the helper's
/// cache folder: the app for its checks and the deletion, the helper at its
/// start before anything there opens the URL cache
/// (`waitWhileTheAppEmptiesIt`). A helper that starts during the deletion
/// waits for it to end; one that got past the lock first is already
/// registered with LaunchServices, so the app's second check, made holding
/// the lock, sees it running and leaves everything alone. `flock` goes away
/// with the process that held it, however it ends, so no lock is left behind.
public enum HelperCachePurge {

    public static let helperBundleIdentifier = "yyh.CLI-Pulse.helper"

    /// The app's done-flag, in its own defaults. Like
    /// `CredentialedURLSession.purgeDoneKey`, deliberately not under an
    /// app-owned prefix (`UnsandboxedDataMigration.appOwnedKeyPrefixes`): the
    /// move from the App Store build must not carry it over (that build's app
    /// never reaches its helper's folders, and so never writes it anyway), and
    /// the first-run check ignores it.
    public static let doneKey = "CLIPulse.helperCachePurge"
    static let version = 1

    /// The file both sides lock, in the helper's cache folder. Kept when the
    /// folder is emptied: removing it while someone waits on it would hand a
    /// later opener a fresh, unlocked file.
    public static let lockFileName = ".cli-pulse-purge.lock"

    /// How long a starting helper waits for the app at most. The deletion
    /// takes milliseconds; a wait that runs out means something else is
    /// wrong, and the helper starts anyway.
    public static let helperWaitLimit: TimeInterval = 5

    // MARK: - Where the helper keeps them

    /// The helper's web cache folder and cookie file, for a helper whose home
    /// folder is `home`.
    public struct Places: Equatable, Sendable {
        public let cacheFolder: URL
        public let cookieFile: URL

        init(helperHome home: URL) {
            let library = home.appendingPathComponent("Library", isDirectory: true)
            cacheFolder = library
                .appendingPathComponent("Caches", isDirectory: true)
                .appendingPathComponent(HelperCachePurge.helperBundleIdentifier, isDirectory: true)
            cookieFile = library
                .appendingPathComponent("HTTPStorages", isDirectory: true)
                .appendingPathComponent("\(HelperCachePurge.helperBundleIdentifier).binarycookies", isDirectory: false)
        }

        var all: [URL] { [cacheFolder, cookieFile] }
    }

    /// Both builds' helpers: the unsandboxed one (Developer ID) at the real
    /// home, the sandboxed one (App Store) in its own container.
    static func helperPlaces(realHome: URL) -> [Places] {
        let container = realHome
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Containers", isDirectory: true)
            .appendingPathComponent(helperBundleIdentifier, isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
        return [Places(helperHome: realHome), Places(helperHome: container)]
    }

    // MARK: - What this process may touch

    /// What this process can reach without the sandbox refusing or macOS
    /// asking the user.
    public struct Reach: Equatable, Sendable {
        /// The user's home from the password database, whatever the sandbox
        /// does to `NSHomeDirectory()`.
        public var realHome: URL
        public var isSandboxed: Bool
        /// This process's home: its container's `Data` folder when sandboxed.
        public var ownHome: URL
        /// The app group's folder. Looked up only when sandboxed.
        public var groupContainer: URL?

        public init(realHome: URL, isSandboxed: Bool, ownHome: URL, groupContainer: URL?) {
            self.realHome = realHome
            self.isSandboxed = isSandboxed
            self.ownHome = ownHome
            self.groupContainer = groupContainer
        }

        public static func current() -> Reach {
            let sandboxed = MASSandboxGate.isSandboxed
            return Reach(
                realHome: UnsandboxedDataMigration.realUserHome(),
                isSandboxed: sandboxed,
                ownHome: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
                groupContainer: sandboxed
                    ? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: HelperIPC.suiteName)
                    : nil
            )
        }
    }

    /// Whether this process may touch `url`, decided from the path alone, so
    /// nothing is opened, listed or even looked up first.
    ///
    /// Sandboxed: only inside its own container or the app group's folder.
    /// Not sandboxed: anywhere in the home except under `Library/Containers`
    /// and `Library/Group Containers`, where opening another app's folder
    /// makes macOS ask the user.
    static func canReach(_ url: URL, _ reach: Reach) -> Bool {
        if reach.isSandboxed {
            return isInside(url, reach.ownHome)
                || reach.groupContainer.map { isInside(url, $0) } == true
        }
        let library = reach.realHome.appendingPathComponent("Library", isDirectory: true)
        return isInside(url, reach.realHome)
            && !isInside(url, library.appendingPathComponent("Containers", isDirectory: true))
            && !isInside(url, library.appendingPathComponent("Group Containers", isDirectory: true))
    }

    /// The helper's places this process reaches, both of each pair or neither.
    static func reachablePlaces(_ reach: Reach) -> [Places] {
        helperPlaces(realHome: reach.realHome).filter { places in
            places.all.allSatisfy { canReach($0, reach) }
        }
    }

    /// Whether `url` is `folder` or below it, by whole path components: a
    /// sibling whose name merely starts the same (`yyh.CLI-Pulse` and
    /// `yyh.CLI-Pulse.helper`) is not inside.
    static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let path = lexicalComponents(url)
        let base = lexicalComponents(folder)
        return path.count >= base.count && Array(path.prefix(base.count)) == base
    }

    /// The path's components with `.` and `..` folded, from the text alone.
    /// Not `standardizedFileURL`: that one also drops a leading `/private`
    /// when the shorter path exists, which it asks the disk, so a folder that
    /// exists and a file below it that does not yet would stop matching.
    static func lexicalComponents(_ url: URL) -> [String] {
        var components: [String] = []
        for component in url.path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(String(component))
            }
        }
        return components
    }

    // MARK: - What the helper does, has done, or may do

    public struct HelperState {
        public var isRunning: () -> Bool
        /// The LoginItem is on, so launchd may start it at any moment.
        public var isLoginItemEnabled: () -> Bool
        /// The helper's own 1.57 purge has run: it emptied both itself, and
        /// has kept no credentialed request since.
        public var hasEmptiedItsOwn: () -> Bool

        public init(
            isRunning: @escaping () -> Bool,
            isLoginItemEnabled: @escaping () -> Bool,
            hasEmptiedItsOwn: @escaping () -> Bool
        ) {
            self.isRunning = isRunning
            self.isLoginItemEnabled = isLoginItemEnabled
            self.hasEmptiedItsOwn = hasEmptiedItsOwn
        }

        public static var live: HelperState {
            HelperState(
                isRunning: {
                    !NSRunningApplication.runningApplications(withBundleIdentifier: helperBundleIdentifier).isEmpty
                },
                // `.requiresApproval` (switched off in System Settings),
                // `.notRegistered` and `.notFound` all mean launchd will not
                // start it.
                isLoginItemEnabled: {
                    SMAppService.loginItem(identifier: helperBundleIdentifier).status == .enabled
                },
                // The helper keeps its done-flag in its own defaults domain.
                // Asked only once the helper's places were found reachable,
                // which is the unsandboxed app: that domain is then the
                // unsandboxed helper's, the one whose places these are.
                hasEmptiedItsOwn: {
                    HelperCachePurge.hasEmptiedItsOwn(UserDefaults(suiteName: helperBundleIdentifier))
                }
            )
        }

        var isActive: Bool { isRunning() || isLoginItemEnabled() }
    }

    static func hasEmptiedItsOwn(_ helperDefaults: UserDefaults?) -> Bool {
        (helperDefaults?.integer(forKey: CredentialedURLSession.purgeDoneKey) ?? 0)
            >= CredentialedURLSession.purgeVersion
    }

    // MARK: - The app's side

    public enum Outcome: Equatable, Sendable {
        /// Done on an earlier launch.
        case alreadyDone
        /// None of the helper's places is reachable from here (the App Store
        /// build). Nothing is recorded: nothing was done.
        case unreachable
        /// The helper emptied both itself already. Recorded as done.
        case helperEmptiedItsOwn
        /// The helper runs, or its LoginItem is on. Left alone; tried again at
        /// the next launch.
        case helperActive
        /// Someone holds the lock (a starting helper), or the lock file could
        /// not be opened. Tried again at the next launch.
        case busy
        /// Nothing was there (a helper that never ran). Recorded as done.
        case nothingThere
        /// This many items were removed (folder entries and the cookie file).
        case emptied(removed: Int)
        /// Something was not as expected, or could not be removed. Not
        /// recorded; tried again at the next launch.
        case failed
    }

    /// Empties the helper's web cache folder (all but the lock file) and
    /// removes its cookie file, once, where this process reaches them and the
    /// helper is neither running nor able to start. Synchronous: call it at
    /// launch, before anything that could turn the LoginItem on.
    @discardableResult
    public static func purgeIfNeeded(
        defaults: UserDefaults = .standard,
        reach: Reach? = nil,
        helper: HelperState = .live
    ) -> Outcome {
        purgeIfNeeded(defaults: defaults, reach: reach, helper: helper, files: .live)
    }

    static func purgeIfNeeded(
        defaults: UserDefaults,
        reach: Reach?,
        helper: HelperState,
        files: FileAccess
    ) -> Outcome {
        guard defaults.integer(forKey: doneKey) < version else { return .alreadyDone }
        let targets = reachablePlaces(reach ?? .current())
        guard !targets.isEmpty else { return .unreachable }
        if helper.hasEmptiedItsOwn() {
            defaults.set(version, forKey: doneKey)
            return .helperEmptiedItsOwn
        }
        guard !helper.isActive else { return .helperActive }

        var removed = 0
        for places in targets {
            let folder = files.itemType(places.cacheFolder)
            let hasCookieFile = files.itemType(places.cookieFile) != nil
            if folder == nil, !hasCookieFile { continue }
            // A link or a file where the folder belongs: not something this
            // code made sense of, so it empties nothing through it.
            if let folder, folder != .typeDirectory { return .failed }
            do {
                if folder == nil { try files.createDirectory(places.cacheFolder) }
            } catch {
                return .failed
            }
            guard let lock = files.lock(places.cacheFolder.appendingPathComponent(lockFileName, isDirectory: false)) else {
                return .busy
            }
            defer { lock.release() }
            // Again, holding the lock: a helper that started since the check
            // above is registered by the time it reaches the lock.
            guard !helper.isActive else { return .helperActive }
            do {
                for item in try files.contents(places.cacheFolder) where item.lastPathComponent != lockFileName {
                    try files.remove(item)
                    removed += 1
                }
                if hasCookieFile {
                    try files.remove(places.cookieFile)
                    removed += 1
                }
            } catch {
                return .failed
            }
        }
        // `removeItem` is done when it returns (unlike URLCache's own purge,
        // which deletes in the background), so the flag can follow at once.
        defaults.set(version, forKey: doneKey)
        return removed == 0 ? .nothingThere : .emptied(removed: removed)
    }

    // MARK: - The helper's side

    /// The helper's side, at its start, before anything opens its URL cache:
    /// waits while an app holds the lock, for at most `limit`. Returns false
    /// when the wait ran out or the lock file could not be opened; the helper
    /// starts either way.
    @discardableResult
    public static func waitWhileTheAppEmptiesIt(
        cacheFolder: URL? = nil,
        limit: TimeInterval = helperWaitLimit
    ) -> Bool {
        let folder = cacheFolder ?? ownCacheFolder()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fd = openLockFile(folder.appendingPathComponent(lockFileName, isDirectory: false))
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let deadline = Date().addingTimeInterval(limit)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let error = errno
            if error == EINTR { continue }
            guard error == EWOULDBLOCK, Date() < deadline else { return false }
            usleep(20_000)
        }
        flock(fd, LOCK_UN)
        return true
    }

    /// This process's URL cache folder: `<Caches>/<bundle id>`, inside the
    /// container when sandboxed.
    static func ownCacheFolder() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Caches", isDirectory: true)
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? helperBundleIdentifier, isDirectory: true)
    }

    // MARK: - Files

    /// The file calls the app's side makes, all through here, so a test can
    /// see every path it touches.
    struct FileAccess {
        /// The item's type, not following a final link; nil when nothing is there.
        var itemType: (URL) -> FileAttributeType?
        var contents: (URL) throws -> [URL]
        var createDirectory: (URL) throws -> Void
        var remove: (URL) throws -> Void
        /// An exclusive lock on the file, taken without waiting; nil when
        /// someone else holds it or it cannot be opened.
        var lock: (URL) -> HeldLock?

        static let live = FileAccess(
            itemType: { url in
                (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
            },
            contents: { url in
                try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            },
            createDirectory: { url in
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            },
            remove: { url in try FileManager.default.removeItem(at: url) },
            lock: { url in HeldLock.take(url) }
        )
    }

    /// An exclusive `flock` this process holds until `release()`.
    final class HeldLock {
        private var fd: Int32

        private init(fd: Int32) {
            self.fd = fd
        }

        static func take(_ url: URL) -> HeldLock? {
            let fd = openLockFile(url)
            guard fd >= 0 else { return nil }
            while flock(fd, LOCK_EX | LOCK_NB) != 0 {
                if errno == EINTR { continue }
                close(fd)
                return nil
            }
            return HeldLock(fd: fd)
        }

        func release() {
            guard fd >= 0 else { return }
            flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }

        deinit {
            release()
        }
    }

    /// Opens (creating) the lock file, refusing a link in its place.
    static func openLockFile(_ url: URL) -> Int32 {
        open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    }
}
#endif
