"""Whether the PYTHON helper offers the remote **session** plane.

MIRRORS `HelperSwift/Sources/HelperKit/RemoteSessionPlane.swift` and
`CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/RemoteSessionPlane.swift`.
Three packages that cannot import each other now carry this constant, and
`test_remote_session_plane.py` reads the Swift source and fails if they
disagree — a copied constant without a drift gate is how a "retired" feature
comes back on one side only.

WHY RETIRED
-----------
Measured against production 2026-08-30 (see the Swift file for the full table):
no non-owner ever started a remote session, `remote_session_commands` and
`remote_permission_requests` were a durable zero, and the app-side surfaces
were removed across PRs #499-#514.

WHY THIS FILE EXISTS AT ALL
---------------------------
The Python helper still constructs a `pterm:` terminal-broadcast producer when
`remote_realtime_broadcast_enabled` is set, and that flag has DEFAULTED ON since
helper 1.24.0. `pterm:` streams a terminal to the phone; the phone stopped
having anywhere to put it when the plane was retired.

Two independent reasons that producer cannot deliver anything today, both
measured 2026-09-08:

  * NO CONSUMER. Nothing in the product subscribes to `pterm:` or `term:` —
    no Realtime WebSocket client exists on macOS, iOS or Android.
  * NO WRITE PATH. It takes v0.65's direct route (mint a token, POST to
    /realtime/v1/api/broadcast as `r0_broadcast`). `r0_broadcast` holds no
    INSERT on `realtime.messages`, and the owner of a hosted Supabase project
    cannot grant it, so Realtime refuses the write. The endpoint returns
    HTTP 202 either way, so the failure has always been invisible.

It has therefore not delivered a byte since at least 2026-08-30, while still
minting a token and issuing an HTTPS request per coalesced chunk.

NOT DELETED, GATED
------------------
Same reasoning as the Swift file: behaviour change and source deletion are two
reversible steps, not one. Flipping this back to True restores the previous
behaviour exactly.
"""

#: ``False`` — the helper offers no remote sessions, terminals or approvals.
IS_ENABLED = False


def should_run_terminal_broadcast(config_enabled: bool) -> bool:
    """Whether to construct the ``pterm:`` terminal-broadcast producer.

    The conjunction is the point: the ops flag
    (``remote_realtime_broadcast_enabled``) can only ever turn the producer OFF
    sooner, never on past the retirement. Un-retiring is one edit, in one place,
    reviewed on its own.
    """
    return IS_ENABLED and bool(config_enabled)
