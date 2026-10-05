#!/usr/bin/env bash
# scripts/test-hostd-install.sh — the pasted command, end to end, in a plain Ubuntu container,
# served from a local HTTP server so nothing is published. Ends "INSTALL PASS".
#
# aarch64 only: it runs natively here, and the x86_64 asset differs only in the arch the build
# was given. FD_HOSTD_SKIP_BUILD=1 reuses build/hostd-release as it is.
#
# Every step in the container runs under `set -e`, so a check that fails stops the run: without
# it, only the last command's status would reach `docker run`, and a broken install that ends
# with an expected refusal would still pass.
set -euo pipefail
cd "$(dirname "$0")/.."
[ "${FD_HOSTD_SKIP_BUILD:-}" = 1 ] || ./scripts/build-hostd-linux.sh aarch64
SUMS=$(shasum -a 256 build/hostd-release/SHA256SUMS | cut -d' ' -f1)
docker run --rm --platform linux/arm64 -e SUMS="$SUMS" -v "$PWD/build/hostd-release:/rel:ro" \
  ubuntu:24.04 bash -euo pipefail -c '
  apt-get update -qq && apt-get install -y -qq curl python3 >/dev/null
  (cd /rel && python3 -m http.server 8000 >/dev/null 2>&1 &)
  until curl -fsS -o /dev/null 2>/dev/null http://127.0.0.1:8000/SHA256SUMS; do sleep 0.2; done

  # FD_HOSTD_TEST=1 unlocks --test-controller, which installs a key nobody paired; neither the
  # installer nor the unit it writes may ever set it. An `if`, not `! grep`: set -e ignores a
  # negated command, so `! grep` could never fail the run.
  if grep -n FD_HOSTD_TEST /rel/hostd-install.sh; then exit 1; fi

  useradd -m dev
  useradd -m fresh
  # su without `-` keeps SUMS and sets HOME to the target user, which is what `~` needs.
  su dev -c "bash -euo pipefail" <<"DEV"
    B=http://127.0.0.1:8000
    # 1. The pasted form, binary only.
    curl -fsSL $B/hostd-install.sh | sh -s -- --sha256 "$SUMS" --asset-base $B --no-systemd
    test "$(stat -c %a ~/.local/bin/flightdeck-hostd)" = 755
    # The help names the installed command, the one the Mac tells the user to type.
    usage=$(~/.local/bin/flightdeck-hostd 2>&1 || true)
    grep -q "usage: flightdeck-hostd serve" <<<"$usage"
    if grep -n HostDaemonLinux <<<"$usage"; then exit 1; fi

    # 2. It serves and pairs.
    ~/.local/bin/flightdeck-hostd serve --port 47410 </dev/null >~/serve.log 2>&1 &
    for _ in $(seq 50); do grep -q "listening on 47410" ~/serve.log && break; sleep 0.2; done
    grep -q "listening on 47410" ~/serve.log
    out=$(timeout 5 ~/.local/bin/flightdeck-hostd pair </dev/null || true)
    grep -q "Pairing code:" <<<"$out"
    test "$(stat -c %a ~/.local/share/flightdeck-hostd)" = 700

    # 3. The systemd path, against stubs (the container has no user manager): the unit, the
    #    linger note when loginctl refuses, and the pair it ends in. Run from a file so timeout
    #    signals the pair that the installer execs, not a pipeline shell that would orphan it.
    mkdir ~/stub
    printf "#!/bin/sh\necho \"\$*\" >> ~/systemctl.log\n" > ~/stub/systemctl
    printf "#!/bin/sh\nexit 1\n" > ~/stub/loginctl
    chmod +x ~/stub/*
    curl -fsSL $B/hostd-install.sh -o ~/install.sh
    rc=0
    PATH=~/stub:$PATH timeout 6 sh ~/install.sh --sha256 "$SUMS" --asset-base $B >~/install.log 2>&1 || rc=$?
    cat ~/install.log
    [ $rc = 124 ]   # still waiting on the pairing code, as it should be
    grep -q "Pairing code:" ~/install.log
    grep -q "host stops when you log out" ~/install.log
    unit=~/.config/systemd/user/flightdeck-hostd.service
    grep -qx "ExecStart=%h/.local/bin/flightdeck-hostd serve" $unit
    grep -qx "Restart=on-failure" $unit
    grep -qx "WantedBy=default.target" $unit
    if grep -n FD_HOSTD_TEST $unit; then exit 1; fi
    grep -qx -- "--user daemon-reload" ~/systemctl.log
    grep -qx -- "--user enable --now flightdeck-hostd" ~/systemctl.log
DEV

  # 4. A wrong digest refuses before anything is installed, in a home with no prior install.
  su fresh -c "bash -euo pipefail" <<"FRESH"
    rc=0
    out=$(curl -fsSL http://127.0.0.1:8000/hostd-install.sh |
      sh -s -- --sha256 0000 --asset-base http://127.0.0.1:8000 --no-systemd 2>&1) || rc=$?
    echo "$out"
    [ $rc = 1 ]
    grep -qx "flightdeck: checksum mismatch — refusing to install" <<<"$out"
    test ! -e ~/.local
FRESH
'
echo "INSTALL PASS"
