# Native peer messaging implementation

1. Add hermetic transport/registry/framing/permission/idle/journal regression tests;
   record a failing run before implementation.
2. Implement the native helper and its private host pipe interface. Port protocol
   fixtures from the standalone bridge, preserving native identity and permission rules.
3. Add app-owned lifecycle/discovery/delivery, authenticated CLI requests, and bundled
   agent instructions. Isolate tests and debug builds from live account registries.
4. Verify helper footprint, native interop, targeted app tests and Release packaging.
5. Update operator docs, commit only feature changes, and activate a verified Release
   via the detached release script with rollback available.

Work is performed in an isolated worktree because the main checkout contains active
changes owned by other sessions. No concurrent user changes are incorporated or reverted.
