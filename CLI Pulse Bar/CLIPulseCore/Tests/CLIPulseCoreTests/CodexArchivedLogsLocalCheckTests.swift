#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// 1.59.1 (N1) acceptance on a real Mac: the scanner's 30-day Codex total
/// against a reference read of the same `~/.codex` folder, with every
/// archived session (`*.jsonl.zst`) decoded by the zstd CLI, in memory.
///
/// Why not CodexBar: it reads `.jsonl` only too (its fix is unmerged), so the
/// two would agree while both left out the archives. The reference here does
/// not use the app's decoder or its file listing:
///
/// * files: every `*.jsonl` and `*.jsonl.zst` under `sessions/` and
///   `archived_sessions/`, at any depth, last written on or after the first
///   day the scan reads (a log not written since cannot hold a line in the
///   window); a session in both forms is read once, from the `.jsonl`;
/// * content: the `.jsonl` as it is, a `.jsonl.zst` as `zstd -dc` prints it
///   (into memory, never to a file);
/// * counting: the app's per-file rules and `CodexCopyResolver`, which this
///   check is not about.
///
/// It also decodes each archive with the app's decoder and compares the
/// bytes, and reports what 1.59.0 saw: the same reference over the `.jsonl`
/// files alone.
///
/// Off unless asked for, because it reads this Mac's own logs:
///
///     CLIPULSE_LOCAL_CODEX_ARCHIVES_CHECK=$(command -v zstd) \
///       swift test --filter CodexArchivedLogsLocalCheckTests
///
/// The scan's cache goes to a throwaway directory, never the app's. Output is
/// counts, yes/no and ratios only: no path, name or figure leaves the test.
final class CodexArchivedLogsLocalCheckTests: XCTestCase {
    func testScannerCountsArchivedSessionsLikeTheirDecodedContent() throws {
        guard let zstd = ProcessInfo.processInfo.environment["CLIPULSE_LOCAL_CODEX_ARCHIVES_CHECK"], !zstd.isEmpty else {
            throw XCTSkip("set CLIPULSE_LOCAL_CODEX_ARCHIVES_CHECK=<path to the zstd CLI> to read this Mac's Codex logs")
        }
        let env = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        let codexHome = URL(fileURLWithPath: env ?? (realUserHome() as NSString).appendingPathComponent(".codex"), isDirectory: true)
        let now = Date()
        let days = 30

        // The app.
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-pulse-codex-archives-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        var options = CostUsageScanner.Options(
            codexSessionsRoot: codexHome.appendingPathComponent("sessions", isDirectory: true),
            claudeProjectsRoots: [], cacheRoot: cacheDir, daysToScan: days)
        options.forceRescan = true
        options.refreshMinIntervalSeconds = 0
        options.providers = [.codex]
        options.splitsByProject = false
        options.now = now
        let app = CostUsageScanner.scan(options: options).entries.filter { $0.provider == "Codex" }
            .reduce(0) { $0 + $1.inputTokens + $1.outputTokens }

        // The reference.
        let since = DayKey.calendar().date(byAdding: .day, value: -days, to: now) ?? now
        let range = CostUsageScanner.DayRange(since: since, until: now)
        // The start of the first day the scan reads (a day before the first it reports).
        let firstReadDay = DayKey.calendar().date(byAdding: .day, value: -1, to: range.firstReportedInstant)
            ?? range.firstReportedInstant

        var logs: [String: URL] = [:] // the session's `.jsonl` path → the file read for it
        for root in ["sessions", "archived_sessions"] {
            let rootURL = codexHome.appendingPathComponent(root, isDirectory: true)
            guard let walk = FileManager.default.enumerator(
                at: rootURL, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walk {
                let name = url.lastPathComponent.lowercased()
                let archived = name.hasSuffix(".jsonl.zst")
                guard archived || name.hasSuffix(".jsonl") else { continue }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values?.isRegularFile == true, let modified = values?.contentModificationDate,
                      modified >= firstReadDay else { continue }
                let session = archived ? url.deletingPathExtension().path : url.path
                if archived, logs[session] != nil { continue }
                logs[session] = url
            }
        }

        var plainRead = 0, archivesRead = 0, decoderAgrees = 0, decoderDiffers = 0, unreadable = 0
        var all = CostUsageCache()
        var plainOnly = CostUsageCache()
        for (session, url) in logs.sorted(by: { $0.key < $1.key }) {
            let archived = LogByteReader.isCompressed(url)
            let content: Data
            if archived {
                guard let decoded = Self.zstdDecode(url, zstd: zstd) else { unreadable += 1; continue }
                content = decoded
                archivesRead += 1
                if (try? Self.appDecode(url)) == decoded { decoderAgrees += 1 } else { decoderDiffers += 1 }
            } else {
                guard let data = try? Data(contentsOf: url) else { unreadable += 1; continue }
                content = data
                plainRead += 1
            }
            guard let entry = CostUsageScanner.codexFileEntry(
                fileURL: url, range: range, mtimeUnixMs: 0, size: Int64(content.count),
                open: { _ in LogByteReader(data: content) }) else { continue }
            all.files[session] = entry
            if !archived { plainOnly.files[session] = entry }
        }
        func tokens(_ cache: inout CostUsageCache) -> Int {
            _ = CostUsageScanner.rebuildCodexDays(cache: &cache)
            return cache.days.filter { DayRange.isInRange(dayKey: $0.key, since: range.sinceKey, until: range.untilKey) }
                .values.flatMap(\.values)
                .reduce(0) { $0 + max(0, $1[safeIdx: 0] ?? 0) + max(0, $1[safeIdx: 2] ?? 0) }
        }
        let reference = tokens(&all)
        let before = tokens(&plainOnly)

        func percent(_ part: Int) -> String {
            reference > 0 ? String(format: "%.1f%%", Double(part) * 100 / Double(reference)) : "n/a"
        }
        print("LOCAL_CODEX_ARCHIVES_CHECK files read: \(plainRead) .jsonl, \(archivesRead) .jsonl.zst, \(unreadable) unreadable")
        print("LOCAL_CODEX_ARCHIVES_CHECK app decoder equals zstd CLI: \(decoderAgrees) of \(archivesRead) archives (\(decoderDiffers) differ)")
        print("LOCAL_CODEX_ARCHIVES_CHECK 30-day Codex tokens, app equals reference: \(app == reference ? "yes" : "no")")
        print("LOCAL_CODEX_ARCHIVES_CHECK share of the reference: before (.jsonl only) \(percent(before)), after (this build) \(percent(app))")
        XCTAssertGreaterThan(reference, 0, "no Codex usage in the window")
        XCTAssertEqual(decoderDiffers, 0, "the app's decoder and the zstd CLI disagree")
        XCTAssertEqual(app, reference, "the scanner's 30-day Codex total differs from the reference (figures not printed)")
    }

    private typealias DayRange = CostUsageScanner.DayRange

    /// `zstd -dc` into memory; nil when it fails.
    private static func zstdDecode(_ url: URL, zstd: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zstd)
        process.arguments = ["-dcq", "--", url.path]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    private static func appDecode(_ url: URL) throws -> Data {
        let reader = try LogByteReader(fileURL: url)
        defer { reader.close() }
        var out = Data()
        while true {
            let chunk = try reader.read(upToCount: 256 * 1024)
            if chunk.isEmpty { return out }
            out.append(chunk)
        }
    }
}
#endif
