// R0 broadcast-terminal — pure request parsing + authorize-result
// classification. No network, no Deno.serve. Imported by index.ts and
// request_test.ts.
//
// Deliberately mirrors mint-realtime-token/request.ts rather than sharing a
// module with it: the two functions deploy independently, and a shared file
// would mean a parse change in one silently reshapes the other's contract.

export const MAX_CHUNKS = 64;
/** Cap on total BASE64 CHARACTERS per request — not decoded bytes. The
 *  accumulator below sums `data_b64.length`, so 256 KiB here admits roughly
 *  192 KiB of decoded output (base64 is 4 chars per 3 bytes). Named and
 *  documented for what it measures, because an earlier comment called it a
 *  decoded-payload cap and a future reader sizing the Swift batch against it
 *  would have been off by a third.
 *
 *  The Swift sink batches to 64 KiB decoded, so this leaves ample headroom;
 *  its purpose is to stop a hand-rolled client turning one call into an
 *  unbounded Realtime message, not to mirror the client bound exactly. */
export const MAX_TOTAL_B64_BYTES = 256 * 1024;

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function isUuid(v: unknown): v is string {
  return typeof v === "string" && UUID_RE.test(v);
}

/** Realtime event names this relay will forward. An allowlist, not a
 *  sanitizer: the event string ends up in the broadcast envelope.
 *
 *  ⚠️ THIS LIST MUST MATCH WHAT THE HELPER ACTUALLY EMITS, and an earlier
 *  version did not. It read `["stdout", "stderr"]` with a comment claiming
 *  "there is no legitimate third value" — while `publishTailSnapshot` sends
 *  `tail_snapshot_result` through the very same sink. `parseBroadcastBody`
 *  fails WHOLESALE on the first unrecognized event, so that batch 400'd and
 *  took any live stdout coalesced into the same 60 ms window with it: the
 *  reconnect snapshot never arrived AND output that used to flow was lost.
 *
 *  The test for this asserts against the set the HELPER emits, not against
 *  this constant's own members — iterating ALLOWED_EVENTS to check that
 *  ALLOWED_EVENTS is accepted is a tautology, and that is exactly what the
 *  first version of the test did. */
export const ALLOWED_EVENTS = ["stdout", "stderr", "tail_snapshot_result"] as const;
export type AllowedEvent = typeof ALLOWED_EVENTS[number];

export interface Chunk {
  event: AllowedEvent;
  data_b64: string;
}

export interface BroadcastBody {
  device_id: string;
  helper_secret: string;
  session_id: string;
  chunks: Chunk[];
}

export type ParseResult =
  | { ok: true; body: BroadcastBody }
  | { ok: false; error: string };

/** Strict base64 — no whitespace, no URL-safe alphabet, correct padding.
 *  `atob` is lenient in ways that would let a malformed chunk through to the
 *  Realtime envelope, so the shape is checked here rather than assumed. */
const B64_RE = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;

export function parseBroadcastBody(raw: unknown): ParseResult {
  if (typeof raw !== "object" || raw === null) {
    return { ok: false, error: "body must be a JSON object" };
  }
  const o = raw as Record<string, unknown>;
  if (!isUuid(o.device_id)) return { ok: false, error: "device_id must be a uuid" };
  if (!isUuid(o.session_id)) return { ok: false, error: "session_id must be a uuid" };
  if (typeof o.helper_secret !== "string" || o.helper_secret.length === 0) {
    return { ok: false, error: "helper_secret must be a non-empty string" };
  }
  if (!Array.isArray(o.chunks) || o.chunks.length === 0) {
    return { ok: false, error: "chunks must be a non-empty array" };
  }
  if (o.chunks.length > MAX_CHUNKS) {
    return { ok: false, error: `chunks must hold at most ${MAX_CHUNKS} entries` };
  }
  const chunks: Chunk[] = [];
  let total = 0;
  for (const c of o.chunks) {
    if (typeof c !== "object" || c === null) {
      return { ok: false, error: "each chunk must be an object" };
    }
    const co = c as Record<string, unknown>;
    const ev = co.event;
    if (typeof ev !== "string" || !(ALLOWED_EVENTS as readonly string[]).includes(ev)) {
      return {
        ok: false,
        // Derived from the allowlist, never restated: an earlier version
        // hard-coded "stdout or stderr" and kept saying it after
        // tail_snapshot_result was added, so the 400 body told the client to
        // send something the server would also have rejected.
        error: `chunk.event must be one of ${ALLOWED_EVENTS.join(", ")}`,
      };
    }
    const d = co.data_b64;
    if (typeof d !== "string" || d.length === 0) {
      return { ok: false, error: "chunk.data_b64 must be a non-empty string" };
    }
    if (!B64_RE.test(d)) {
      return { ok: false, error: "chunk.data_b64 must be standard base64" };
    }
    total += d.length;
    if (total > MAX_TOTAL_B64_BYTES) {
      return { ok: false, error: "chunks exceed the per-request size cap" };
    }
    chunks.push({ event: ev as AllowedEvent, data_b64: d });
  }
  return {
    ok: true,
    body: {
      // Canonical lowercase, same reason as mint-realtime-token: the RPC and
      // the topic both compare `rs.id::text`, which is lowercase, as a STRING.
      device_id: o.device_id.toLowerCase(),
      helper_secret: o.helper_secret,
      session_id: o.session_id.toLowerCase(),
      chunks,
    },
  };
}

export type AuthorizeOutcome =
  | { authorized: true; owner: string }
  | { authorized: false; status: 401 | 403 | 500 };

/**
 * Map a `remote_helper_authorize_broadcast` result to an outcome.
 *
 * Copied in spirit from mint-realtime-token, INCLUDING its 2026-07-03 review
 * fix, because getting this wrong has a specific, known cost: ONLY the
 * intentional 42501 RAISE is an authoritative denial (403). Any other error —
 * DB blip, PostgREST 5xx, statement timeout — is infra and maps to 500.
 *
 * The Swift sink SUPPRESSES a session on 403 for a bounded backoff window
 * (`denialBackoff`, 60 s) and retries after it. Misreporting an infra blip as
 * 403 therefore costs a minute of a healthy private terminal rather than
 * everything until restart — an earlier version of both this comment and that
 * sink described a PERMANENT latch, which is why the distinction was written
 * so emphatically. The rule is unchanged and still worth keeping: only the
 * intentional 42501 is a denial.
 */
export function classifyAuthorizeResult(
  data: unknown,
  error: unknown,
): AuthorizeOutcome {
  if (error != null) {
    const code = (error as { code?: string } | null)?.code;
    return { authorized: false, status: code === "42501" ? 403 : 500 };
  }
  if (!isUuid(data)) return { authorized: false, status: 403 };
  return { authorized: true, owner: data };
}

/** The one topic this relay may ever publish to. A function, not a template
 *  at the call site, so there is exactly one place the prefix is spelled. */
export function privateTopic(sessionId: string): string {
  return `pterm:${sessionId}`;
}
