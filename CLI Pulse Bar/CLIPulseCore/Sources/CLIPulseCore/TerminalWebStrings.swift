import Foundation

/// The in-app terminal's localized strings, handed to the xterm.js page.
///
/// xterm.js has two built-in English strings that reach a screen reader: the
/// `aria-label` of the hidden textarea that takes keyboard input (set when
/// `term.open()` runs, in every mode, so VoiceOver announces "Terminal input"
/// on focus) and the live-region message for output too fast to announce.
/// Everything else in the terminal window is already translated, so a
/// VoiceOver user in any other language heard English exactly where the
/// terminal takes their typing.
///
/// Both web view hosts — the Mac `TerminalView` and the iPhone
/// `RemoteTerminalView` — install `userScriptSource()` at document start, and
/// `Resources/Terminal/index.html` copies the values into `Terminal.strings`
/// before it opens the terminal. Read at web view creation, i.e. in the
/// language the app is showing when the terminal opens.
public enum TerminalWebStrings {
    /// JavaScript that sets `window.TERMINAL_STRINGS`. The values go through
    /// JSON encoding, so a translation containing a quote or backslash cannot
    /// break out of the string literal.
    public static func userScriptSource() -> String {
        let strings = [
            "promptLabel": L10n.terminal.inputLabel,
            "tooMuchOutput": L10n.terminal.tooMuchOutput,
        ]
        // Encoding a [String: String] cannot fail; if it somehow did, an empty
        // object leaves the page on xterm's English defaults.
        let json = (try? JSONSerialization.data(withJSONObject: strings, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        return "window.TERMINAL_STRINGS = \(String(decoding: json, as: UTF8.self));"
    }
}
