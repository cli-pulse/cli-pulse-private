#if os(macOS)
import SwiftUI
import AppKit

/// Secure text field that suppresses Keychain/iCloud Password AutoFill.
///
/// Why: on macOS, an `NSTextField` immediately followed by an `NSSecureTextField` is
/// heuristically treated as a login form, and Keychain offers saved credentials even
/// when the SecureField holds something unrelated (e.g. an API key). Bridging to
/// AppKit lets us explicitly set `contentType = nil` and disable completion.
struct NoAutoFillSecureField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String

    func makeNSView(context: Context) -> NSSecureTextField {
        let field = NSSecureTextField()
        field.placeholderString = placeholder
        field.contentType = nil
        field.isAutomaticTextCompletionEnabled = false
        field.font = .systemFont(ofSize: 10)
        field.bezelStyle = .roundedBezel
        field.isBordered = true
        field.focusRingType = .default
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ nsView: NSSecureTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NoAutoFillSecureField
        init(parent: NoAutoFillSecureField) { self.parent = parent }
        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSecureTextField else { return }
            parent.text = field.stringValue
        }
    }
}

/// Plain text field with AutoFill suppressed. Used alongside `NoAutoFillSecureField`
/// so the pair is not misread as a username/password form, and for the sign-in
/// email fields, which take AutoFill out of the path altogether.
struct NoAutoFillTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    /// What VoiceOver reads. A SwiftUI `TextField` takes it from its title; an
    /// `NSTextField` only has a placeholder, which is not its label.
    var voiceOverLabel: String? = nil
    var fontSize: CGFloat = 10
    /// One line that scrolls, as a SwiftUI `TextField` is, instead of wrapping
    /// onto a second line. Off for the multi-word fields that already use this.
    var singleLine = false
    /// Return in the field, as a SwiftUI `TextField`'s `.onSubmit`. nil: Return
    /// does what an `NSTextField` does on its own (1.60).
    var onSubmit: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.contentType = nil
        field.isAutomaticTextCompletionEnabled = false
        field.bezelStyle = .roundedBezel
        field.isBordered = true
        field.focusRingType = .default
        field.delegate = context.coordinator
        if singleLine {
            field.cell?.usesSingleLineMode = true
            field.cell?.isScrollable = true
            field.lineBreakMode = .byTruncatingTail
        }
        apply(to: field)
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        // The settings tab redraws in place when the language changes, keeping
        // what was typed; the placeholder and label must follow.
        apply(to: nsView)
    }

    private func apply(to field: NSTextField) {
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
        if let voiceOverLabel, field.accessibilityLabel() != voiceOverLabel {
            field.setAccessibilityLabel(voiceOverLabel)
        }
        if field.font?.pointSize != fontSize { field.font = .systemFont(ofSize: fontSize) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NoAutoFillTextField
        init(parent: NoAutoFillTextField) { self.parent = parent }
        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
        /// Return runs `onSubmit`, with the binding already holding what is
        /// in the field.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)), let onSubmit = parent.onSubmit else {
                return false
            }
            if parent.text != control.stringValue { parent.text = control.stringValue }
            onSubmit()
            return true
        }
    }
}
#endif
