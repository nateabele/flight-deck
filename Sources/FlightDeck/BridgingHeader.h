// Reuses Ghostty's ObjC helper classes. Importing these headers here exposes
// their transitive Foundation/QuartzCore imports to every Swift file in the
// target -- this is how the vendored Ghostty Swift files compile without an
// explicit `import Foundation` (matching Ghostty's own bridging header).
#import "ObjCExceptionCatcher.h"
#import "VibrantLayer.h"

// libproc gives us `proc_listchildpids` and `proc_pidinfo`, which are how the session
// reaper learns which processes a tab owns. The app is not sandboxed
// (`FlightDeck.entitlements` has no `com.apple.security.app-sandbox`), so enumerating and
// signalling our own descendants needs no entitlement.
#import <libproc.h>
