#!/usr/bin/env python3
"""Rewrite an .xctestrun so the UI tests run on a Mac with an OLDER Xcode. Used by smoke-remote.sh.

    patch-xctestrun.py <in.xctestrun> <out.xctestrun> [NAME=VALUE ...]

The bundle is built here, with this Mac's Xcode, but run by `xcodebuild test-without-building`
on the UI-test Mac, whose Xcode can be older. The xctestrun this Mac writes resolves XCTest
through `__SHAREDFRAMEWORKS__` and `__PLATFORMS__`, which the REMOTE xcodebuild expands to ITS
Xcode, so the runner, built against this Xcode's XCTest, loads the remote's older copy and dies
before any test runs:

    Symbol not found: …typeKey…  in …/SharedFrameworks/XCTest.framework

smoke-remote.sh ships this Xcode's test frameworks next to the products as `xctest26/`, and this
script points every DYLD search path at that copy instead. It drops the paths themselves, not
just their order, because a remote framework found first would still win. Without `xctest26/`
on the library path the failure is `Library not loaded: @rpath/lib_TestingInterop.dylib`.

The Main Thread Checker insert goes too. It comes from `__DEVELOPERUSRLIB__`, the remote Xcode
again, and is built against that Xcode's XCTest, which is the mismatch this script exists to
remove.

Only the UI-test target is kept, so a remote run cannot also try to run the unit bundle, which
is hosted by the app and needs this Mac's state.

Each NAME=VALUE goes into the UI-test runner's environment. `xcodebuild` forwards a caller's
`TEST_RUNNER_*` variables to the runner (prefix stripped) only from its OWN environment, and the
remote xcodebuild's environment is an ssh session's, so a flake-hunt gate set on this Mac would
otherwise never arrive and its case would silently SKIP. The caller strips the prefix.

Handles both xctestrun layouts: FormatVersion 1 keys targets at the top level, 2 nests them
under TestConfigurations.
"""
import plistlib
import sys

UI_TARGET = "FlightDeckUITests"
SHIM = "__TESTROOT__/xctest26"


def remote_safe(paths):
    """Drops every entry that resolves inside the remote Xcode."""
    return [p for p in paths.split(":") if p and not p.startswith(("__SHAREDFRAMEWORKS__", "__PLATFORMS__", "__DEVELOPERUSRLIB__"))]


def patch_target(target, extra):
    env = target.setdefault("TestingEnvironmentVariables", {})
    env["DYLD_FRAMEWORK_PATH"] = ":".join(
        remote_safe(env.get("DYLD_FRAMEWORK_PATH", "")) + ["__TESTHOST__/Contents/Frameworks", SHIM]
    )
    env["DYLD_LIBRARY_PATH"] = ":".join(
        remote_safe(env.get("DYLD_LIBRARY_PATH", "")) + ["__TESTHOST__/Contents/Frameworks", SHIM]
    )
    inserts = [p for p in remote_safe(env.get("DYLD_INSERT_LIBRARIES", "")) if "MainThreadChecker" not in p]
    if inserts:
        env["DYLD_INSERT_LIBRARIES"] = ":".join(inserts)
    else:
        env.pop("DYLD_INSERT_LIBRARIES", None)
    target.setdefault("EnvironmentVariables", {}).update(extra)
    env.update(extra)


def main():
    src, dst, *pairs = sys.argv[1:]
    extra = dict(pair.split("=", 1) for pair in pairs)
    with open(src, "rb") as f:
        run = plistlib.load(f)

    patched = 0
    if "TestConfigurations" in run:
        for config in run["TestConfigurations"]:
            config["TestTargets"] = [t for t in config["TestTargets"] if t.get("BlueprintName") == UI_TARGET]
            for target in config["TestTargets"]:
                patch_target(target, extra)
                patched += 1
    else:
        for key in [k for k in run if not k.startswith("__") and k != UI_TARGET]:
            del run[key]
        if UI_TARGET in run:
            patch_target(run[UI_TARGET], extra)
            patched += 1

    # A silent no-op would ship an unpatched file and fail remotely with the XCTest symbol error
    # above, which names neither this script nor the missing target.
    if patched == 0:
        sys.exit(f"patch-xctestrun: no {UI_TARGET} target in {src}")
    with open(dst, "wb") as f:
        plistlib.dump(run, f)


if __name__ == "__main__":
    main()
