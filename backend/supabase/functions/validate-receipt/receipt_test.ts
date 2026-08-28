// Deno tests for the pure receipt logic. Run with:
//   deno test backend/supabase/functions/validate-receipt/receipt_test.ts
//
// H-8 / H-14 (2026-06-07 review): validate-receipt had ZERO tests, and the
// sandbox-receipt → real-paid-tier write was unguarded. These pin the
// environment gate (sandbox must NOT persist a real entitlement), the JWS
// environment peek, and the product→tier map.

import { assert, assertEquals } from "jsr:@std/assert";
import {
  SignedDataVerifier,
  Environment,
} from "npm:@apple/app-store-server-library@3";
import {
  isLifetimeProduct,
  isUsableAppAppleId,
  peekJWSEnvironment,
  shouldPersistEntitlement,
  toRootCertificates,
  tierForProduct,
} from "./receipt.ts";

function b64url(s: string): string {
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function makeJWS(payload: Record<string, unknown>): string {
  return `${b64url(JSON.stringify({ alg: "ES256" }))}.${b64url(JSON.stringify(payload))}.sig`;
}

Deno.test("tierForProduct: known products map, unknown → free", () => {
  assertEquals(tierForProduct("com.clipulse.pro.monthly"), "pro");
  assertEquals(tierForProduct("com.clipulse.pro.yearly"), "pro");
  assertEquals(tierForProduct("com.clipulse.team.monthly"), "team");
  assertEquals(tierForProduct("com.clipulse.team.yearly"), "team");
  assertEquals(tierForProduct("com.clipulse.pro.lifetime"), "pro");
  assertEquals(tierForProduct("com.unknown.thing"), "free");
  assertEquals(tierForProduct(""), "free");
});

Deno.test("isLifetimeProduct", () => {
  assert(isLifetimeProduct("com.clipulse.pro.lifetime"));
  assertEquals(isLifetimeProduct("com.clipulse.pro.monthly"), false);
});

Deno.test("shouldPersistEntitlement: H-8 — only Production persists", () => {
  assertEquals(shouldPersistEntitlement("Production"), true);
  assertEquals(
    shouldPersistEntitlement("Sandbox"),
    false,
    "a sandbox receipt must NOT write a real server-side entitlement",
  );
});

Deno.test("peekJWSEnvironment: Sandbox claim", () => {
  const r = peekJWSEnvironment(makeJWS({ environment: "Sandbox", productId: "x" }));
  assert(r.ok);
  if (r.ok) assertEquals(r.environment, "Sandbox");
});

Deno.test("peekJWSEnvironment: Production claim", () => {
  const r = peekJWSEnvironment(makeJWS({ environment: "Production" }));
  assert(r.ok);
  if (r.ok) assertEquals(r.environment, "Production");
});

Deno.test("peekJWSEnvironment: missing/other environment defaults to Production", () => {
  const r = peekJWSEnvironment(makeJWS({ productId: "x" }));
  assert(r.ok);
  if (r.ok) assertEquals(r.environment, "Production");
});

Deno.test("peekJWSEnvironment: malformed JWS (not 3 parts) → error", () => {
  const r = peekJWSEnvironment("aaa.bbb");
  assertEquals(r.ok, false);
  if (!r.ok) assertEquals(r.error, "Malformed JWS");
});

Deno.test("peekJWSEnvironment: undecodable payload → error", () => {
  const r = peekJWSEnvironment("aaa.@@@@.ccc");
  assertEquals(r.ok, false);
  if (!r.ok) assertEquals(r.error, "Cannot decode JWS payload");
});

// ── v1.52: the App Apple ID config guard ────────────────────────────────────
//
// THE CASE THIS EXISTS FOR. `index.ts` reads the id as
// `Number(Deno.env.get("APPLE_APP_APPLE_ID") ?? "0")`. An unset secret becomes
// 0, Apple's SignedDataVerifier then rejects every PRODUCTION receipt, and the
// old code reported that as a generic 400 "JWS verification failed" — the same
// answer it gives for a genuinely bad receipt.
//
// The client treats a failed validation as transient and keeps the local
// StoreKit tier, so the buyer still sees Pro and nothing looks wrong, while the
// backend records nothing. That is consistent with what production shows: no
// row in `subscriptions` has ever carried an apple_transaction_id, not even for
// the real Pro Monthly purchase Apple reports on 2026-06-24.

Deno.test("isUsableAppAppleId: an unset secret is NOT usable", () => {
  // The exact shape of the bug: `Deno.env.get` returns undefined.
  assertEquals(isUsableAppAppleId(undefined), false);
  assertEquals(isUsableAppAppleId(null), false);
  assertEquals(isUsableAppAppleId(""), false);
  assertEquals(isUsableAppAppleId("   "), false);
});

Deno.test("isUsableAppAppleId: zero is NOT usable", () => {
  // `?? "0"` is the literal default in index.ts, so this is the value that
  // actually reached SignedDataVerifier.
  assertEquals(isUsableAppAppleId("0"), false);
  assertEquals(isUsableAppAppleId("-1"), false);
});

Deno.test("isUsableAppAppleId: garbage is NOT usable", () => {
  assertEquals(isUsableAppAppleId("not-a-number"), false);
  assertEquals(isUsableAppAppleId("12.5"), false);
  assertEquals(isUsableAppAppleId("NaN"), false);
  assertEquals(isUsableAppAppleId("Infinity"), false);
});

Deno.test("isUsableAppAppleId: the real app id IS usable", () => {
  // CLI Pulse's actual App Apple ID. Not a secret — it is in every store URL.
  assert(isUsableAppAppleId("6761163709"));
  assert(isUsableAppAppleId(" 6761163709 "));
});

// ── The regression that cost three months of purchases ────────────────────────
//
// From v1.21 (2026-05-15) to 2026-08-28, `index.ts` built the Apple root certs
// as `new TextEncoder().encode(pem).buffer`. That is an ArrayBuffer, which
// `new X509Certificate()` rejects, so the `SignedDataVerifier` CONSTRUCTOR threw
// — outside the try/catch around verifyAndDecodeTransaction — and every Apple
// receipt became an unexplained HTTP 500 before any DB write. Zero rows were
// ever recorded, including for three real paid transactions.
//
// Nothing caught it: `deno test` only type-checks what a test file imports, and
// no test imported `index.ts`; no test had ever constructed a verifier. This
// test does exactly that, so the failure mode cannot return silently.
Deno.test("toRootCertificates output actually constructs a SignedDataVerifier", () => {
  const roots = toRootCertificates([APPLE_ROOT_CA_G3_PEM_FOR_TEST]);
  assertEquals(roots.length, 1);
  assert(roots[0].length > 0, "cert buffer must not be empty");

  // The real assertion: the library accepts it. Pre-fix this threw
  // 'The "buffer" argument must be of type string or an instance of Buffer,
  // TypedArray, or DataView. Received an instance of ArrayBuffer'.
  const verifier = new SignedDataVerifier(
    roots,
    true,
    Environment.PRODUCTION,
    "yyh.CLI-Pulse",
    6761163709,
  );
  assert(verifier, "verifier must construct");
});

Deno.test("an ArrayBuffer root cert is rejected — the exact shipped defect", () => {
  // Negative control. If this ever stops throwing, the assertion above has
  // become vacuous and this whole test file is no longer proving anything.
  const bad = [new TextEncoder().encode(APPLE_ROOT_CA_G3_PEM_FOR_TEST).buffer];
  let threw = false;
  try {
    // deno-lint-ignore no-explicit-any
    new SignedDataVerifier(bad as any, true, Environment.PRODUCTION, "yyh.CLI-Pulse", 6761163709);
  } catch (_) {
    threw = true;
  }
  assert(threw, "ArrayBuffer roots must still be rejected by the library");
});

// Apple Root CA - G3, copied from index.ts. Duplicated deliberately: the point
// of this test is to validate the CONVERSION, and importing index.ts would pull
// in `Deno.serve` and stand up the whole handler.
const APPLE_ROOT_CA_G3_PEM_FOR_TEST = `-----BEGIN CERTIFICATE-----
MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwS
QXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9u
IEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcN
MTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBS
b290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9y
aXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49
AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtf
TjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517
IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySr
MA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gA
MGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4
at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM
6BgD56KyKA==
-----END CERTIFICATE-----`;
