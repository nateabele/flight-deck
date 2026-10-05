#!/bin/sh
# hostd-install.sh — installs flightdeck-hostd for the current user and prints a pairing code.
# The Add Host → Linux sheet shows the one command that runs it:
#
#   curl -fsSL <release>/hostd-install.sh | sh -s -- --sha256 <digest of SHA256SUMS>
#
# POSIX sh, no bashisms: Debian and Ubuntu run `sh` as dash, and a pasted command that dies on
# `[[` gives the user nothing to act on.
#
# Flags:
#   --sha256 DIGEST    required — the SHA-256 of this release's SHA256SUMS, from the Mac. It is
#                      the only value that did not come from the server, so it is what the
#                      download is checked against.
#   --asset-base URL   where SHA256SUMS and the tarballs live (default: the release this copy
#                      of the installer was built for).
#   --no-systemd       install the binary only: no user unit, no linger, no pairing (for
#                      containers and tests, where there is no user manager to start it).
set -eu

# Replaced by scripts/build-hostd-linux.sh with the release URL, so the pasted command needs no
# --asset-base. Left as the placeholder in the source copy, which therefore requires the flag.
ASSET_BASE='@FD_HOSTD_ASSET_BASE@'
SUMS_DIGEST=
SYSTEMD=1

say() { printf 'flightdeck: %s\n' "$*"; }
die() { printf 'flightdeck: %s\n' "$*" >&2; exit "${2:-1}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --sha256) [ $# -ge 2 ] || die "--sha256 needs a digest" 64; SUMS_DIGEST=$2; shift 2 ;;
    --asset-base) [ $# -ge 2 ] || die "--asset-base needs a URL" 64; ASSET_BASE=$2; shift 2 ;;
    --no-systemd) SYSTEMD=0; shift ;;
    *) die "unknown option $1" 64 ;;
  esac
done
# No digest means nothing to check the download against, so nothing is installed: running an
# unchecked binary is exactly what the digest exists to prevent.
[ -n "$SUMS_DIGEST" ] || die "--sha256 is required (copy the command from Flight Deck)" 64
case "$ASSET_BASE" in
  @*) die "--asset-base is required for an unreleased installer" 64 ;;
esac
ASSET_BASE=${ASSET_BASE%/}

case "$(uname -m)" in
  x86_64 | amd64) ARCH=x86_64 ;;
  aarch64 | arm64) ARCH=aarch64 ;;
  *) die "unsupported architecture $(uname -m) (x86_64 and aarch64 are built)" ;;
esac
TARBALL=flightdeck-hostd-linux-$ARCH.tar.gz

fetch() {
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2"
  elif command -v wget >/dev/null 2>&1; then wget -qO "$2" "$1"
  else die "needs curl or wget"
  fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

# Everything is downloaded and checked here, in a scratch directory, before ~/.local is touched,
# so a mismatch leaves no binary, no unit and no half-written install behind.
fetch "$ASSET_BASE/SHA256SUMS" SHA256SUMS || die "could not download $ASSET_BASE/SHA256SUMS"
[ "$(sha256sum SHA256SUMS | cut -d' ' -f1)" = "$SUMS_DIGEST" ] ||
  die "checksum mismatch — refusing to install"
fetch "$ASSET_BASE/$TARBALL" "$TARBALL" || die "could not download $ASSET_BASE/$TARBALL"
# Only this architecture's line: `sha256sum -c` over the whole file would fail on the other
# tarball, which was never downloaded.
grep "  $TARBALL\$" SHA256SUMS > want || die "SHA256SUMS has no entry for $TARBALL"
sha256sum -c --status want || die "checksum mismatch — refusing to install"
tar -xzf "$TARBALL" flightdeck-hostd

BIN_DIR=$HOME/.local/bin
BIN=$BIN_DIR/flightdeck-hostd
mkdir -p "$BIN_DIR"
# Copied beside the target and renamed over it, not written in place: overwriting the
# executable of a running hostd fails with "Text file busy", and a rename also means a crash
# mid-copy can never leave a truncated binary where the unit will start it.
cp flightdeck-hostd "$BIN.new"
chmod 755 "$BIN.new"
mv -f "$BIN.new" "$BIN"
say "installed $BIN"

if [ "$SYSTEMD" = 0 ]; then
  say "start it with: $BIN serve — then run: $BIN pair"
  exit 0
fi

UNIT_DIR=$HOME/.config/systemd/user
mkdir -p "$UNIT_DIR"
# The unit runs the plain `serve` and sets no environment: the test flag that unlocks
# --test-controller installs a key nobody paired, and scripts/test-hostd-install.sh fails if its
# name appears anywhere in this file.
cat > "$UNIT_DIR/flightdeck-hostd.service" <<'UNIT'
[Unit]
Description=Flight Deck host (flightdeck-hostd)

[Service]
ExecStart=%h/.local/bin/flightdeck-hostd serve
Restart=on-failure

[Install]
WantedBy=default.target
UNIT

systemctl --user daemon-reload ||
  die "could not reach your systemd user manager; re-run with --no-systemd and start '$BIN serve' yourself"
systemctl --user enable --now flightdeck-hostd
# `enable --now` leaves an already-running hostd alone, so a reinstall would keep serving the
# old binary until the next login without this.
systemctl --user restart flightdeck-hostd
ME=${USER:-$(id -un)}
# Without linger the user manager, and the hostd with it, stops when the last session logs out.
# Some hosts forbid it to unprivileged users; the host still works while someone is logged in.
loginctl enable-linger "$ME" 2>/dev/null ||
  say "could not enable linger, so the host stops when you log out (ask an admin: loginctl enable-linger $ME)"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) say "$BIN_DIR is not on your PATH; add it to run flightdeck-hostd by name" ;;
esac

# The unit was just (re)started, and `pair` exits 2 until its admin socket is up, so wait for
# that rather than reporting a hostd that is merely still starting as not running.
tries=0
while :; do
  rc=0
  "$BIN" status >/dev/null 2>&1 || rc=$?
  [ "$rc" != 2 ] && break
  tries=$((tries + 1))
  [ "$tries" -lt 15 ] || die "flightdeck-hostd did not start; see: journalctl --user -u flightdeck-hostd" 2
  sleep 1
done

# The scratch directory goes now, because exec replaces this shell and its EXIT trap with it.
cd /
rm -rf "$TMP"
trap - EXIT
# In the foreground, last: its "Pairing code:" line is what the user types into the Mac, and
# its exit status (0 paired, 1 expired) is the installer's.
exec "$BIN" pair
