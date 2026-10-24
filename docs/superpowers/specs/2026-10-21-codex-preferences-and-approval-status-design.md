# Codex preferences and approval status

Expose Codex session settings using its installed CLI schema and the official configuration
reference, rather than copying Claude-only flags. Preserve nil as inheritance, old preferences,
and project overrides. Share the app-wide startup control with Claude.

The interactive TUI starts through `codex resume`; apply preferences there as well as at thread
creation. Quote each override so instruction text cannot become shell syntax.

An approval prompt must show waiting in the sidebar. Rollouts have no approval event, and a
separate app-server reports notLoaded for TUI-owned threads. Supplement the rollout with a
live-screen check using the existing numbered-dialog parser and Codex confirmation footer.
Restore the latest turn state after dismissal; unreadable surfaces supply no dismissal evidence.
Do not wake sleeping tabs. Stop observation when the last subscriber detaches.

Source: https://learn.chatgpt.com/docs/config-file/config-reference and installed `codex --help`
and `codex app-server generate-json-schema` (2026-10-21).
