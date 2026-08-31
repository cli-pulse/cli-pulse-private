# Claude Code permission hook — setup and diagnosis

Wires Claude Code's `PermissionRequest` / `PreToolUse` hooks so that permission
requests raised by a **CLI Pulse-managed session on this Mac** can be approved
or denied from the CLI Pulse UI, instead of only from the terminal that Claude
is running in.

> **The filename is historical.** This was "Remote Approval Setup", describing a
> flow where a permission request travelled to Supabase and you approved it from
> your iPhone. **That flow is retired** (v1.52.1) and the sections describing it
> have been removed rather than left to mislead. The file keeps its name because
> `helper/permissions_diagnose.py` sends users here **by path** when it detects a
> misconfigured hook — renaming it would point a shipped diagnostic at nothing.
>
> **Audience.** Developers and trusted testers. This repository is public despite
> being named `cli-pulse-private`; nothing here is a credential.

## What the hook does now

| | |
|---|---|
| **Does** | Lets a CLI Pulse-**managed** session (one CLI Pulse spawned, so the helper owns its PTY) surface its permission requests in the app's Sessions tab, where you Approve / Reject. Transport is a Unix-domain socket on this machine. |
| **Does NOT** | Send anything to Supabase, your phone, or any server. There is no remote approval path any more, and nothing is uploaded when the hook fires. |

A **hand-launched** Claude session — one you started yourself in a terminal —
has no managed row, so the hook defers to Claude's own prompt and gets out of
the way. That is deliberate: an external session must never be blocked by CLI
Pulse being unavailable.

## Prerequisites

1. **Paired helper.** `~/.cli-pulse-helper.json` exists and is valid:
   ```bash
   python3 helper/cli_pulse_helper.py inspect | head -5
   ```
   The output should mention a `device_id` matching your Mac's row in
   `public.devices`. If not, run `pair` first per the main README.
2. **Local session control on.** The helper's local control gate must be
   enabled — the Sessions tab shows its state, and `hello` reports the
   `approvals` capability when the helper can serve them.

You do **not** need the Remote Control toggle. That switch now gates machine
controls (fan target, low-power mode, keep-awake) and has no effect here.

## Wire the hook into Claude Code

The helper prints a copy-pasteable JSON snippet tailored to this machine's
absolute path:

```bash
python3 helper/cli_pulse_helper.py remote-approvals print-claude-hook-config
```

It does **not** write anywhere. Copy the `hooks` block into
`~/.claude/settings.json` (create the file if it doesn't exist). If the file
already has a `hooks` section, MERGE rather than replace.

```json
{
  "hooks": {
    "PermissionRequest": [
      {
        "type": "command",
        "command": "python3 /absolute/path/to/cli pulse/helper/cli_pulse_helper.py remote-approval-hook --provider claude"
      }
    ]
  }
}
```

* Replace the absolute path verbatim — Claude Code does not expand `~` inside
  `command`.
* If the helper is not on `PATH`, point at the python3 binary too
  (`/usr/bin/python3` or `/opt/homebrew/bin/python3`).
* The hook reads JSON on stdin and writes one line of JSON to stdout. Logging
  goes to stderr; do **not** add `> /dev/null` or `2>&1` — the hook needs a
  clean stdout pipe.

Restart Claude Code after saving.

> The **app** installs its own hook entry pointing at the bundled Swift helper
> (`<helper-path> remote-approval-hook --provider claude`). The snippet above is
> the manual equivalent for the Python helper. Both share the same wire
> contract; do not install both for the same event.

## What the user sees

| Scenario | What Claude shows |
|---|---|
| Managed session, helper reachable, approvals advertised | Approve / Reject appear on that row in the Sessions tab. Approve → the tool call proceeds. |
| Managed session, helper down | Fail-closed: `deny` with an explainer. A broken helper never auto-approves. |
| Hand-launched (external) session | The hook abstains and Claude's own prompt runs. Never blocked by CLI Pulse. |
| High-risk shell command (`rm -rf`, `sudo`, …) | Short-circuits to the local prompt. High-risk actions are always decided in front of you. |

## Diagnose "Always Allow keeps re-prompting"

Three read-only subcommands surface common Claude Code permission gotchas
without rewriting any settings file:

```bash
# At-a-glance state of helper pairing + Claude hook wiring
python3 helper/cli_pulse_helper.py remote-approvals status

# Print the JSON snippet for ~/.claude/settings.json (does NOT write)
python3 helper/cli_pulse_helper.py remote-approvals print-claude-hook-config

# Walk all 4 settings scopes (managed/local/project/user), apply the merge
# rules, and report: parse errors, deny-overrides-allow, ask-overrides-allow,
# narrow Bash patterns, allow-only-in-local-scope, missing hook.
python3 helper/cli_pulse_helper.py remote-approvals diagnose-claude-permissions

# Same diagnosis as JSON, for tooling.
python3 helper/cli_pulse_helper.py remote-approvals diagnose-claude-permissions --json
```

**Privacy note on `diagnose` output.** It prints local file paths
(`~/.claude/settings.json`, project cwd) and the raw text of your
`permissions.allow` / `ask` / `deny` rules — which can include paths and command
patterns from your Always-Allow history. **Do not paste it into a public bug
report verbatim**; redact first. The diagnose is read-only and uploads nothing.

## Disabling

Remove the `PermissionRequest` / `PreToolUse` block from
`~/.claude/settings.json` and restart Claude Code. Claude then handles every
permission prompt itself, exactly as it does without CLI Pulse installed.

## Limits

* Approve is `once` per request — there is no persistent Always-Allow shape.
* Managed sessions only. A hand-launched session is deliberately never gated.
* macOS only; the transport is a local Unix-domain socket.
