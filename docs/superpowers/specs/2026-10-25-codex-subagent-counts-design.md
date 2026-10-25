# Codex sub-agent counts

Count active spawned descendants of each attached Codex conversation, including children
blocked on approval and nested workers. Idle, completed, interrupted, failed and closed
workers do not count. Ordinary peer-message recipients are not children.

Use native thread and collaboration-item notifications for immediate updates. Reconcile
with paginated `thread/list(ancestorThreadId, sourceKinds: subAgent)` metadata after
connection and on the existing five-second status cadence. Do not load child threads or
read their histories. Publish through `AgentEvent.subagentCount`, preserving the existing
sidebar, background-work and fleet wire behavior. Replay the current count to new tabs.

Failed or partial snapshots retain the last count; a full snapshot can clear it. Keep
events arriving during a snapshot newer than that snapshot. Legacy standalone threads
without native descendant metadata retain no claimed count. Codex's phone summary uses the same
singular/plural wording as Claude and OpenCode.

Count-only sidebar badges stay visible while waiting and do not open an empty outline.
Descendant queries include every model provider so role-specific providers are not omitted.
