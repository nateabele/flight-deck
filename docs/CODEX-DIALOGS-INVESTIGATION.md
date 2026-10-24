# Codex dialogs: shared-server investigation

Investigated 2026-10-23 against installed codex-cli 0.163.0. The implementation now follows this route; release validation is recorded in
`docs/superpowers/plans/2026-10-23-codex-native-dialogs.md`.

## Finding

The older adapter's exclusive-writer limitation does not rule out current Codex's
shared-server model. Two clients of one server can join the same running thread,
receive the same server requests, and resolve them from either client. A native
Codex TUI connected with `--remote unix://<socket>` participates in that model.

Flight Deck currently creates a separate stdio app-server while its terminal runs
`codex resume`. Move both onto the same account-specific server before relying on
notifications or server requests to represent the terminal's dialogs.

## Measured evidence

An isolated Python probe used a temporary CODEX_HOME and workspace, a private Unix
WebSocket listener, and a scripted loopback Responses server. No external model API
or user credentials were used. The native TUI ran in a private PTY without opening
a window or taking screen focus. Every process created by the probe was stopped.

Both of these scenarios passed:

| Check | Command approval | Structured question |
| --- | --- | --- |
| Second client joins the same persisted thread | Passed | Passed |
| Both clients receive the same native request id and payload | Passed | Passed |
| Native Codex TUI displays the dialog | Passed | Passed |
| A third client joining after the request receives it | Passed | Passed |
| Second client's response produces `serverRequest/resolved` on both original clients | Passed | Passed |

Methods observed: `item/commandExecution/requestApproval` and
`item/tool/requestUserInput`. Also observed `thread/status/changed` on both clients.
The approval was declined/cancelled; no approval-granting test was needed.

Probe and raw captures during this investigation:

- `/tmp/fd-codex-dialog-probe.py` (temporary investigation code).
- Approval native TUI capture: temporary directory `fd-dialog-probe-gr367mkz` under
  this machine's `TMPDIR`, file `tui.capture`.
- Question native TUI capture: temporary directory `fd-dialog-probe-490p0_2g` under
  `TMPDIR`, file `tui.capture`.

## Options

1. **Shared native protocol, plus a screen fallback for local UI (recommended).**
   Keep the native Codex terminal. Connect Flight Deck and that TUI to the same
   server. Track native pending requests and status, push their contents to the
   phone, and respond by native request id. Recover pending dialogs by rejoining
   after reconnect. Version-gate this behavior; 0.163.0 is the version tested here,
   not an established minimum. The WebSocket interface is experimental upstream.
2. **Extend terminal parsing.** Reuse `ChoiceDialog` and screen-prompt identities
   to expose visible menus on the phone. This can work with the existing process
   arrangement, but requires captures and answer drivers for each dialog shape,
   including pagination, multi-question input, narrow screens and changed labels.
   It cannot recover information clipped from the terminal screen.
3. **Permission hooks plus screen parsing.** Codex's `PermissionRequest` hook can
   expose approval details and return decisions. It does not cover the full
   question/MCP elicitation surface, so it is an additional source rather than a
   complete solution for all dialogs.

## Implementation surface for option 1

- Account-specific shared server transport and lifecycle. The server must survive
  an ordinary Flight Deck restart without killing detached terminal sessions.
- Native TUI launch/resume onto that same server. Retain existing thread pins and
  account homes. Test both new and restored tabs.
- Bidirectional RPC handling. `CodexRPC.receive` currently ignores server requests;
  distinguish messages containing `method` and `id` from responses before matching
  client request ids, since the two directions can reuse numeric ids.
- Pending-dialog state keyed by account, thread, native request id and connection
  generation. Track request resolution, turn interruption, close and reconnect.
- Extend fleet wire and phone presentation to carry exact decisions, question ids,
  permission scopes and MCP form schemas. Current generic permission cards carry
  less information than these native requests provide.
- Reject expired or already-resolved answers; test Mac/phone races and reconnect
  while a dialog is open.

## Coverage boundary

The documented native protocol includes command/network approvals, file-change
approvals, explicit permission grants, structured user-input questions and MCP
elicitation forms/URLs. Only command approvals and questions were exercised by
the live probe; the others need individual fixtures and live integration gates.

Startup trust, hook trust, sign-in, onboarding, and locally opened menus must be
inventoried separately. They are not necessarily server requests. Use native
authentication APIs where available and a screen bridge for local UI. Do not call
the feature complete merely because the two model-dialog probes passed.

## Daemon facts found while shipping (codex 0.164.0, probed live)

- `codex app-server daemon start` reports `~/.codex/app-server-control/app-server-control.sock`,
  a symlink to a short socket under `/tmp/codex-daemon-<uid>/`. Validate the containing
  directory, then connect to the target.
- `codex --remote … resume` refuses every permission override: `--sandbox`, `approval_policy`,
  `sandbox_workspace_write.*`, and the control-access profile all exit with "Permission
  overrides are not supported when resuming a remote task". `--model` and other `--config`
  keys are accepted. Permissions have to travel in `thread/start`/`thread/resume` params.
  The control-access grant works as `config` (`default_permissions`, `permissions.<name>`,
  `features.network_proxy`).
- `thread/resume` overrides apply only when that call loads the thread, which means no
  connection is subscribed to it. A thread stays loaded after its last subscriber leaves, and
  a later bare resume (what the `--remote` TUI sends) keeps the settings. So `rebind`
  unsubscribes Flight Deck's own connection first. It never does this while a turn is in
  flight, because that would risk the pending approval.
- Flight Deck's daemon socket must be close-on-exec. Without it, every tab's `fd-abduco`,
  shell and TUI inherited the connection. It then outlived the app, and every thread it had
  subscribed stayed pinned to whatever settings it was loaded with.

## Official references

- [App-server protocol and dialog types](https://learn.chatgpt.com/docs/app-server).
- [Codex hooks and PermissionRequest](https://learn.chatgpt.com/docs/hooks).
- Installed `codex app-server generate-json-schema --experimental` output,
  particularly `ThreadResumeParams`, `ServerRequest` and `ServerRequestResolvedNotification`.
