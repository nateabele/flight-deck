# Codex sub-agent count implementation

1. Check the installed Codex schema for ancestry, collaboration states and pagination.
2. Add pure count-fold regressions and prove a failing spawn/count case before implementing.
3. Connect native notifications and complete descendant snapshots to the runtime's existing
   status cadence, preserving attachment isolation, cancellation and writer ownership.
4. Add integration coverage for restore, pagination, detach and count replay.
5. In parallel, enable the shared Codex summary and singular/plural tests.
6. Run focused tests, review the changes and update the adapter architecture documentation.

## Validation so far

- Installed Codex 0.164.0 schema confirms descendant filters, parent IDs and native
  collaboration states. A read-only live audit queried four existing roots (31 stored
  descendants); list statuses agreed with individual metadata reads.
- Summary RED: 8 tests, two failures. Runtime snapshot RED: 6 tests, four failures.
- Review regressions RED: 7 tests, two failures (repeated completion freshness and an
  unloaded parent with a newer active child). Both corrected; review found no blockers.
- Focused runtime/fleet suite: 84 tests passed. iOS framework, mobile app and test bundles
  compile successfully. An unloaded parent no longer clears its children: only their
  completed metadata snapshot can do that, and no resume is issued for an unloaded parent.

## Complete

Final focused run: 100 tests passed, zero failures, including the waiting badge regression
(confirmed RED before fixing), native notification counts, complete and partial pagination,
reconnect/restore, late attachment, fresh-event precedence, provider filters and fleet
projection. The iOS framework, companion and test bundles built successfully. Independent
review found no remaining blockers in tracking, snapshot races or count-only presentation.
