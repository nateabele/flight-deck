// The macOS host's Darwin-only half (track C3 fills it): the IOKit idle- and display-sleep
// assertions a run holds (§6.1, §6.3), and the console-user and screen-lock checks
// (`CGSessionCopyCurrentDictionary`) the screen preflight reads.
//
// Everything in this target sits inside `#if os(macOS)`. On Linux the target is still built
// (the manifest cannot drop a target per platform without a conditional manifest), so it must
// compile to an empty module there; an unguarded `import IOKit` would break the Linux hostd
// build that `scripts/test-hostkit.sh` runs.
#if os(macOS)
import CoreGraphics
import HostKit
import IOKit
#endif
