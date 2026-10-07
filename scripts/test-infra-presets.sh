#!/usr/bin/env bash
# scripts/test-infra-presets.sh — `tofu test` for each bundled preset against mock providers.
# No credentials and no cloud calls: mock_provider replaces every provider. `tofu init` does
# download the providers pinned in each preset's .terraform.lock.hcl (read-only registry
# traffic; the mocks still need the real provider schema to type-check the module).
#
# Each preset is tested in a copy under build/, never in place: Resources/Infra is a folder
# reference in project.yml, so a `.terraform/` left beside a preset (hundreds of MB of
# provider binaries) would be copied into every app bundle. `-lockfile=readonly` makes a
# preset whose constraints have drifted from its committed lock file fail here, rather than
# silently re-resolve on a user's Mac.
set -euo pipefail
cd "$(dirname "$0")/.."
TOFU=${TOFU:-$(command -v tofu || true)}
[ -n "$TOFU" ] || { echo "tofu not found (brew install opentofu, or TOFU=/path)"; exit 2; }
work=build/infra-presets
export TF_PLUGIN_CACHE_DIR="$PWD/$work/plugin-cache"
mkdir -p "$TF_PLUGIN_CACHE_DIR"
for p in Resources/Infra/presets/*/; do
  name=$(basename "$p")
  echo "== $name"
  rm -rf "${work:?}/$name" && cp -R "$p" "$work/$name"
  (cd "$work/$name" && "$TOFU" init -backend=false -input=false -lockfile=readonly >/dev/null && "$TOFU" test -no-color)
done
echo "PRESETS PASS"
