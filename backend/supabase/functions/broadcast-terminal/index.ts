// Supabase Edge Function: broadcast-terminal
//
// R0 — the SERVICE-RELAY half of the private terminal mirror. Accepts redacted
// terminal chunks from a paired helper and republishes them on the RLS-governed
// `pterm:<session_id>` topic.
//
//   helper  --POST {device_id, helper_secret, session_id, chunks[]}-->  this fn
//   this fn --rpc remote_helper_authorize_broadcast (service role)-->  owner uuid
//   this fn --POST /realtime/v1/api/broadcast (service role key)---->  pterm:<sid>
//
// ── Why a relay instead of the helper posting directly ──────────────
// v0.65's design had the helper POST to the broadcast endpoint itself, holding
// a minted `r0_broadcast` token, with the `realtime.messages` WRITE policy as
// the boundary. That token needs `r0_broadcast` to hold INSERT on
// realtime.messages, and MEASURED 2026-09-08 the owner of a hosted Supabase
// project cannot grant it: the table is owned by supabase_realtime_admin, the
// migration role holds INSERT *without grant option*, and such a GRANT does not
// error — it warns and returns success. See
// backend/supabase/migrate_v0.82_r0_broadcast_insert_grant.sql for the full
// measurement and the refused escape hatches.
//
// So this takes the fallback v0.65 itself recorded (its line 65): a
// service-relay broadcast. It needs no privilege nobody has.
//
// ⚠️ THE COST, STATED PLAINLY: `service_role` is `rolbypassrls`, so the
//    realtime.messages WRITE policy is NOT consulted on this path. THIS
//    FUNCTION IS THE ENTIRE WRITE-SIDE BOUNDARY. Every authorization decision
//    lives in the `remote_helper_authorize_broadcast` call below, and the topic
//    is derived from the session id that call authorized — never from anything
//    the caller sends separately. Do not add a caller-supplied topic parameter.
//
// ⛔ KNOWN GAP, and it is a SCHEMA change so it is not fixed here.
//    `remote_helper_authorize_broadcast` (migrate_v0.56, ~lines 145-175) selects
//    on exactly `rs.id`, `rs.device_id`, `rs.user_id` and
//    `rs.realtime_private is true`. There is NO status predicate and no consent
//    column — M4.4d's `cloudShared` is an in-memory helper flag never mirrored
//    to the database, and revocation only posts `status='stopped'`, which this
//    RPC does not read.
//
//    So revocation is enforced ENTIRELY on the client: the visibility gate
//    stops new chunks and the sink's purge barrier abandons in-flight ones. A
//    helper that is compromised, stale, or simply buggy would still be
//    authorized to write a revoked session's topic, and this function — which
//    the paragraph above calls the entire write-side boundary — would let it.
//
//    HALF-CLOSED 2026-09-09 by migrate_v0.83: the RPC now also requires
//    `rs.status in ('pending','running')`, so a session retired to
//    status='stopped' — which is exactly what revocation posts — stops
//    authorizing. Verified against real rows: the old predicate set matched 1,
//    the new one matches 0.
//
//    STILL OPEN: consent. `cloudShared` is an in-memory helper flag never
//    mirrored to the database, so a session that was never shared but is
//    running would still authorize if a helper asked. Closing that needs a
//    consent column the client maintains. So revocation is now enforced on
//    BOTH sides; consent is still client-only. Do not conflate them.
//    The READ side is unaffected and still RLS-governed (migrate_v0.81), so
//    subscribers are still restricted to their own sessions.
//
// Privacy / secrets:
//   * NEVER log helper_secret, the service role key, or chunk payloads. Logs
//     carry session_id (a uuid), chunk COUNT, and HTTP status only.
//   * Chunks arrive ALREADY REDACTED — TerminalBroadcastPublisher runs
//     Redactor.redact before the sink sees a byte. This function does not and
//     must not attempt its own redaction: it cannot see raw output, so a
//     "redact here too" would be theatre that hides where the real invariant
//     lives.
//
// Auth model: deploy with DEFAULT JWT verification ON. The gateway requires a
// valid project JWT (the helper sends the anon key). REAL per-device
// authorization is helper_secret, checked inside
// remote_helper_authorize_broadcast — same model as mint-realtime-token and the
// other remote_helper_* paths.
//
// Auto-provided by Supabase: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  classifyAuthorizeResult,
  parseBroadcastBody,
  privateTopic,
} from "./request.ts";

function json(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") {
    return json(405, { error: "method not allowed" });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!supabaseUrl || !serviceRoleKey) {
    console.error("broadcast-terminal: missing required configuration");
    return json(500, { error: "server not configured" });
  }

  let raw: unknown;
  try {
    raw = await req.json();
  } catch {
    return json(400, { error: "invalid JSON body" });
  }
  const parsed = parseBroadcastBody(raw);
  if (!parsed.ok) {
    return json(400, { error: parsed.error });
  }
  const { device_id, helper_secret, session_id, chunks } = parsed.body;

  // --- the boundary ---
  const supabase = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await supabase.rpc(
    "remote_helper_authorize_broadcast",
    {
      p_device_id: device_id,
      p_helper_secret: helper_secret,
      p_session_id: session_id,
    },
  );
  const outcome = classifyAuthorizeResult(data, error);
  if (!outcome.authorized) {
    // 500 = infra trouble, NOT a denial. The Swift sink suppresses a session
    // for a bounded backoff on 403, so a misreported blip costs a minute of a
    // healthy terminal.
    if (outcome.status === 500) {
      console.error(
        `broadcast-terminal: authorize errored (infra) session=${session_id}`,
      );
      return json(500, { error: "authorization temporarily unavailable" });
    }
    console.warn(
      `broadcast-terminal: authorize denied session=${session_id} status=${outcome.status}`,
    );
    return json(outcome.status, { error: "not authorized for this session" });
  }

  // --- republish ---
  // The topic is built from the session id the RPC just authorized. There is no
  // path by which a caller can influence it.
  const topic = privateTopic(session_id);
  const messages = chunks.map((c) => ({
    topic,
    event: c.event,
    private: true,
    payload: { session_id, data_b64: c.data_b64 },
  }));

  const endpoint = `${supabaseUrl.replace(/\/+$/, "")}/realtime/v1/api/broadcast`;
  let resp: Response;
  try {
    resp = await fetch(endpoint, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: serviceRoleKey,
        Authorization: `Bearer ${serviceRoleKey}`,
      },
      body: JSON.stringify({ messages }),
    });
  } catch (e) {
    console.error(
      `broadcast-terminal: realtime POST failed session=${session_id}: ${
        e instanceof Error ? e.name : "error"
      }`,
    );
    return json(502, { error: "broadcast transport failed" });
  }

  // ⚠️ A 2xx HERE IS AN ACK, NOT A DELIVERY RECEIPT. Measured 2026-09-08
  // against production: an anon-key publish to a private topic returns the
  // same HTTP 202 as a service-role publish, and only the service-role one
  // reaches a subscriber. So `resp.ok` proves the request was accepted, not
  // that anyone received it. The authorization that actually means something
  // happened above, against the database.
  // Drain the body so the connection can be reused. Deno keeps an unread
  // response body's stream open, and this function runs once per coalesced
  // batch — leaking a stream per call is a slow resource leak in the hottest
  // path we have. We deliberately do not LOG the body (it can carry
  // internals); reading and discarding is not the same as echoing.
  try { await resp.arrayBuffer(); } catch { /* already closed */ }

  if (!resp.ok) {
    // Never echo the Realtime body — it can carry internals. Status only.
    console.error(
      `broadcast-terminal: realtime rejected session=${session_id} status=${resp.status}`,
    );
    // Map to 502, NOT to the upstream status: a 403 from Realtime is an
    // infrastructure/config problem on OUR side (service key, topic shape), not
    // an authorization denial for this device — and 403 is the one status that
    // suppresses the session on the helper side.
    return json(502, { error: "broadcast rejected upstream" });
  }

  return json(200, { published: chunks.length });
});
