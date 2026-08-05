import Foundation
@_exported import Sentry

public enum SentryPlatform: String {
    case macOS = "macos"
    case iOS = "ios"
    case watchOS = "watchos"
}

/// Thin wrapper around sentry-cocoa that enforces CLI Pulse privacy rules:
/// DSN read from Info.plist, PII disabled, tokens/paths scrubbed via beforeSend.
public enum SentryLogger {
    private static let sensitiveKeyFragments: [String] = [
        "password", "secret", "token", "apikey", "api_key",
        "authorization", "bearer",
        "supabase", "claude_api", "anthropic", "codex", "openai", "gemini", "dsn",
        "device_token", "pairing", "refresh_token", "access_token", "id_token",
        "keychain"
    ]

    public static func start(platform: SentryPlatform) {
        // v1.21 M1: hand the actual SentrySDK.start off the main thread so
        // any unexpected file I/O / hook installation in sentry-cocoa cannot
        // block app launch on a slow-disk or weak-network device. Per
        // Gemini round 1: weak network should never delay our cold start
        // by more than a frame. SentrySDK.start is documented thread-safe.
        //
        // Trade-off: a crash in the ~50ms window between Application init
        // and the background queue picking up `_startSync` won't be captured
        // — acceptable for this feature given crash-on-launch with a working
        // SDK is rare and the dispatched start runs at .utility QoS so it
        // gets to run quickly.
        DispatchQueue.global(qos: .utility).async {
            _startSync(platform: platform)
        }
    }

    private static func _startSync(platform: SentryPlatform) {
        // v1.20 A7: skip Sentry initialization in DEBUG builds. The
        // production project's "All Events" view used to fill with
        // noise from local dev sessions (each iteration triggered
        // crash-loop-style breadcrumbs against the prod DSN, even
        // though `environment` was tagged "debug"). Filtering after
        // the fact wastes quota; not sending in the first place is
        // cheaper. If DEBUG-mode telemetry is ever needed (e.g. for
        // CI smoke runs), wire a separate DSN here behind another
        // compile-time flag.
        #if DEBUG
        return
        #endif

        guard let dsn = Bundle.main.object(forInfoDictionaryKey: "SENTRY_DSN") as? String,
              !dsn.isEmpty,
              dsn.hasPrefix("https://") else {
            return
        }

        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "unknown"
        let build = (info?["CFBundleVersion"] as? String) ?? "0"

        SentrySDK.start { options in
            options.dsn = dsn
            options.releaseName = "cli-pulse@\(version)+\(build)"
            options.environment = Self.environment()
            options.tracesSampleRate = 0.0
            options.sendDefaultPii = false
            options.attachStacktrace = true
            options.enableAutoSessionTracking = true
            options.enableCaptureFailedRequests = false
            options.maxBreadcrumbs = 50
            // macOS menu-bar app: when App-Napped in the background the main
            // run loop is throttled, which the default 2s app-hang watchdog
            // misreports as a hang with a benign idle stack (Sentry
            // APPLE-MACOS-B, the most-frequent macOS "hang"). Raise the
            // threshold on macOS to cut those false positives while still
            // catching genuine multi-second main-thread blocks. (App-hang V2
            // is iOS/tvOS/visionOS-only in sentry-cocoa, so it's a no-op
            // here; the causal fix is the BackgroundActivityAssertion that
            // keeps the app out of App Nap.)
            if platform == .macOS {
                options.appHangTimeoutInterval = 3.0
            }
            #if DEBUG
            options.debug = false
            #endif
            options.beforeSend = { event in
                Self.scrub(event: event)
            }
            options.beforeBreadcrumb = { crumb in
                Self.scrub(breadcrumb: crumb)
            }
        }

        SentrySDK.configureScope { scope in
            scope.setTag(value: platform.rawValue, key: "platform_family")
        }
    }

    private static func environment() -> String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }

    // MARK: - Lightweight event API (v1.26.1)

    /// Record a structured breadcrumb. Safe to call before/without
    /// `start()` (sentry-cocoa drops breadcrumbs when the SDK isn't
    /// running) and on DEBUG builds (start() is skipped there).
    /// All `data` values pass through the same `beforeBreadcrumb`
    /// scrubber configured in `start()`, so sensitive keys are
    /// redacted before they ever leave the device.
    public static func breadcrumb(
        category: String,
        message: String,
        level: SentryLevel = .info,
        data: [String: Any]? = nil
    ) {
        let crumb = Breadcrumb()
        crumb.level = level
        crumb.category = category
        crumb.message = message
        if let data { crumb.data = data }
        SentrySDK.addBreadcrumb(crumb)
    }

    /// Capture a non-fatal warning as a Sentry event. Use sparingly
    /// — this consumes event quota, unlike breadcrumbs. Intended for
    /// "should never happen" guards (e.g. a swallowed JS bridge
    /// exception) where we want field visibility into how often the
    /// last-resort path actually fires. Message is redacted via the
    /// `beforeSend` scrubber.
    public static func captureWarning(
        _ message: String,
        category: String,
        data: [String: Any]? = nil
    ) {
        breadcrumb(category: category, message: message, level: .warning, data: data)
        SentrySDK.capture(message: "[\(category)] \(message)")
    }

    private static func scrub(event: Event) -> Event? {
        if let user = event.user {
            user.email = nil
            user.ipAddress = nil
            user.username = nil
        }

        if var extra = event.extra {
            for key in extra.keys where shouldScrub(key: key) {
                extra[key] = "[scrubbed]"
            }
            event.extra = extra
        }

        if var tags = event.tags {
            for key in tags.keys where shouldScrub(key: key) {
                tags[key] = "[scrubbed]"
            }
            event.tags = tags
        }

        if let exceptions = event.exceptions {
            if isBenignModalTrackingHang(exceptions) {
                return nil
            }
            for ex in exceptions {
                if let v = ex.value {
                    ex.value = redact(v)
                }
            }
        }

        if let msg = event.message {
            event.message = SentryMessage(formatted: redact(msg.formatted))
        }

        return event
    }

    /// Drop app-hang reports that are AppKit waiting for the user to let go of
    /// the mouse button.
    ///
    /// Clicking and holding the menu-bar item puts AppKit into
    /// `-[NSStatusBarButtonCell trackMouse:inRect:ofView:untilMouseUp:]`, a
    /// nested modal event loop that blocks the main thread **by design** until
    /// mouseUp. Sentry's watchdog sees a main thread that hasn't returned to the
    /// normal run loop and files a hang. A user who holds the button for three
    /// seconds — or drags off it, or gets distracted mid-click — produces one
    /// every time.
    ///
    /// This is not the App-Nap false positive `appHangTimeoutInterval` and
    /// `BackgroundActivityAssertion` already address; those were about a
    /// throttled idle run loop. Both mitigations are in place and neither
    /// touches this path, which is why it is still the top macOS "hang":
    /// 15 users on 1.44.0, ~196 events in fourteen days, against a 5k/month
    /// free-tier budget. The cost is not the quota, it is that a real hang
    /// would be indistinguishable from the noise.
    ///
    /// The predicate is deliberately narrow, because dropping a genuine hang is
    /// far worse than keeping a false one. BOTH must hold:
    ///
    ///   1. the stack contains a modal mouse-tracking frame, and
    ///   2. the topmost frame is a wait primitive — the thread is parked in the
    ///      kernel waiting for an event, not executing anything.
    ///
    /// If our code is blocked *underneath* a tracking loop — a synchronous XPC
    /// call in a click handler, the class of bug that produced three real
    /// production hangs — the top frame is that call, not `mach_msg`, and the
    /// event is kept.
    static func isBenignModalTrackingHang(_ exceptions: [Exception]) -> Bool {
        guard exceptions.contains(where: { isAppHangType($0.type) }) else {
            return false
        }
        for ex in exceptions {
            guard let frames = ex.stacktrace?.frames, !frames.isEmpty else { continue }
            // Sentry orders frames oldest-first, so the running frame is last.
            let functions = frames.compactMap(\.function)
            if isBenignModalTrackingStack(functions) {
                return true
            }
        }
        return false
    }

    static func isAppHangType(_ type: String?) -> Bool {
        guard let type else { return false }
        return type.localizedCaseInsensitiveContains("app hang")
            || type.localizedCaseInsensitiveContains("app hanging")
    }

    /// Frame-name predicate, split out so it is testable without constructing
    /// Sentry model objects. `functions` is oldest-first, as Sentry sends it.
    static func isBenignModalTrackingStack(_ functions: [String]) -> Bool {
        guard let top = functions.last else { return false }
        let waiting = ["mach_msg", "_DPSNextEvent", "_BlockUntilNextEventMatchingList"]
        guard waiting.contains(where: { top.contains($0) }) else { return false }
        return functions.contains { $0.contains("trackMouse:") || $0.contains("NSControlTrackMouse") }
    }

    private static func scrub(breadcrumb: Breadcrumb) -> Breadcrumb? {
        if let message = breadcrumb.message {
            breadcrumb.message = redact(message)
        }
        if var data = breadcrumb.data {
            for key in data.keys where shouldScrub(key: key) {
                data[key] = "[scrubbed]"
            }
            breadcrumb.data = data
        }
        return breadcrumb
    }

    private static func shouldScrub(key: String) -> Bool {
        let lower = key.lowercased()
        return sensitiveKeyFragments.contains(where: { lower.contains($0) })
    }

    private static let patterns: [NSRegularExpression] = {
        let sources = [
            #"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#,
            #"sk-[A-Za-z0-9_-]{20,}"#,
            #"sk_(live|test)_[A-Za-z0-9]{16,}"#,
            #"Bearer\s+[A-Za-z0-9_\-\.=]+"#
        ]
        return sources.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    private static let userPathRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"/Users/[^/\s"']+"#
    )

    private static func redact(_ input: String) -> String {
        var out = input
        for regex in patterns {
            let range = NSRange(out.startIndex..., in: out)
            out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: "[scrubbed]")
        }
        if let regex = userPathRegex {
            let range = NSRange(out.startIndex..., in: out)
            out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: "/Users/[user]")
        }
        return out
    }
}
