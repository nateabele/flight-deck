# Implementation and validation

1. Compare Codex’s pane, installed CLI schema, official config reference and Claude’s controls.
2. Add preference decode/config regression coverage; confirm settings are dropped before the fix.
3. Extend typed settings, per-project merge and both launch paths. Share startup UI with Claude.
4. Add a runtime regression for busy → approval waiting → busy, missing screens and detach.
   Confirmed RED: 10 runtime tests executed, two assertions failed on the new regression.
5. Observe live approval dialogs on the existing clock and preserve rollout activity underneath.
6. Run focused preference, schema, launch, runtime and status-routing tests on the test Mac.
7. Update architecture and adapter handoff documentation with the final behavior and limits.

Completed validation (2026-10-22): build-for-testing succeeded; 87 focused tests executed,
one opt-in schema regeneration test skipped, zero failures. Includes a captured approval
screen driven by the production shared clock and observation cleanup after detach.
`git diff --check` passed. No app installation or release swap was performed.
