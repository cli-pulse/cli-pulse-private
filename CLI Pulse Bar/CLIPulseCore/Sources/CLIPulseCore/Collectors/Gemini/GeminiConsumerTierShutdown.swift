// Derived from steipete/CodexBar @ 25bba9b7
// Sources/CodexBarCore/Providers/Gemini/GeminiStatusProbe.swift
// (https://github.com/steipete/CodexBar): `isConsumerTierDeprecationSignal`,
// `isConsumerClientUnsupported` / `hasUnsupportedClientIneligibleTier`, and
// the rule for when a quota HTTP 403 means the shutdown (CodexBar 0.60.2,
// #3139).
//
// Not verbatim:
//   * the three pieces are gathered into one enum instead of living on
//     `GeminiStatusProbeError` and `GeminiStatusProbe`;
//   * the tier arrives as Google's raw id string, because `GeminiCollector`
//     keeps it that way, rather than as CodexBar's `GeminiUserTierId`;
//   * no logging;
//   * `isPersonalAccount`: CodexBar reads only `oauth_creds.json`, which
//     always carries an ID token, so it can always tell a Workspace account
//     from a personal one. Our Antigravity and Keychain logins carry none, and
//     for them the collector lets the quota call decide.
//
// ─── MIT License (full notice required by upstream) ───────────────
//
// MIT License
//
// Copyright (c) 2026 Peter Steinberger
//
// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use, copy,
// modify, merge, publish, distribute, sublicense, and/or sell copies
// of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
// OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
// HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
// WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.

import Foundation

/// Google's June 2026 shutdown of Gemini CLI for personal Google accounts
/// (individual, AI Pro and Ultra).
///
/// Google does not answer it with an error. `loadCodeAssist` returns HTTP 200
/// with no `currentTier` and the consumer tier listed under `ineligibleTiers`
/// with reason `UNSUPPORTED_CLIENT`; the quota call that follows then fails
/// with a 403 (`SUBSCRIPTION_REQUIRED`) that says nothing about the shutdown.
/// Read on its own, that 403 looks like a lapsed sign-in, and the user is told
/// to reconnect, which cannot work: Google refuses this account through this
/// client, however fresh the token.
///
/// Workspace, education and licensed (Standard/Enterprise) accounts are not
/// part of the shutdown, and Google may still list the consumer tier as
/// ineligible for them, so both signals below are gated on the account being
/// a personal one.
enum GeminiConsumerTierShutdown {

    /// Text Google uses for the shutdown, in a `loadCodeAssist` ineligible-tier
    /// entry or in an error body. Case-insensitive.
    static func isShutdownSignal(_ text: String) -> Bool {
        let normalized = text.lowercased()
        if normalized.contains("unsupported_client") { return true }
        if normalized.contains("ineligibletiererror") { return true }
        if normalized.contains("no longer supported"), normalized.contains("gemini code assist") {
            return true
        }
        if normalized.contains("migrate"), normalized.contains("antigravity"), normalized.contains("gemini") {
            return true
        }
        return false
    }

    /// An error body (any status) that states the shutdown outright.
    static func isShutdownResponse(_ body: Data) -> Bool {
        guard let text = String(data: body, encoding: .utf8) else { return false }
        return isShutdownSignal(text)
    }

    /// Whether a `loadCodeAssist` response says this client can no longer
    /// serve this account.
    ///
    /// Two things outrank the ineligible-tier listing. A named paid tier
    /// (`paidTier.name`), which the shutdown response never carries. And a
    /// hosted domain (`hd` in the ID token): Workspace and education accounts
    /// keep Gemini CLI.
    static func isClientUnsupported(loadCodeAssist json: [String: Any], hostedDomain: String?) -> Bool {
        guard paidTierName(in: json) == nil, hostedDomain == nil else { return false }
        guard let ineligible = json["ineligibleTiers"] as? [[String: Any]] else { return false }
        // `tierId` is deliberately ignored: any UNSUPPORTED_CLIENT entry means
        // *this client* is unsupported, whichever tier Google attached it to.
        return ineligible.contains { entry in
            [entry["reasonCode"], entry["reasonMessage"]]
                .compactMap { $0 as? String }
                .contains(where: isShutdownSignal)
        }
    }

    /// A quota 403 that carries no shutdown wording is still the shutdown when
    /// `loadCodeAssist` flagged this client and the account is not on a
    /// licensed tier. A Standard/Enterprise 403 stays an ordinary failure.
    static func isShutdownQuotaDenial(status: Int, clientUnsupported: Bool, tierId: String?) -> Bool {
        status == 403 && clientUnsupported && tierId != "standard-tier"
    }

    static func paidTierName(in json: [String: Any]) -> String? {
        guard let paidTier = json["paidTier"] as? [String: Any],
              let raw = paidTier["name"] as? String
        else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The `hd` (hosted domain) claim of a Google ID token, read without
    /// verifying it: it only decides which message to show, never access.
    static func hostedDomain(idToken: String?) -> String? {
        guard let claims = claims(idToken: idToken),
              let hd = claims["hd"] as? String,
              !hd.isEmpty
        else { return nil }
        return hd
    }

    /// Whether an ID token says this is a personal account: it decodes, and
    /// it carries no hosted domain.
    ///
    /// false when there is no readable ID token. Antigravity's login never
    /// carries one, and neither does CLI Pulse's own Keychain sign-in; for
    /// them a Workspace account looks exactly like a personal one, so only
    /// the quota call can tell (`isShutdownQuotaDenial`).
    static func isPersonalAccount(idToken: String?) -> Bool {
        guard let claims = claims(idToken: idToken) else { return false }
        let hd = (claims["hd"] as? String) ?? ""
        return hd.isEmpty
    }

    /// The payload of a Google ID token, unverified. nil when there is no
    /// token or it does not decode.
    private static func claims(idToken: String?) -> [String: Any]? {
        guard let token = idToken else { return nil }
        let parts = token.components(separatedBy: ".")
        guard parts.count >= 2 else { return nil }
        var payload = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 { payload += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
