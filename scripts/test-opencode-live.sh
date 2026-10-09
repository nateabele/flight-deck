#!/usr/bin/env bash
# Runs OpenCodeLiveTests: the OpenCode adapter against a REAL `opencode serve`.
#
# Hermetic apart from the `opencode` binary itself: the model is scripts/opencodeprobe/fake_llm.py
# (no GPU, no network, no tokens), and OpenCode's config, data and state all live in a throwaway
# directory — your ~/.config/opencode and ~/.local/share/opencode are never read or written.
#
# Needs `opencode` (>= 1.18.0) on the login shell's PATH and python3. Takes about a minute after
# the build. Pass FD_SKIP_BUILD=1 to reuse the last build-for-testing.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d -t fd-opencode-live)"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
python3 scripts/opencodeprobe/fake_llm.py "$PORT" >"$WORK/fake-llm.log" 2>&1 &
FAKE_PID=$!
# The OpenCode server the test spawns is stopped by the test's own teardown.
cleanup() { kill "$FAKE_PID" 2>/dev/null || true; }
trap cleanup EXIT

mkdir -p "$WORK/config/opencode" "$WORK/state"
cat >"$WORK/config/opencode/opencode.json" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "provider": {
    "fake": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Fake",
      "options": { "baseURL": "http://127.0.0.1:$PORT/v1" },
      "models": { "fake-model": { "name": "fake-model", "tool_call": true } }
    }
  },
  "model": "fake/fake-model",
  "small_model": "fake/fake-model",
  "permission": { "bash": "ask", "edit": "ask" },
  "autoupdate": false
}
EOF

export XDG_CONFIG_HOME="$WORK/config"
export XDG_STATE_HOME="$WORK/state"
export FLIGHTDECK_OPENCODE_LIVE=1
FD_TEST_FILTER=OpenCodeLiveTests ./scripts/test-unit.sh
