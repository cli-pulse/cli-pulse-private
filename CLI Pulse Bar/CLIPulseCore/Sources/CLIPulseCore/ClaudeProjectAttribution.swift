#if os(macOS)
import Foundation

/// Which project a Claude Code transcript belongs to, and what to call it.
///
/// Claude Code files every transcript under `<projects root>/<directory>/`,
/// where `<directory>` is the session's working directory with every
/// character other than an ASCII letter or digit replaced by `-`. The
/// transcript is not always directly inside it, though. Subagents write to
/// `<directory>/<session id>/subagents/…`, and workflow runs one level deeper
/// again, `…/subagents/workflows/<run id>/…`. Naming the project after the
/// transcript's parent folder therefore called most of a heavy user's work
/// "subagents", or a workflow run id.
///
/// So the project is the first directory under the projects root, and nothing
/// deeper. Its label comes from the real path that directory was made from,
/// when a transcript recorded one, because the directory name alone cannot be
/// turned back into a path: `-` is both the separator and an ordinary
/// character (`cli-pulse`), and so is every space and dot.
public struct ClaudeProjectAttribution: Equatable, Sendable {
    /// The directory directly under the projects root: the grouping key. Two
    /// transcripts belong to the same project exactly when this is equal.
    public let directory: String
    /// The absolute path `directory` was made from, when a transcript's `cwd`
    /// led back to it. nil when none did.
    public let root: String?
    /// What to show: the last component of `root`, else the directory name
    /// decoded as well as it can be.
    public let label: String
}

extension CostUsageScanner {

    /// How far into a transcript to look for `cwd`. Claude Code writes it on
    /// every conversation line, so the first few lines settle it; the cap is
    /// what keeps a transcript that opens with a very long line from being
    /// read whole.
    static let claudeCwdReadLimit = 32 * 1024

    /// Attribute one transcript to its project.
    ///
    /// The label is found in this order:
    /// 1. the transcript's own `cwd`, or the ancestor of it that the project
    ///    directory was made from. A subagent can be started after the session
    ///    moved into a subfolder, so its `cwd` is often below the project, not
    ///    at it; naming the project after that subfolder would be wrong.
    /// 2. for a transcript below `<directory>/<session id>/`, the `cwd` of the
    ///    session's own transcript, `<directory>/<session id>.jsonl`. A
    ///    subagent that ran somewhere else entirely (another worktree) is still
    ///    filed under the session that started it.
    /// 3. the directory name, decoded (`humanReadableClaudeProject`).
    ///
    /// Returns nil when `transcript` is not at least one directory below
    /// `projectsRoot`; callers keep their previous behaviour for that case.
    public static func claudeProjectAttribution(
        transcript: URL,
        projectsRoot: URL
    ) -> ClaudeProjectAttribution? {
        guard let relative = claudeTranscriptPath(transcript, under: projectsRoot) else { return nil }
        let directory = relative[0]

        var sources: [URL] = [transcript]
        if relative.count >= 3 {
            let session = projectsRoot
                .appendingPathComponent(directory, isDirectory: true)
                .appendingPathComponent(relative[1] + ".jsonl", isDirectory: false)
            sources.append(session)
        }
        for source in sources {
            guard let cwd = readClaudeTranscriptCwd(fileURL: source),
                  let root = claudeProjectRoot(cwd: cwd, directory: directory),
                  let label = projectLabelFromCodexMeta(root)
            else { continue }
            return ClaudeProjectAttribution(directory: directory, root: root, label: label)
        }
        return ClaudeProjectAttribution(
            directory: directory,
            root: nil,
            label: humanReadableClaudeProject(encodedDir: directory)
        )
    }

    /// The transcript's path components below `projectsRoot`, when it is at
    /// least one directory below it. The first component is the project.
    static func claudeTranscriptPath(_ transcript: URL, under projectsRoot: URL) -> [String]? {
        // Standardised on both sides, so `/var/…` and `/private/var/…`
        // spellings of the same folder still line up.
        let rootComponents = projectsRoot.standardizedFileURL.pathComponents
        let fileComponents = transcript.standardizedFileURL.pathComponents
        guard fileComponents.count >= rootComponents.count + 2,
              Array(fileComponents.prefix(rootComponents.count)) == rootComponents
        else { return nil }
        return Array(fileComponents.dropFirst(rootComponents.count))
    }

    /// `cwd`, or the nearest ancestor of it, whose Claude Code project
    /// directory name is `directory`. nil when none is.
    static func claudeProjectRoot(cwd: String, directory: String) -> String? {
        guard cwd.hasPrefix("/") else { return nil }
        // Compared as written. Claude Code encoded the path it recorded, so
        // resolving it first (`/private/tmp` → `/tmp`) would stop it matching.
        var path = cwd
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        while true {
            if claudeProjectDirectoryName(forPath: path) == directory { return path }
            let parent = (path as NSString).deletingLastPathComponent
            if parent == path || parent.isEmpty { return nil }
            path = parent
        }
    }

    /// The directory name Claude Code files a session under, for a working
    /// directory. Mirrors Claude Code 2.1.x: every UTF-16 unit that is not an
    /// ASCII letter or digit becomes `-`; a result longer than 200 units is
    /// cut to 200 and suffixed with `-` and a base-36 hash of the original
    /// path (a 32-bit Java-style string hash, as a JavaScript engine computes
    /// it).
    static func claudeProjectDirectoryName(forPath path: String) -> String {
        let units = Array(path.utf16)
        var encoded = String.UnicodeScalarView()
        for unit in units {
            let isAlnum = (unit >= 0x30 && unit <= 0x39)
                || (unit >= 0x41 && unit <= 0x5A)
                || (unit >= 0x61 && unit <= 0x7A)
            encoded.append(isAlnum ? Unicode.Scalar(UInt8(unit)) : "-")
        }
        let name = String(encoded)
        let limit = 200
        guard name.count > limit else { return name }
        var hash: Int32 = 0
        for unit in units {
            hash = (hash &<< 5) &- hash &+ Int32(unit)
        }
        let magnitude = abs(Int64(hash))
        return String(name.prefix(limit)) + "-" + String(magnitude, radix: 36)
    }

    /// The first top-level `cwd` in a transcript, reading at most
    /// `claudeCwdReadLimit` bytes and only lines that ended inside them. nil
    /// when the file cannot be read or no such line has one.
    static func readClaudeTranscriptCwd(fileURL: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: claudeCwdReadLimit),
              !data.isEmpty else { return nil }
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        // A line cut off by the byte cap is not JSON; drop it rather than
        // guess at it.
        if data.count == claudeCwdReadLimit, data.last != 0x0A, !lines.isEmpty {
            lines.removeLast()
        }
        let key = Data(#""cwd""#.utf8)
        for line in lines.prefix(64) {
            guard line.range(of: key) != nil,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let cwd = object["cwd"] as? String,
                  !cwd.isEmpty
            else { continue }
            return cwd
        }
        return nil
    }
}
#endif
