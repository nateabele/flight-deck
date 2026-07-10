// Reuses Ghostty's ObjC helper classes. Importing these headers here exposes
// their transitive Foundation/QuartzCore imports to every Swift file in the
// target -- this is how the vendored Ghostty Swift files compile without an
// explicit `import Foundation` (matching Ghostty's own bridging header).
#import "ObjCExceptionCatcher.h"
#import "VibrantLayer.h"
