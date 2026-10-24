# Native Codex dialogs

Implement the shared-server route established in CODEX-DIALOGS-INVESTIGATION.md.
Codex 0.163+ uses its managed per-account daemon; older clients retain their existing
terminal behavior. Flight Deck connects to the private Unix WebSocket, subscribes by
thread/resume, and routes server requests before matching outgoing RPC responses.

Native pending requests are the source of truth for status and phone offers. Answers
must match account, thread, request id and connection generation, and preserve the
decisions Codex offers. Rejoining recovers pending requests. Terminal screens provide
the fallback for local menus and trust dialogs. Keep all existing conversation pins,
rollout history and account homes. Never restart the user's daemon to adopt it.

Use the existing question/answer wire for option lists and structured questions, with
schema validation for MCP form fields. Links require explicit phone interaction.
Unknown shapes remain visibly waiting and cannot become an implicit approval.

Deploy only after focused native-dialog tests, the token-free live shared-server
probe, macOS/iOS builds and release verification. Install through swap-release.sh.
