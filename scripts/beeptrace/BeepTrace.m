// Finds out which tests make the macOS "you can't do that" beep. Opt-in: FD_TRACE_BEEPS=1 on
// test-unit.sh / smoke.sh (docs/AGENT-OPERATIONS.md §5) inserts this dylib into every xctest
// shard, the menu-bar harness, and the app under test.
//
// It interposes NSBeep and the AudioServices alert calls under it (dyld __DATA,__interpose),
// where NSSound.beep() and every AppKit "can't do that" path (noResponder(for:), a rejected key,
// a disabled menu item) end up. Each process appends a LOAD line to $FD_BEEP_LOG when it starts,
// and each beep a BEEP record: time, pid, process, the test case XCTest is running (an
// XCTestObservation observer keeps it) and a symbolicated backtrace. Then it calls through, so
// behaviour is unchanged.
//
// fd_beep_count() is the number of beeps this process has made, for a test that wants to assert
// "no beep" while traced; dlsym(RTLD_DEFAULT, "fd_beep_count") is NULL when it is not.
//
// Built by scripts/beeptrace/build.sh; never part of the app or its bundle.
#import <AppKit/AppKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <unistd.h>

static atomic_long gCount;
static NSString *volatile gCurrentTest;   // "-[Class test]", nil outside a test case
static int gLogFD = -1;

long fd_beep_count(void) { return atomic_load(&gCount); }

// A beep is one call with several layers under it (+[NSSound beep] -> NSBeep ->
// AudioServicesPlayAlertSound...), and AppKit's own calls to its own NSBeep are not interposable,
// so each layer is hooked and only the outermost one on a thread is recorded.
static __thread int gDepth;

static NSString *stamp(void) {
    static NSDateFormatter *f;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ f = [NSDateFormatter new]; f.dateFormat = @"HH:mm:ss.SSS"; });
    return [f stringFromDate:[NSDate date]];
}

static void put(NSString *line) {
    const char *bytes = line.UTF8String;
    if (gLogFD >= 0) write(gLogFD, bytes, strlen(bytes));   // one write: O_APPEND keeps shards' records whole
}

static void record(const char *via) {
    atomic_fetch_add(&gCount, 1);
    @autoreleasepool {
        NSString *test = gCurrentTest ?: @"(no test running)";
        NSArray *stack = NSThread.callStackSymbols;   // minus the tracer's own two frames; the top 30 reach the test
        stack = [stack subarrayWithRange:NSMakeRange(MIN(2, stack.count), MIN(30, stack.count - MIN(2, stack.count)))];
        NSString *entry = [NSString stringWithFormat:@"BEEP %@ pid=%d proc=%@ via=%s test=%@\n%@\n\n",
            stamp(), getpid(), NSProcessInfo.processInfo.processName, via, test,
            [stack componentsJoinedByString:@"\n"]];
        put(entry);
    }
}

// <mach-o/dyld-interposing.h> is not in the SDK; INTERPOSE is its macro's expansion.
#define INTERPOSE(replacement, replacee)                                                         \
    __attribute__((used)) static const struct { const void *r; const void *e; }                  \
        interpose_##replacee __attribute__((section("__DATA,__interpose"))) =                    \
        { (const void *)replacement, (const void *)replacee };

#define HOOK(name, params, args)                                                 \
    static void fd_##name params {                                               \
        if (gDepth++ == 0) record(#name);                                        \
        name args;                                                               \
        gDepth--;                                                                \
    }                                                                            \
    INTERPOSE(fd_##name, name)

static void fd_NSBeep(void) {
    if (gDepth++ == 0) record("NSBeep");
    NSBeep();   // interposing leaves the interposer's own calls going to the real function
    gDepth--;
}
INTERPOSE(fd_NSBeep, NSBeep)

HOOK(AudioServicesPlayAlertSound, (SystemSoundID s), (s))
HOOK(AudioServicesPlaySystemSound, (SystemSoundID s), (s))
HOOK(AudioServicesPlayAlertSoundWithCompletion, (SystemSoundID s, void (^c)(void)), (s, c))
HOOK(AudioServicesPlaySystemSoundWithCompletion, (SystemSoundID s, void (^c)(void)), (s, c))

@interface FDBeepObserver : NSObject
@end
@implementation FDBeepObserver
// CASE lines let report.py name the test behind a beep made in ANOTHER process: the app under
// test has no XCTest, but the runner does, and both stamp the same clock.
- (void)testCaseWillStart:(id)testCase {
    gCurrentTest = [testCase performSelector:@selector(name)];
    put([NSString stringWithFormat:@"CASE %@ pid=%d start %@\n", stamp(), getpid(), gCurrentTest]);
}
- (void)testCaseDidFinish:(id)testCase {
    put([NSString stringWithFormat:@"CASE %@ pid=%d end %@\n", stamp(), getpid(), gCurrentTest]);
    gCurrentTest = nil;
}
@end

// XCTest is not loaded yet when this dylib's constructor runs, so the observer is added from the
// image callback for XCTestCore. The callback runs for every image any thread loads, in the app
// under test too, so until then it does a string compare and nothing else.
static void imageAdded(const struct mach_header *mh, intptr_t slide) {
    static BOOL registered;
    Dl_info info;
    if (registered || !dladdr(mh, &info) || !strstr(info.dli_fname, "/XCTestCore.framework/")) return;
    Class center = NSClassFromString(@"XCTestObservationCenter");
    Protocol *observation = NSProtocolFromString(@"XCTestObservation");
    if (!center || !observation) return;
    class_addProtocol([FDBeepObserver class], observation);   // addTestObserver: checks conformance
    registered = YES;
    id shared = [center performSelector:NSSelectorFromString(@"sharedTestObservationCenter")];
    [shared performSelector:NSSelectorFromString(@"addTestObserver:") withObject:[FDBeepObserver new]];
}

__attribute__((constructor)) static void init(void) {
    const char *path = getenv("FD_BEEP_LOG");
    gLogFD = open(path ? path : "/tmp/fd-beeps.log", O_WRONLY | O_APPEND | O_CREAT, 0644);
    // Not inherited: the shells, git and node the app or a test spawns have no use for it.
    unsetenv("DYLD_INSERT_LIBRARIES");
    // A LOAD line per process, so a log with no BEEP lines is proof the tracer was in them.
    put([NSString stringWithFormat:@"LOAD pid=%d proc=%@\n", getpid(), NSProcessInfo.processInfo.processName]);
    _dyld_register_func_for_add_image(imageAdded);
}
