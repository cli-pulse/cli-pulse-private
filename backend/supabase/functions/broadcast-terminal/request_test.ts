import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  ALLOWED_EVENTS,
  classifyAuthorizeResult,
  MAX_CHUNKS,
  parseBroadcastBody,
  privateTopic,
} from "./request.ts";

const DEV = "11111111-1111-4111-8111-111111111111";
const SES = "22222222-2222-4222-8222-222222222222";
const ok = (over: Record<string, unknown> = {}) => ({
  device_id: DEV,
  helper_secret: "s3cret",
  session_id: SES,
  chunks: [{ event: "stdout", data_b64: "aGVsbG8=" }],
  ...over,
});

Deno.test("parse: accepts a well-formed body and canonicalizes uuids", () => {
  const r = parseBroadcastBody(ok({ device_id: DEV.toUpperCase() }));
  assertEquals(r.ok, true);
  if (r.ok) {
    assertEquals(r.body.device_id, DEV);
    assertEquals(r.body.session_id, SES);
    assertEquals(r.body.chunks.length, 1);
  }
});

Deno.test("parse: rejects malformed envelopes", () => {
  const bad: unknown[] = [
    null,
    "string",
    ok({ device_id: "nope" }),
    ok({ session_id: "nope" }),
    ok({ helper_secret: "" }),
    ok({ chunks: [] }),
    ok({ chunks: "x" }),
  ];
  for (const b of bad) assertEquals(parseBroadcastBody(b).ok, false);
});

/** The event names the Swift helper actually puts on this wire.
 *
 *  Hard-coded ON PURPOSE, not derived from ALLOWED_EVENTS. The previous test
 *  iterated the constant to prove the constant was accepted — a tautology that
 *  passed while `tail_snapshot_result` (emitted by
 *  ManagedSessionManager.publishTailSnapshot, via
 *  TerminalBroadcastPublisher.submit's `channel:` -> envelope `event`) was
 *  being rejected with a 400. If the helper gains an event, add it HERE and
 *  watch this fail before widening ALLOWED_EVENTS. */
const EMITTED_BY_HELPER = ["stdout", "stderr", "tail_snapshot_result"];

Deno.test("parse: accepts every event the helper actually emits", () => {
  for (const ev of EMITTED_BY_HELPER) {
    assertEquals(
      parseBroadcastBody(ok({ chunks: [{ event: ev, data_b64: "aGk=" }] })).ok,
      true,
      `the helper emits ${ev}; rejecting it 400s the whole batch, taking co-batched stdout with it`,
    );
  }
});

Deno.test("parse: event is an allowlist, not a sanitizer", () => {
  for (const ev of ALLOWED_EVENTS) {
    assertEquals(parseBroadcastBody(ok({ chunks: [{ event: ev, data_b64: "aGk=" }] })).ok, true);
  }
  for (const ev of ["exit", "STDOUT", "", "stdout\n", "__proto__"]) {
    assertEquals(
      parseBroadcastBody(ok({ chunks: [{ event: ev, data_b64: "aGk=" }] })).ok,
      false,
      `event ${JSON.stringify(ev)} must be refused`,
    );
  }
});

Deno.test("parse: data_b64 must be standard base64, not URL-safe or padded junk", () => {
  const good = ["aGk=", "aGVsbG8=", "YWJjZA==", "YWJj"];
  for (const d of good) {
    assertEquals(parseBroadcastBody(ok({ chunks: [{ event: "stdout", data_b64: d }] })).ok, true, d);
  }
  // URL-safe alphabet, whitespace, wrong padding, and empty are all refused —
  // atob() would accept some of these and hand Realtime a mangled envelope.
  const bad = ["a-_=", "aG k=", "aGk", "=", "", "aGk==="];
  for (const d of bad) {
    assertEquals(
      parseBroadcastBody(ok({ chunks: [{ event: "stdout", data_b64: d }] })).ok,
      false,
      `b64 ${JSON.stringify(d)} must be refused`,
    );
  }
});

Deno.test("parse: bounds chunk count and total size", () => {
  const many = Array.from({ length: MAX_CHUNKS + 1 }, () => ({ event: "stdout", data_b64: "aGk=" }));
  assertEquals(parseBroadcastBody(ok({ chunks: many })).ok, false);
  const atLimit = Array.from({ length: MAX_CHUNKS }, () => ({ event: "stdout", data_b64: "aGk=" }));
  assertEquals(parseBroadcastBody(ok({ chunks: atLimit })).ok, true);

  // One huge chunk trips the byte cap even though the count is fine.
  const huge = "A".repeat(300 * 1024);
  assertEquals(parseBroadcastBody(ok({ chunks: [{ event: "stdout", data_b64: huge }] })).ok, false);
});

Deno.test("classify: ONLY 42501 is an authoritative denial", () => {
  // This is the invariant that keeps the Swift sink from latching a healthy
  // session into deniedSessions on a DB blip.
  assertEquals(classifyAuthorizeResult(null, { code: "42501" }), {
    authorized: false,
    status: 403,
  });
  for (const code of ["57014", "08006", "PGRST301", undefined]) {
    assertEquals(
      classifyAuthorizeResult(null, { code }),
      { authorized: false, status: 500 },
      `sqlstate ${code} must be infra, not denial`,
    );
  }
  assertEquals(classifyAuthorizeResult(SES, null), { authorized: true, owner: SES });
  assertEquals(classifyAuthorizeResult("not-a-uuid", null), { authorized: false, status: 403 });
});

Deno.test("topic: private prefix, and it is the only one this relay can build", () => {
  assertEquals(privateTopic(SES), `pterm:${SES}`);
  // The public prefix must never be reachable from here. `pterm:x` does not
  // start with `term:`, which is what keeps the two families disjoint.
  assertEquals(privateTopic(SES).startsWith("term:"), false);
});
