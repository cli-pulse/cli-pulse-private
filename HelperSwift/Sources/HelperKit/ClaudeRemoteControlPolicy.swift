import Foundation

/// Remote-control M1a — whether Claude Code's Remote Control is allowed
/// by policy on this Mac, answered from the settings files BEFORE a
/// session is spawned with `--remote-control`.
///
/// Claude Code 2.1.259 reads the boolean `disableRemoteControl` from its
/// settings chain (user, project-local, managed) and prints "Remote
/// Control is disabled by your organization's policy" when it is true.
/// The plan's negative control is "org disabled ⇒ the entry is not shown,
/// not an error", so the phone needs the answer up front; the banner
/// scanner is the fallback for anything this pre-check cannot see.
///
/// Fail direction: a missing, unreadable, or malformed file counts as
/// "not a disable" — a stray comma must not hide the feature — but never
/// overrides a real disable in another file.
public enum ClaudeRemoteControlPolicy: String, Sendable, Equatable {
    case allowed
    case disabled

    public static let settingsKey = "disableRemoteControl"

    /// User settings, project-local overrides, and the managed (MDM) file
    /// — the three places Claude Code reads the key from on macOS.
    public static func defaultSettingsFiles(home: String?) -> [URL] {
        var files: [URL] = []
        if let home, home.hasPrefix("/") {
            let claude = URL(fileURLWithPath: home).appendingPathComponent(".claude")
            files.append(claude.appendingPathComponent("settings.json"))
            files.append(claude.appendingPathComponent("settings.local.json"))
        }
        files.append(URL(fileURLWithPath: "/Library/Application Support/ClaudeCode/managed-settings.json"))
        return files
    }

    public static func evaluate(settingsFiles: [URL]) -> ClaudeRemoteControlPolicy {
        for file in settingsFiles {
            guard let data = try? Data(contentsOf: file),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let raw = obj[settingsKey]
            else { continue }
            // JSONSerialization hands booleans back as NSNumber; a JSON
            // string "true" is a different type and is NOT a disable.
            if let n = raw as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID(), n.boolValue {
                return .disabled
            }
        }
        return .allowed
    }

    /// The production question: resolved home + the default chain.
    public static func current() -> ClaudeRemoteControlPolicy {
        evaluate(settingsFiles: defaultSettingsFiles(home: HelperEnvironment.resolvedUserHome()))
    }
}
