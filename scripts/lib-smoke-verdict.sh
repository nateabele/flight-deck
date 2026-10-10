# Sourced by scripts/smoke-remote.sh: turns a successful xcodebuild test log into the run's
# verdict. Kept apart so SmokeVerdictScriptTests can drive it with synthetic logs.
#
# Why it exists: every Flight Control UI class is gated on a TEST_RUNNER_* variable and throws
# XCTSkip without it, and xcodebuild counts a skipped case as a success. A run of those classes
# with the gate unset therefore ended "SMOKE PASS" having run nothing — and that pass was once
# reported as the classes passing. A selected class that skipped everything is now its own,
# non-success verdict.
#
#   smoke_verdict <run.log> <FD_UITEST_ONLY identifiers...>
#
# Prints the passed/failed/skipped counts, then one of:
#   SMOKE PASS     at least one selected case ran, or this is the whole-suite smoke
#                  (identifier `FlightDeckUITests`), whose gated classes are SUPPOSED to skip
#   SMOKE SKIPPED  named classes or cases were selected and none of them ran: exit status 5,
#                  which every wrapper passes through as a failure
# Only called when xcodebuild itself succeeded; a failing run never reaches it.
SMOKE_SKIPPED_STATUS=5

smoke_verdict() {
  local log=$1; shift
  local passed failed skipped selective=0 id
  passed=$(grep -cE "^Test Case '.*' passed" "$log" 2>/dev/null) || passed=0
  failed=$(grep -cE "^Test Case '.*' failed" "$log" 2>/dev/null) || failed=0
  skipped=$(grep -cE "^Test Case '.*' skipped" "$log" 2>/dev/null) || skipped=0
  echo "[smoke] tests: $passed passed, $failed failed, $skipped skipped"
  # A `/` means a class or a case was named. The bare bundle is the whole-suite smoke, where
  # the gated classes skipping is the expected outcome and the ungated groups are what ran.
  for id in "$@"; do
    case "$id" in */*) selective=1 ;; esac
  done
  if [ "$selective" -eq 1 ] && [ $((passed + failed)) -eq 0 ]; then
    echo "SMOKE SKIPPED — every selected test was skipped (or none matched $*)."
    echo "            A skipped case proves nothing: set the class's TEST_RUNNER_* gate."
    return "$SMOKE_SKIPPED_STATUS"
  fi
  echo "SMOKE PASS"
}
