import Foundation

/// The `ps` process-table parsers for `get_machine_snapshot`, ported from
/// `helper/machine_collector.py` (`_normalize_state` :130, `parse_top_processes`
/// :150, `build_process_list` :192).
///
/// Pure functions by design: the oracle layer runs `ps` and hands the raw
/// stdout in. Nothing here spawns a process or touches the filesystem, so the
/// whole table is testable against the same fixture strings the Python suite
/// uses — which is the only way the two implementations can be shown to agree.
///
/// Where Python has a quirk, this file reproduces the quirk. The client parses
/// the resulting dict with `?? 0` on every field and shows its error UI only
/// when the CALL threw, so a shape difference here does not surface as an
/// error — it surfaces as a process table that quietly disagrees with the
/// Python helper on the same machine.
public enum MachineProcessTable {

    // MARK: - STAT column

    /// Map a BSD `ps` STAT column to `running` | `stopped` | `other`.
    ///
    /// Only the FIRST char is the primary state code; the rest are modifiers
    /// (e.g. "Ss", "S+", "R<", "TN", "SNs", "Us") and the whole token never
    /// contains a space (confirmed on macOS), so it splits cleanly as one field.
    ///   * 'T' → stopped   (SIGSTOP'd or traced — the Suspend/Resume target)
    ///   * 'Z' → other     (zombie/defunct — not actionable; no Suspend/Resume)
    ///   * everything else (R/S/I/U/…) → running
    ///
    /// Empty → "running": the safe, actionable default, matching the
    /// `ProcessInfo.state` field default an old helper would leave unset.
    public static func normalizeState(_ raw: String) -> String {
        guard let first = raw.first else { return "running" }
        if first == "T" { return "stopped" }
        if first == "Z" { return "other" }
        return "running"
    }

    // MARK: - ps parsing

    /// Parse `ps -Aceo pid,uid,pcpu,rss,state,comm` output (order preserved).
    ///
    /// Six columns (v1.38.1 added `state` before `comm`): the BSD STAT column
    /// is a single space-free token, so splitting at most 5 times isolates it
    /// and keeps the trailing free-form `comm` intact — that field routinely
    /// contains spaces ("Google Chrome Helper (Renderer)") and a naive
    /// split-on-all-whitespace would truncate it to "Google". A header row and
    /// any malformed row are skipped. Returns at most `limit` rows (all rows
    /// when `limit` is nil). The `uid` column gates the "End Process" /
    /// Suspend affordances to same-UID rows; `state` chooses Suspend vs Resume.
    public static func parseTopProcesses(_ psStdout: String, limit: Int? = 12) -> [MachineProcess] {
        var rows: [MachineProcess] = []
        for line in psStdout.split(whereSeparator: \.isNewline) {
            let stripped = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if stripped.isEmpty { continue }
            let parts = splitOnWhitespace(stripped, maxSplits: 5)
            if parts.count < 6 { continue }
            let pidS = parts[0], uidS = parts[1], cpuS = parts[2], rssS = parts[3]
            let stateS = parts[4], comm = parts[5]

            // Header row ("PID UID %CPU RSS STAT COMM") or junk. Python tests
            // `pid_s.isdigit()`, which is also how a "-1" or "+7" pid is
            // rejected — hence a digits-only check rather than `Int(pidS) != nil`.
            guard !pidS.isEmpty, pidS.allSatisfy({ $0.isASCII && $0.isNumber }) else { continue }

            // Python's `except (ValueError, TypeError): continue` — a row whose
            // numbers do not parse is dropped whole, never half-built. `Int(pidS)`
            // can additionally fail on overflow where Python's bignum would not;
            // a >2^63 pid does not exist, and dropping the row is the safe arm.
            guard let pid = Int(pidS), let cpu = Double(cpuS), let rssKiB = Int(rssS) else { continue }

            // Non-numeric uid → -1, which no same-UID gate ever matches, so an
            // unreadable owner disables the End/Suspend controls rather than
            // mis-granting them. Python gates on `isdigit()`, so a signed "-1"
            // in the column also lands here.
            let uid: Int
            if !uidS.isEmpty, uidS.allSatisfy({ $0.isASCII && $0.isNumber }), let parsed = Int(uidS) {
                uid = parsed
            } else {
                uid = -1
            }

            rows.append(MachineProcess(
                pid: pid,
                name: comm.trimmingCharacters(in: .whitespacesAndNewlines),
                // Per-core, so it can exceed 100 on a busy multi-thread process.
                // Python does not clamp it and neither do we: a 400% row is the
                // signal the user opened the Machine tab for.
                cpuPercent: roundedToOneDecimal(cpu),
                // `ps` reports rss in KiB; the wire field is MiB.
                rssMB: roundedToOneDecimal(Double(rssKiB) / 1024.0),
                uid: uid,
                state: normalizeState(String(stateS))
            ))

            // Python checks the limit AFTER appending. That means `limit == 0`
            // returns ONE row rather than none — a bug, faithfully reproduced,
            // because the caller always passes a positive limit or nil and a
            // divergence here would be a silent off-by-one against the Python
            // helper rather than a visible failure.
            if let limit, rows.count >= limit { break }
        }
        return rows
    }

    // MARK: - Union

    /// Default size of each ranked slice (top-N-by-CPU and top-N-by-mem)
    /// unioned into the Machine tab's process list. ~25 each so a memory sort
    /// is faithful (a real mem ranking, not just a re-sort of the top-CPU set)
    /// and the app's "Show more" reveals a meaningful set beyond its default
    /// top-10.
    public static let processUnionN = 25

    /// Merge the CPU-sorted (`ps … -r`) and memory-sorted (`ps … -m`) process
    /// lists into ONE deduped table for the Machine tab (v1.38.1 B2), and
    /// force-include every same-UID *stopped* process (B1 vanishing-process fix).
    ///
    /// Why a union: a client-side "sort by memory" is only faithful if the
    /// helper actually returned the memory-heavy processes — top-CPU alone
    /// would miss a quiet-but-huge process. So we take top-`topN`-by-CPU ∪
    /// top-`topN`-by-mem, deduped by pid.
    ///
    /// Why force-include stopped same-UID procs: a suspended process
    /// immediately drops to ~0% CPU and (unless it's memory-heavy) falls out of
    /// BOTH ranked slices on the next 2 s refresh — the row would vanish and
    /// the user could no longer Resume it. We scan the SAME full `-r` output
    /// (no extra `ps`) for same-UID rows in state `stopped` and pin them in. A
    /// paused process therefore never drops off the list while stopped.
    ///
    /// The result is therefore NOT capped at `topN`: a live run routinely
    /// returns 40+ rows for `topN == 25`. Capping it would re-introduce exactly
    /// the vanishing-process bug the force-union exists to fix.
    ///
    /// Sorted CPU-desc so an OLD app (pre-B2, no client-side sort) still
    /// renders a sensible top-N-by-CPU from `.prefix(10)`.
    public static func buildProcessList(
        cpuSorted: String,
        memorySorted: String,
        currentUID: Int,
        topN: Int = processUnionN
    ) -> [MachineProcess] {
        // Full `-r` scan (CPU desc) — the stopped-process sweep below needs
        // every row, not just the top slice.
        let cpuRows = parseTopProcesses(cpuSorted, limit: nil)
        let memRows = parseTopProcesses(memorySorted, limit: topN)

        var seen = Set<Int>()
        var union: [MachineProcess] = []
        func add(_ p: MachineProcess) {
            if seen.insert(p.pid).inserted { union.append(p) }
        }

        // `max(0,)` only so a nonsense topN cannot trap `prefix(_:)`; Python
        // would slice from the end instead, and no caller passes a negative.
        for p in cpuRows.prefix(max(0, topN)) { add(p) }   // top-N by CPU
        for p in memRows { add(p) }                        // top-N by memory
        for p in cpuRows where p.state == "stopped" && p.uid == currentUID {
            add(p)                                         // force-union
        }

        // Python's `list.sort` is STABLE, and the insertion order above is the
        // wire order an old client renders, so equal-CPU rows (every idle
        // process sits at 0.0) must keep it. Swift's `sorted` is not stable —
        // hence the explicit index tiebreak.
        return union.enumerated().sorted { lhs, rhs in
            if lhs.element.cpuPercent > rhs.element.cpuPercent { return true }
            if lhs.element.cpuPercent < rhs.element.cpuPercent { return false }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    // MARK: - Python-compatible primitives

    /// Python's `round(x, 1)`.
    ///
    /// Python rounds the EXACT binary value of `x` to one decimal place with
    /// ties-to-even ("banker's"): `round(0.25, 1) == 0.2`, not 0.3. Swift's
    /// `(x * 10).rounded() / 10` is ties-AWAY-from-zero — it yields 0.3 — and
    /// the ×10 injects its own error on top. `%.1f` is correctly rounded under
    /// the default FE_TONEAREST mode, which is precisely Python's rule, and
    /// `String(format:)` with no locale argument is unlocalised so the decimal
    /// separator is always ".".
    ///
    /// This is reachable in practice: an rss of 256 KiB is exactly 0.25 MiB.
    public static func roundedToOneDecimal(_ x: Double) -> Double {
        guard x.isFinite else { return x }
        return Double(String(format: "%.1f", x)) ?? x
    }

    /// Python's `str.split(None, maxsplit)`: split on runs of whitespace,
    /// skipping leading whitespace, and once `maxSplits` splits have been made
    /// return the rest of the string verbatim as the final field — internal
    /// spaces and all. That last part is what keeps a `comm` of "Google Chrome
    /// Helper (Renderer)" in one piece.
    public static func splitOnWhitespace(_ s: String, maxSplits: Int) -> [Substring] {
        var parts: [Substring] = []
        var idx = s.startIndex
        while true {
            while idx < s.endIndex, s[idx].isWhitespace { idx = s.index(after: idx) }
            if idx == s.endIndex { break }
            if parts.count == maxSplits {
                parts.append(s[idx...])
                break
            }
            var end = idx
            while end < s.endIndex, !s[end].isWhitespace { end = s.index(after: end) }
            parts.append(s[idx..<end])
            idx = end
        }
        return parts
    }
}
