// Deno tests for the pure receipt logic. Run with:
//   deno test backend/supabase/functions/validate-receipt/receipt_test.ts
//
// H-8 / H-14 (2026-06-07 review): validate-receipt had ZERO tests, and the
// sandbox-receipt → real-paid-tier write was unguarded. These pin the
// environment gate (sandbox must NOT persist a real entitlement), the JWS
// environment peek, and the product→tier map.

import { assert, assertEquals } from "jsr:@std/assert";
import {
  isLifetimeProduct,
  isUsableAppAppleId,
  peekJWSEnvironment,
  shouldPersistEntitlement,
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
