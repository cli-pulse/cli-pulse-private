// Pure, unit-testable receipt logic for validate-receipt (H-8 / H-14 review).
// The actual JWS signature verification stays in index.ts (it needs the Apple
// app-store-server-library + real receipts); everything decidable without a
// live signature/network lives here so it can be deno-tested.

import { Buffer } from "node:buffer";

export const PRODUCT_TIER_MAP: Record<string, string> = {
  "com.clipulse.pro.monthly": "pro",
  "com.clipulse.pro.yearly": "pro",
  "com.clipulse.team.monthly": "team",
  "com.clipulse.team.yearly": "team",
  // v1.14: Pro Lifetime — Non-Consumable IAP, no expiresDate.
  "com.clipulse.pro.lifetime": "pro",
};

export const LIFETIME_PRODUCT_IDS = new Set<string>([
  "com.clipulse.pro.lifetime",
]);

export function tierForProduct(productId: string): string {
  return PRODUCT_TIER_MAP[productId] ?? "free";
}

export function isLifetimeProduct(productId: string): boolean {
  return LIFETIME_PRODUCT_IDS.has(productId);
}

export type ReceiptEnvironment = "Sandbox" | "Production";

export type JWSEnvResult =
  | { ok: true; environment: ReceiptEnvironment }
  | { ok: false; error: string };

/**
 * Peek the (UNVERIFIED) `environment` claim from a StoreKit 2 JWS payload to
 * route PRODUCTION vs SANDBOX before constructing the verifier. The peek is
 * unauthenticated — the signature, bundleId, appAppleId and root-cert chain are
 * still enforced by the verifier afterwards, so a forged `environment` only
 * changes which verifier we try (and a mismatched signature still fails).
 * Anything other than the exact string "Sandbox" is treated as Production.
 */
export function peekJWSEnvironment(jws: string): JWSEnvResult {
  const parts = jws.split(".");
  if (parts.length !== 3) return { ok: false, error: "Malformed JWS" };
  try {
    const padded = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const pad = "=".repeat((4 - (padded.length % 4)) % 4);
    const claim = JSON.parse(atob(padded + pad));
    return {
      ok: true,
      environment: claim.environment === "Sandbox" ? "Sandbox" : "Production",
    };
  } catch (_) {
    return { ok: false, error: "Cannot decode JWS payload" };
  }
}

/**
 * H-8: a signature-valid SANDBOX receipt (App Review, TestFlight, or a local
 * dev/StoreKit-test build) must NOT be persisted as a real server-side paid
 * entitlement — doing so would hand any sandbox/TestFlight tester real Pro/Team
 * in production. We still return `verified:true` + the tier so the IAP unlocks
 * for the session (the client re-validates the sandbox receipt each launch, so
 * App Review sees the purchase work), but only a PRODUCTION receipt is written
 * to `profiles.tier` / `subscriptions`.
 */
export function shouldPersistEntitlement(environment: ReceiptEnvironment): boolean {
  return environment === "Production";
}

/// v1.52 — is the configured App Apple ID usable at all?
///
/// ⚠️ CORRECTION (v1.52.1). This helper was introduced on the theory that an
/// unset `APPLE_APP_APPLE_ID` was why no purchase was ever recorded. That was
/// a guess, it was wrong, and the original text here asserted it as fact.
/// Measured 2026-08-28: the secret is set to the correct value (its digest
/// matches sha256 of the real App Apple ID), AND `verifyAndDecodeTransaction`
/// never reads `appAppleId` in the first place — only `bundleId` and
/// `environment`. So this could not have been the cause on either count.
///
/// The actual cause was in `index.ts`: the root certificates were passed as
/// `ArrayBuffer` instead of `Buffer`, which makes the `SignedDataVerifier`
/// constructor throw before any verification or database write happens.
/// See `toRootCertificates` below.
///
/// This helper is kept because `APPLE_APP_APPLE_ID` *is* required for App Store
/// Server Notifications and `verifyAndDecodeAppTransaction`, so an unset value
/// remains a genuine misconfiguration worth reporting distinctly — just not the
/// explanation for the missing rows.
///
/// Pure and exported so the distinction is unit-testable without a live
/// StoreKit round-trip.
export function isUsableAppAppleId(raw: string | undefined | null): boolean {
  if (raw === undefined || raw === null) return false;
  const trimmed = raw.trim();
  if (trimmed === "") return false;
  const n = Number(trimmed);
  return Number.isFinite(n) && Number.isInteger(n) && n > 0;
}

/// Convert PEM-encoded root certificates into the exact type Apple's
/// `SignedDataVerifier` accepts.
///
/// This function exists because of a real, three-month production outage.
/// `index.ts` used to build the roots inline as
/// `new TextEncoder().encode(pem).buffer` — an `ArrayBuffer`, which
/// `new X509Certificate()` rejects on both Node and Deno. The resulting
/// TypeError was thrown by the `SignedDataVerifier` CONSTRUCTOR, which sits
/// outside the try/catch around `verifyAndDecodeTransaction`, so every single
/// Apple receipt — sandbox and production — died as an unexplained HTTP 500
/// before any database write. Zero purchases were recorded between v1.21
/// (2026-05-15) and 2026-08-28, including three real paid transactions.
///
/// It went unnoticed for so long because nothing ever type-checked `index.ts`
/// (`deno test` only checks modules a test file imports, and no test imported
/// it) and nothing ever constructed a verifier in a test.
///
/// Extracted here so both of those are now false: it is type-checked, and
/// `receipt_test.ts` builds a real `SignedDataVerifier` from its output.
///
/// `Buffer` specifically — a plain `Uint8Array` runs fine but fails the
/// library's declared `Buffer[]` parameter type, which would leave `deno check`
/// permanently red.
export function toRootCertificates(pems: readonly string[]): Buffer[] {
  return pems.map((pem) => Buffer.from(pem, "utf-8"));
}
