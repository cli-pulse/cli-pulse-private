#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// 1.58: the Mac app empties its LoginItem helper's web cache and cookie file
/// once, for a helper that background sync never starts (`HelperCachePurge`).
///
/// What is pinned here: where each build's helper keeps them; that the
/// Developer ID app reaches only the unsandboxed helper's places and the App
/// Store app none, decided before any file call, and that nothing else is
/// touched; that a helper which emptied its own, as its own preferences file
/// says, is left alone for good; that a running helper, an enabled LoginItem,
/// a helper that starts during the checks and one holding the lock are all
/// left alone; that the helper waits at its start while the app holds the
/// lock and then holds it for as long as it runs; that a real URL cache's
/// credentialed entries are gone afterwards; that it runs once, off the main
/// thread; and where the app and the helper call it.
final class HelperCachePurgeTests: XCTestCase {

    private static let sampleHome = URL(fileURLWithPath: "/Users/sample", isDirectory: true)

    // MARK: - Where, and whether the app reaches there

    func testEachBuildsHelperKeepsThemWhereThisLooks() {
        let places = HelperCachePurge.helperPlaces(realHome: Self.sampleHome)
        XCTAssertEqual(places.map { $0.cacheFolder.path }, [
            "/Users/sample/Library/Caches/yyh.CLI-Pulse.helper",
            "/Users/sample/Library/Containers/yyh.CLI-Pulse.helper/Data/Library/Caches/yyh.CLI-Pulse.helper",
        ])
        XCTAssertEqual(places.map { $0.cookieFile.path }, [
            "/Users/sample/Library/HTTPStorages/yyh.CLI-Pulse.helper.binarycookies",
            "/Users/sample/Library/Containers/yyh.CLI-Pulse.helper/Data/Library/HTTPStorages/yyh.CLI-Pulse.helper.binarycookies",
        ])
        XCTAssertEqual(HelperCachePurge.helperBundleIdentifier, HelperLoginItemRestart.identifier)
    }

    /// Developer ID: the app is not sandboxed, reaches the unsandboxed
    /// helper's places, and nothing under `Library/Containers` or
    /// `Library/Group Containers` (macOS asks the user before an unsandboxed
    /// app opens another app's folder there).
    func testTheDeveloperIDAppReachesOnlyTheUnsandboxedHelpersPlaces() {
        let reach = Self.developerIDReach(home: Self.sampleHome)
        let places = HelperCachePurge.helperPlaces(realHome: Self.sampleHome)
        XCTAssertEqual(HelperCachePurge.reachablePlaces(reach), [places[0]])
        for url in places[1].all {
            XCTAssertFalse(HelperCachePurge.canReach(url, reach), "\(url.path) is in the helper's container")
        }
        let group = URL(fileURLWithPath: "/Users/sample/Library/Group Containers/group.yyh.CLI-Pulse/Library/Caches")
        XCTAssertFalse(HelperCachePurge.canReach(group, reach))
        XCTAssertFalse(HelperCachePurge.canReach(URL(fileURLWithPath: "/Users/other/Library/Caches/x"), reach))
        XCTAssertFalse(HelperCachePurge.canReach(
            URL(fileURLWithPath: "/Users/sample/Library/Containers/../Containers/yyh.CLI-Pulse.helper/Data"), reach
        ), "a `..` must not walk around the check")
    }

    /// App Store: the sandboxed app reaches its own container and the app
    /// group's folder. The helper keeps its places in a container of its own,
    /// so none is reached, and the purge makes no file call at all. The
    /// positive side: had the helper used the app's container or the group's
    /// folder, it would be reached.
    func testTheAppStoreAppReachesNoneOfItsHelpersPlaces() {
        let reach = Self.appStoreReach(home: Self.sampleHome)
        XCTAssertEqual(HelperCachePurge.reachablePlaces(reach), [])
        for places in HelperCachePurge.helperPlaces(realHome: Self.sampleHome) {
            for url in places.all {
                XCTAssertFalse(HelperCachePurge.canReach(url, reach), url.path)
            }
        }
        XCTAssertTrue(HelperCachePurge.canReach(
            reach.ownHome.appendingPathComponent("Library/Caches/yyh.CLI-Pulse.helper"), reach
        ))
        XCTAssertTrue(HelperCachePurge.canReach(
            reach.groupContainer!.appendingPathComponent("Library/Caches/yyh.CLI-Pulse.helper"), reach
        ))

        let defaults = isolatedDefaults()
        let recorder = FileCallRecorder(base: .live)
        var asked: [String] = []
        let helper = HelperCachePurge.HelperState(
            isRunning: { asked.append("running"); return false },
            isLoginItemEnabled: { asked.append("LoginItem"); return false },
            hasEmptiedItsOwn: { asked.append("its own purge"); return false }
        )
        let outcome = HelperCachePurge.purgeIfNeeded(
            defaults: defaults, reach: reach, helper: helper, files: recorder.access
        )
        XCTAssertEqual(outcome, .unreachable)
        XCTAssertEqual(recorder.paths, [], "the App Store app looked at files it cannot reach")
        XCTAssertEqual(asked, [], "the App Store app asked about a helper whose places it cannot reach")
        XCTAssertEqual(defaults.integer(forKey: HelperCachePurge.doneKey), 0, "nothing was done, so nothing is recorded")
    }

    /// Inside means by whole path components: `yyh.CLI-Pulse.helper` is not
    /// inside `yyh.CLI-Pulse` though its name starts the same.
    func testInsideIsByWholeComponents() {
        let app = URL(fileURLWithPath: "/Users/sample/Library/Containers/yyh.CLI-Pulse", isDirectory: true)
        XCTAssertFalse(HelperCachePurge.isInside(
            URL(fileURLWithPath: "/Users/sample/Library/Containers/yyh.CLI-Pulse.helper/Data"), app
        ))
        XCTAssertTrue(HelperCachePurge.isInside(URL(fileURLWithPath: "/Users/sample/Library/Containers/yyh.CLI-Pulse/Data"), app))
        XCTAssertTrue(HelperCachePurge.isInside(app, app))
        XCTAssertFalse(HelperCachePurge.isInside(
            URL(fileURLWithPath: "/Users/sample/Library/Containers/yyh.CLI-Pulse/Data/../../yyh.CLI-Pulse.helper"), app
        ))
        XCTAssertTrue(HelperCachePurge.isInside(
            URL(fileURLWithPath: "/Users/sample/Library/./Containers/yyh.CLI-Pulse/Data/Library/Caches"), app
        ))
    }

    /// Decided from the text alone: a folder that exists and a place below it
    /// that does not exist yet still match. (`standardizedFileURL` asks the
    /// disk and drops `/private` from the one that exists only, so the
    /// unsandboxed helper's cache folder, before its first start, would not
    /// be inside the home.)
    func testInsideDoesNotDependOnWhatExists() throws {
        let home = try scratchHome()
        XCTAssertTrue(home.path.hasPrefix("/private/"), "precondition: the scratch home is under /private")
        let notYet = home.appendingPathComponent("Library/Caches/yyh.CLI-Pulse.helper", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: notYet.path))
        XCTAssertTrue(HelperCachePurge.isInside(notYet, home))
        XCTAssertEqual(HelperCachePurge.reachablePlaces(Self.developerIDReach(home: home)).count, 1)
    }

    // MARK: - Emptying, and touching nothing else

    /// On a Developer ID Mac with both builds' helper files present: the
    /// unsandboxed helper's cache folder is emptied but for the lock file and
    /// its cookie file removed; the App Store helper's container is never
    /// touched, not even looked at; every file call stays on the two places.
    func testItEmptiesTheHelpersPlacesAndTouchesNothingElse() throws {
        let home = try scratchHome()
        let places = HelperCachePurge.helperPlaces(realHome: home)
        try Self.fillLikeA156Helper(places[0])
        try Self.fillLikeA156Helper(places[1])
        let containerBefore = try Self.snapshot(of: home.appendingPathComponent("Library/Containers"))
        let defaults = isolatedDefaults()
        let recorder = FileCallRecorder(base: .live)

        let outcome = HelperCachePurge.purgeIfNeeded(
            defaults: defaults, reach: Self.developerIDReach(home: home), helper: Self.idle, files: recorder.access
        )

        XCTAssertEqual(outcome, .emptied(removed: 5), "Cache.db, -shm, -wal, fsCachedData and the cookie file")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: places[0].cacheFolder.path),
                       [HelperCachePurge.lockFileName])
        XCTAssertFalse(FileManager.default.fileExists(atPath: places[0].cookieFile.path))
        XCTAssertEqual(try Self.snapshot(of: home.appendingPathComponent("Library/Containers")), containerBefore,
                       "the App Store helper's container changed")
        XCTAssertFalse(recorder.paths.isEmpty)
        for path in recorder.paths {
            let url = URL(fileURLWithPath: path)
            XCTAssertTrue(
                HelperCachePurge.isInside(url, places[0].cacheFolder) || url.path == places[0].cookieFile.path,
                "touched \(path)"
            )
            XCTAssertFalse(path.contains("/Library/Containers/"), "touched \(path)")
        }
        XCTAssertEqual(defaults.integer(forKey: HelperCachePurge.doneKey), HelperCachePurge.version)
    }

    /// A real URL cache in the helper's folder, holding a credentialed GET, a
    /// sign-in POST's body and a token in an answer: none of it is left in
    /// any file there afterwards.
    func testARealCachesCredentialsAreGone() async throws {
        let home = try scratchHome()
        let folder = HelperCachePurge.helperPlaces(realHome: home)[0].cacheFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let canaries = ["helper-header-canary-3f1a", "helper-body-canary-77c0", "helper-answer-canary-b2d9"]
        do {
            let cache = URLCache(memoryCapacity: 0, diskCapacity: 20_000_000, directory: folder)
            var get = URLRequest(url: URL(string: "https://helper-purge.invalid/usage")!)
            get.setValue("Bearer \(canaries[0])", forHTTPHeaderField: "Authorization")
            var post = URLRequest(url: URL(string: "https://helper-purge.invalid/token")!)
            post.httpMethod = "POST"
            post.httpBody = Data(#"{"refresh_token":"\#(canaries[1])"}"#.utf8)
            for request in [get, post] {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                               headerFields: ["Cache-Control": "max-age=3600"])!
                cache.storeCachedResponse(CachedURLResponse(
                    response: response, data: Data(#"{"access_token":"\#(canaries[2])"}"#.utf8),
                    userInfo: nil, storagePolicy: .allowed
                ), for: request)
            }
            for canary in canaries {
                let stored = await Self.eventually { Self.files(in: folder, contain: canary) }
                XCTAssertTrue(stored, "precondition: \(canary) never reached the cache's files")
            }
        }

        let outcome = HelperCachePurge.purgeIfNeeded(
            defaults: isolatedDefaults(), reach: Self.developerIDReach(home: home), helper: Self.idle, files: .live
        )

        guard case .emptied(let removed) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertGreaterThan(removed, 0)
        for canary in canaries {
            XCTAssertFalse(Self.files(in: folder, contain: canary), "\(canary) is still in the helper's cache folder")
        }
    }

    /// A helper that never ran left nothing: done, and no folder is made.
    func testAHelperThatNeverRanLeavesNothingToDo() throws {
        let home = try scratchHome()
        let defaults = isolatedDefaults()
        let outcome = HelperCachePurge.purgeIfNeeded(
            defaults: defaults, reach: Self.developerIDReach(home: home), helper: Self.idle, files: .live
        )
        XCTAssertEqual(outcome, .nothingThere)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: HelperCachePurge.helperPlaces(realHome: home)[0].cacheFolder.path
        ))
        XCTAssertEqual(defaults.integer(forKey: HelperCachePurge.doneKey), HelperCachePurge.version)
    }

    /// Once: a later launch leaves what is there now alone.
    func testItRunsOnce() throws {
        let home = try scratchHome()
        let places = HelperCachePurge.helperPlaces(realHome: home)[0]
        try Self.fillLikeA156Helper(places)
        let defaults = isolatedDefaults()
        let reach = Self.developerIDReach(home: home)
        XCTAssertEqual(HelperCachePurge.purgeIfNeeded(defaults: defaults, reach: reach, helper: Self.idle, files: .live),
                       .emptied(removed: 5))
        try Self.fillLikeA156Helper(places)
        let recorder = FileCallRecorder(base: .live)
        XCTAssertEqual(HelperCachePurge.purgeIfNeeded(defaults: defaults, reach: reach, helper: Self.idle, files: recorder.access),
                       .alreadyDone)
        XCTAssertEqual(recorder.paths, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: places.cacheFolder.appendingPathComponent("Cache.db").path))
    }

    /// A link where the cache folder belongs is not followed: whatever it
    /// points at stays, and nothing is recorded.
    func testALinkInPlaceOfTheFolderIsNotFollowed() throws {
        let home = try scratchHome()
        let places = HelperCachePurge.helperPlaces(realHome: home)[0]
        let elsewhere = home.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: elsewhere.appendingPathComponent("notes.txt"))
        try FileManager.default.createDirectory(at: places.cacheFolder.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: places.cacheFolder, withDestinationURL: elsewhere)
        let defaults = isolatedDefaults()

        XCTAssertEqual(HelperCachePurge.purgeIfNeeded(
            defaults: defaults, reach: Self.developerIDReach(home: home), helper: Self.idle, files: .live
        ), .failed)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), ["notes.txt"])
        XCTAssertEqual(defaults.integer(forKey: HelperCachePurge.doneKey), 0)
    }

    // MARK: - Never while the helper may be using them

    /// A running helper, or an enabled LoginItem (launchd may start it at any
    /// moment), is left alone, with no file call; nothing is recorded, so a
    /// later launch tries again.
    func testARunningHelperOrAnEnabledLoginItemIsLeftAlone() throws {
        let home = try scratchHome()
        let places = HelperCachePurge.helperPlaces(realHome: home)[0]
        try Self.fillLikeA156Helper(places)
        let before = try Self.snapshot(of: home)
        let defaults = isolatedDefaults()
        let reach = Self.developerIDReach(home: home)
        let activities = [
            "running": HelperCachePurge.HelperState(isRunning: { true }, isLoginItemEnabled: { false }, hasEmptiedItsOwn: { false }),
            "LoginItem on": HelperCachePurge.HelperState(isRunning: { false }, isLoginItemEnabled: { true }, hasEmptiedItsOwn: { false }),
        ]
        for (label, activity) in activities {
            let recorder = FileCallRecorder(base: .live)
            XCTAssertEqual(HelperCachePurge.purgeIfNeeded(
                defaults: defaults, reach: reach, helper: activity, files: recorder.access
            ), .helperActive, label)
            XCTAssertEqual(recorder.paths, [], label)
            XCTAssertEqual(try Self.snapshot(of: home), before, label)
            XCTAssertEqual(defaults.integer(forKey: HelperCachePurge.doneKey), 0, label)
        }
        XCTAssertEqual(HelperCachePurge.purgeIfNeeded(defaults: defaults, reach: reach, helper: Self.idle, files: .live),
                       .emptied(removed: 5), "once the helper is gone and its LoginItem off, the next launch empties it")
    }

    /// A helper that has run 1.57 or later emptied both itself, as its own
    /// done-flag in its own preferences file says: recorded as done, with no
    /// file call, whether it runs now or not; and the app stops asking.
    func testAHelperThatEmptiedItsOwnIsLeftAloneForGood() throws {
        let home = try scratchHome()
        let places = HelperCachePurge.helperPlaces(realHome: home)[0]
        try Self.fillLikeA156Helper(places)
        let reach = Self.developerIDReach(home: home)
        XCTAssertFalse(HelperCachePurge.hasEmptiedItsOwn(reach), "a helper that never ran: no preferences file")
        try Self.writeHelperPreferences(home: home, flag: nil)
        XCTAssertFalse(HelperCachePurge.hasEmptiedItsOwn(reach), "a helper that never ran 1.57")
        try Self.writeHelperPreferences(home: home, flag: CredentialedURLSession.purgeVersion)
        XCTAssertTrue(HelperCachePurge.hasEmptiedItsOwn(reach))
        let before = try Self.snapshot(of: home)

        let defaults = isolatedDefaults()
        for (isRunning, isLoginItemEnabled) in [(false, false), (true, true)] {
            defaults.removeObject(forKey: HelperCachePurge.doneKey)
            let helper = HelperCachePurge.HelperState(
                isRunning: { isRunning },
                isLoginItemEnabled: { isLoginItemEnabled },
                hasEmptiedItsOwn: { HelperCachePurge.hasEmptiedItsOwn(reach) }
            )
            let recorder = FileCallRecorder(base: .live)
            XCTAssertEqual(HelperCachePurge.purgeIfNeeded(defaults: defaults, reach: reach, helper: helper, files: recorder.access),
                           .helperEmptiedItsOwn)
            XCTAssertEqual(recorder.paths, [])
            XCTAssertEqual(try Self.snapshot(of: home), before)
            XCTAssertEqual(defaults.integer(forKey: HelperCachePurge.doneKey), HelperCachePurge.version)
            XCTAssertEqual(HelperCachePurge.purgeIfNeeded(defaults: defaults, reach: reach, helper: helper, files: recorder.access),
                           .alreadyDone)
        }
    }

    /// The flag is read from the unsandboxed helper's own preferences file,
    /// by path: not from the App Store helper's container (a Mac with both
    /// builds' helpers), whose flag says nothing about these folders; not
    /// from a file that is not a property list; and never by an app that
    /// cannot reach the file.
    func testTheHelpersFlagIsReadFromItsOwnPreferencesFileOnly() throws {
        XCTAssertEqual(HelperCachePurge.helperPreferencesFile(realHome: Self.sampleHome).path,
                       "/Users/sample/Library/Preferences/yyh.CLI-Pulse.helper.plist")

        let home = try scratchHome()
        let reach = Self.developerIDReach(home: home)
        let container = home.appendingPathComponent("Library/Containers/yyh.CLI-Pulse.helper/Data", isDirectory: true)
        try Self.writeHelperPreferences(home: container, flag: CredentialedURLSession.purgeVersion)
        XCTAssertFalse(HelperCachePurge.hasEmptiedItsOwn(reach), "the App Store helper's flag was read")

        let file = HelperCachePurge.helperPreferencesFile(realHome: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a property list".utf8).write(to: file)
        XCTAssertFalse(HelperCachePurge.hasEmptiedItsOwn(reach))
        try Self.writeHelperPreferences(home: home, flag: 0)
        XCTAssertFalse(HelperCachePurge.hasEmptiedItsOwn(reach))
        try Self.writeHelperPreferences(home: home, flag: CredentialedURLSession.purgeVersion)
        XCTAssertTrue(HelperCachePurge.hasEmptiedItsOwn(reach))
        XCTAssertFalse(HelperCachePurge.hasEmptiedItsOwn(Self.appStoreReach(home: home)),
                       "the App Store app read a file outside its container")
    }

    /// A helper that starts after the first check is seen by the second,
    /// made holding the lock: nothing is removed.
    func testAHelperThatStartsDuringTheChecksIsLeftAlone() throws {
        let home = try scratchHome()
        let places = HelperCachePurge.helperPlaces(realHome: home)[0]
        try Self.fillLikeA156Helper(places)
        let defaults = isolatedDefaults()
        var looks = 0
        let startsLate = HelperCachePurge.HelperState(
            isRunning: { looks += 1; return looks > 1 },
            isLoginItemEnabled: { false },
            hasEmptiedItsOwn: { false }
        )
        let recorder = FileCallRecorder(base: .live)

        XCTAssertEqual(HelperCachePurge.purgeIfNeeded(
            defaults: defaults, reach: Self.developerIDReach(home: home), helper: startsLate, files: recorder.access
        ), .helperActive)
        XCTAssertEqual(looks, 2)
        XCTAssertEqual(recorder.removed, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: places.cacheFolder.appendingPathComponent("Cache.db").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: places.cookieFile.path))
        XCTAssertEqual(defaults.integer(forKey: HelperCachePurge.doneKey), 0)
    }

    /// While a helper holds the lock, the app removes nothing, whatever
    /// LaunchServices and the LoginItem status say (both say "idle" here:
    /// a running helper they miss); once it is free, the app empties the
    /// folder.
    func testTheAppLeavesItAloneWhileTheHelperHoldsTheLock() throws {
        let home = try scratchHome()
        let places = HelperCachePurge.helperPlaces(realHome: home)[0]
        try Self.fillLikeA156Helper(places)
        let defaults = isolatedDefaults()
        let reach = Self.developerIDReach(home: home)
        var helper = try XCTUnwrap(HelperCachePurge.waitForTheAppThenHoldTheLock(cacheFolder: places.cacheFolder, limit: 1))

        for _ in 0..<2 {
            XCTAssertEqual(HelperCachePurge.purgeIfNeeded(defaults: defaults, reach: reach, helper: Self.idle, files: .live),
                           .busy)
            XCTAssertTrue(FileManager.default.fileExists(atPath: places.cacheFolder.appendingPathComponent("Cache.db").path))
            XCTAssertEqual(defaults.integer(forKey: HelperCachePurge.doneKey), 0)
        }

        helper.release()
        helper = try XCTUnwrap(HelperCachePurge.waitForTheAppThenHoldTheLock(cacheFolder: places.cacheFolder, limit: 1))
        XCTAssertEqual(HelperCachePurge.purgeIfNeeded(defaults: defaults, reach: reach, helper: Self.idle, files: .live),
                       .busy, "a helper that started again holds it again")
        helper.release()
        XCTAssertEqual(HelperCachePurge.purgeIfNeeded(defaults: defaults, reach: reach, helper: Self.idle, files: .live),
                       .emptied(removed: 5))
    }

    /// The helper's side: at its start it waits while the app holds the lock,
    /// goes on as soon as it is free, and gives up waiting after the limit;
    /// once it goes on, it holds the lock until it lets go of it, and the app
    /// cannot take it meanwhile.
    func testTheHelperWaitsWhileTheAppEmptiesItThenHoldsTheLock() throws {
        let folder = try scratchHome().appendingPathComponent("Library/Caches/yyh.CLI-Pulse.helper", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lockFile = folder.appendingPathComponent(HelperCachePurge.lockFileName)

        var started = Date()
        var helper = HelperCachePurge.waitForTheAppThenHoldTheLock(cacheFolder: folder, limit: 2)
        XCTAssertNotNil(helper)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "nobody held the lock, yet it waited")
        let appWhileItRuns = HelperCachePurge.HeldLock.take(lockFile)
        XCTAssertNil(appWhileItRuns, "the app took the lock a running helper holds")
        appWhileItRuns?.release()
        let secondHelper = HelperCachePurge.waitForTheAppThenHoldTheLock(cacheFolder: folder, limit: 0)
        XCTAssertNotNil(secondHelper, "a second helper could not share it")
        secondHelper?.release()
        helper = nil  // the helper quits: its lock goes with it
        let appAfterwards = HelperCachePurge.HeldLock.take(lockFile)
        XCTAssertNotNil(appAfterwards, "a helper that is gone still holds the lock")
        appAfterwards?.release()

        let app = try XCTUnwrap(HelperCachePurge.HeldLock.take(lockFile))
        started = Date()
        let timedOut = HelperCachePurge.waitForTheAppThenHoldTheLock(cacheFolder: folder, limit: 0.3)
        XCTAssertNil(timedOut)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.3, "it did not wait for the app")

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { app.release() }
        started = Date()
        helper = HelperCachePurge.waitForTheAppThenHoldTheLock(cacheFolder: folder, limit: 5)
        let waited = Date().timeIntervalSince(started)
        XCTAssertNotNil(helper)
        XCTAssertGreaterThanOrEqual(waited, 0.2, "it went on while the app still held the lock")
        XCTAssertLessThan(waited, 4, "it waited out the limit instead of going on when the lock was freed")
        let appAfterTheWait = HelperCachePurge.HeldLock.take(lockFile)
        XCTAssertNil(appAfterTheWait, "the helper let go of the lock once it had waited")
        appAfterTheWait?.release()
        helper?.release()

        XCTAssertGreaterThanOrEqual(HelperCachePurge.helperWaitLimit, 1)
        XCTAssertLessThanOrEqual(HelperCachePurge.helperWaitLimit, 10, "a stuck app must not hold a starting helper for long")
    }

    /// The app's launch call runs the purge on the queue it is given, not on
    /// the calling (main) thread, and reports the outcome from there.
    func testTheAppPurgesOffTheMainThread() throws {
        XCTAssertTrue(Thread.isMainThread, "precondition: tests run on the main thread")
        let home = try scratchHome()
        try Self.fillLikeA156Helper(HelperCachePurge.helperPlaces(realHome: home)[0])
        let threads = MainThreadRecorder()
        let helper = HelperCachePurge.HelperState(
            isRunning: { threads.note(); return false },
            isLoginItemEnabled: { threads.note(); return false },
            hasEmptiedItsOwn: { threads.note(); return false }
        )
        let base = HelperCachePurge.FileAccess.live
        var files = base
        files.contents = { url in threads.note(); return try base.contents(url) }
        files.remove = { url in threads.note(); try base.remove(url) }
        let reported = expectation(description: "outcome reported")
        var outcome: HelperCachePurge.Outcome?
        var reportedOnMain = true

        HelperCachePurge.purgeInBackground(
            on: DispatchQueue(label: "HelperCachePurgeTests.utility", qos: .utility),
            defaults: isolatedDefaults(), reach: Self.developerIDReach(home: home), helper: helper, files: files
        ) { result in
            outcome = result
            reportedOnMain = Thread.isMainThread
            reported.fulfill()
        }
        threads.note()  // this thread, after the call returned: the only main-thread note
        wait(for: [reported], timeout: 10)

        XCTAssertEqual(outcome, .emptied(removed: 5))
        XCTAssertFalse(reportedOnMain)
        XCTAssertEqual(threads.onMain, 1, "the purge ran on the calling thread")
        XCTAssertGreaterThan(threads.offMain, 5)
    }

    // MARK: - The flag and the call sites

    /// The done-flag stays out of the app-owned namespace, like the 1.57
    /// purge's, and a new install with nothing but the flag is still new.
    func testTheDoneFlagIsNotAnAppOwnedKey() {
        let key = HelperCachePurge.doneKey
        XCTAssertNotEqual(key, CredentialedURLSession.purgeDoneKey)
        XCTAssertFalse(UnsandboxedDataMigration.appOwnedKeyPrefixes.contains { key.hasPrefix($0) })
        XCTAssertTrue(FirstRunPresentation.shouldPresent(existingKeys: [key], alreadyShown: false, hasSentinel: false))
    }

    /// The app starts emptying the helper's places at launch, production
    /// only, off the main thread, before `AppState` (which can turn the
    /// LoginItem on); the helper waits for it before its own purge and before
    /// its daemon exists, and keeps the lock in a property, for as long as it
    /// runs, rather than letting it go at once.
    func testTheAppPurgesBeforeAppStateAndTheHelperWaitsFirst() throws {
        let app = try Self.shippingCode(at: "CLI Pulse Bar/CLIPulseBarApp.swift")
        let gate = try XCTUnwrap(app.range(of: "if runtimeEnvironment.capabilities.allowsHelperRegistration {\n"
                                           + "            HelperCachePurge.purgeInBackground {"),
                                 "the app no longer empties the helper's places off the main thread, or not only in production")
        XCTAssertNil(app.range(of: "HelperCachePurge.purgeIfNeeded("), "the app empties the helper's places on the main thread")
        let appState = try XCTUnwrap(app.range(of: "let state = AppState(runtimeEnvironment: runtimeEnvironment)"))
        XCTAssertTrue(gate.lowerBound < appState.lowerBound, "the app empties the helper's places after AppState")

        let helper = try Self.shippingCode(at: "CLIPulseHelper/HelperAppDelegate.swift")
        XCTAssertNotNil(helper.range(of: "private var cacheLock: HelperCachePurge.HeldLock?"))
        let wait = try XCTUnwrap(helper.range(of: "        cacheLock = HelperCachePurge.waitForTheAppThenHoldTheLock()"),
                                 "the helper no longer waits for the app, or lets go of the lock at once")
        let ownPurge = try XCTUnwrap(helper.range(of: "CredentialedURLSession.purgeLegacyStorageIfNeeded()"))
        let daemon = try XCTUnwrap(helper.range(of: "let daemon = HelperDaemon("))
        XCTAssertTrue(wait.lowerBound < ownPurge.lowerBound, "the helper opens its URL cache before waiting")
        XCTAssertTrue(wait.lowerBound < daemon.lowerBound)
        XCTAssertNil(helper.range(of: "cacheLock = nil"), "the helper lets go of the lock while it runs")
    }

    // MARK: - This Mac

    /// The acceptance on a real Developer ID Mac whose helper does not start
    /// (background sync off). The purge as the app runs it at launch: this
    /// Mac's real places, the helper's real state, the real lock and listing.
    /// Two differences: its own done-flag instead of the app's, and what it
    /// removes goes to the Trash instead of being deleted, so a mistake can
    /// be undone (empty the Trash afterwards: those files hold the old
    /// requests). Off unless asked; it prints the outcome only, counts and no
    /// name or path:
    ///
    ///     CLIPULSE_HELPER_PURGE_LIVE=1 swift test --filter HelperCachePurgeTests/testThisMacsHelperPlaces
    ///
    /// Then `CredentialedRequestsLocalCheckTests/testTheAppsRealCachesHoldNoCredential`
    /// on the helper's cache folder finds no credentialed entry. Run from
    /// `swift test`, `SMAppService` looks for the LoginItem in the test
    /// runner's bundle, finds none and says it is not enabled: whether the
    /// real LoginItem is on is not measured here, so run it only with
    /// background sync off.
    func testThisMacsHelperPlaces() throws {
        guard ProcessInfo.processInfo.environment["CLIPULSE_HELPER_PURGE_LIVE"] == "1" else {
            throw XCTSkip("set CLIPULSE_HELPER_PURGE_LIVE=1 to empty this Mac's helper cache (to the Trash)")
        }
        let reach = HelperCachePurge.Reach.current()
        let helper = HelperCachePurge.HelperState.live(reach: reach)
        if helper.isRunning() { throw XCTSkip("the helper is running: it empties its own") }
        var trashed = 0
        var files = HelperCachePurge.FileAccess.live
        files.remove = { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            trashed += 1
        }

        let outcome = HelperCachePurge.purgeIfNeeded(defaults: isolatedDefaults(), reach: reach, helper: helper, files: files)

        Swift.print("HELPER_PURGE_LIVE sandboxed=\(reach.isSandboxed) reachable=\(HelperCachePurge.reachablePlaces(reach).count) "
                    + "outcome=\(outcome) trashed=\(trashed)")
        switch outcome {
        case .emptied, .nothingThere, .helperEmptiedItsOwn, .unreachable: break
        default: XCTFail("\(outcome)")
        }
        XCTAssertEqual(outcome == .unreachable, reach.isSandboxed)
    }

    // MARK: - Helpers

    private static let idle = HelperCachePurge.HelperState(isRunning: { false }, isLoginItemEnabled: { false }, hasEmptiedItsOwn: { false })

    private static func developerIDReach(home: URL) -> HelperCachePurge.Reach {
        HelperCachePurge.Reach(realHome: home, isSandboxed: false, ownHome: home, groupContainer: nil)
    }

    private static func appStoreReach(home: URL) -> HelperCachePurge.Reach {
        HelperCachePurge.Reach(
            realHome: home,
            isSandboxed: true,
            ownHome: home.appendingPathComponent("Library/Containers/yyh.CLI-Pulse/Data", isDirectory: true),
            groupContainer: home.appendingPathComponent("Library/Group Containers/group.yyh.CLI-Pulse", isDirectory: true)
        )
    }

    /// What a 1.56 helper leaves: the URL cache's four entries and a cookie file.
    private static func fillLikeA156Helper(_ places: HelperCachePurge.Places) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: places.cacheFolder.appendingPathComponent("fsCachedData", isDirectory: true),
                                        withIntermediateDirectories: true)
        for name in ["Cache.db", "Cache.db-shm", "Cache.db-wal", "fsCachedData/0A1B2C3D"] {
            try Data("Authorization: Bearer fixture-token".utf8).write(to: places.cacheFolder.appendingPathComponent(name))
        }
        try fileManager.createDirectory(at: places.cookieFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("cook".utf8).write(to: places.cookieFile)
    }

    /// The helper's preferences file under `home`, as `cfprefsd` writes it
    /// (binary), with its 1.57 done-flag set to `flag` or absent.
    private static func writeHelperPreferences(home: URL, flag: Int?) throws {
        let file = HelperCachePurge.helperPreferencesFile(realHome: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var preferences: [String: Any] = ["SUHasLaunchedBefore": true]
        if let flag { preferences[CredentialedURLSession.purgeDoneKey] = flag }
        try PropertyListSerialization.data(fromPropertyList: preferences, format: .binary, options: 0).write(to: file)
    }

    /// Every file under `folder` with its bytes, to show nothing changed.
    private static func snapshot(of folder: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return files }
        for case let url as URL in enumerator {
            let relative = String(url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count))
            files[relative] = (try? Data(contentsOf: url)) ?? Data("<folder>".utf8)
        }
        return files
    }

    private static func files(in directory: URL, contain canary: String) -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return false
        }
        let needle = Data(canary.utf8)
        for case let url as URL in enumerator {
            if let data = try? Data(contentsOf: url), data.range(of: needle) != nil { return true }
        }
        return false
    }

    private static func eventually(_ condition: @escaping () -> Bool) async -> Bool {
        for _ in 0..<50 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }

    private func scratchHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-pulse-helper-purge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        // `realpath`, not `resolvingSymlinksInPath()`: that one drops the
        // `/private` of `/private/var`, which a directory listing keeps, and
        // the paths compared below would then differ for no real reason.
        let resolved = try XCTUnwrap(realpath(home.path, nil))
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "HelperCachePurgeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private static var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // CLIPulseCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // CLIPulseCore
            .deletingLastPathComponent()  // CLI Pulse Bar
    }

    /// A source with its `//` comments taken out (outside string literals).
    private static func shippingCode(at relativePath: String) throws -> String {
        let text = try String(contentsOf: projectRoot.appendingPathComponent(relativePath), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                var quotes = 0
                var previous: Character = " "
                for index in line.indices {
                    let character = line[index]
                    if character == "\"" { quotes += 1 }
                    if character == "/", previous == "/", quotes % 2 == 0 {
                        return line[line.startIndex..<line.index(before: index)]
                    }
                    previous = character
                }
                return line
            }
            .joined(separator: "\n")
    }
}

/// Counts the calls made on the main thread and off it.
private final class MainThreadRecorder {
    private let lock = NSLock()
    private(set) var onMain = 0
    private(set) var offMain = 0

    func note() {
        let isMain = Thread.isMainThread
        lock.lock()
        defer { lock.unlock() }
        if isMain { onMain += 1 } else { offMain += 1 }
    }
}

/// Wraps a `FileAccess` and writes down every path it is handed.
private final class FileCallRecorder {
    private(set) var paths: [String] = []
    private(set) var removed: [String] = []
    private let base: HelperCachePurge.FileAccess

    init(base: HelperCachePurge.FileAccess) {
        self.base = base
    }

    var access: HelperCachePurge.FileAccess {
        HelperCachePurge.FileAccess(
            itemType: { [self] url in paths.append(url.path); return base.itemType(url) },
            contents: { [self] url in paths.append(url.path); return try base.contents(url) },
            createDirectory: { [self] url in paths.append(url.path); try base.createDirectory(url) },
            remove: { [self] url in paths.append(url.path); removed.append(url.path); try base.remove(url) },
            lock: { [self] url in paths.append(url.path); return base.lock(url) }
        )
    }
}
#endif
