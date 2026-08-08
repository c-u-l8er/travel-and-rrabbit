#!/usr/bin/env bash
# Build a PARKBSD golden image, end to end, from the Linux host.
#
# The image has to be assembled on FreeBSD (makefs, mkimg and pkg's -r mode are
# all FreeBSD-native), so this pushes distro/ into a running builder instance,
# builds there, streams the result back, and registers it as a golden image.
#
#   distro/make.sh [builder-instance] [config]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
BUILDER="${1:-builder}"
CONF="${2:-parkbsd.conf}"

REC="$ROOT/var/run/$BUILDER/instance.json"
[ -f "$REC" ] || { echo "no such instance: $BUILDER" >&2; exit 1; }
PORT=$(python3 -c "import json;print(json.load(open('$REC'))['ssh_port'])")
USER=$(python3 -c "import json;print(json.load(open('$REC'))['user'])")
KEY="$ROOT/var/parkvps_ed25519"
SSHOPTS=(-i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

if ! python3 "$ROOT/vpsd/vps.py" status "$BUILDER" | grep -q '"ssh_ready": true'; then
  echo "builder '$BUILDER' is not reachable over ssh; start it first" >&2
  exit 1
fi

# Read the distro identity from the config rather than assuming it, so renaming
# the distro in one file renames the artifact everywhere.
NAME=$(awk -F'"' '/^DISTRO_NAME=/{print $2}' "$HERE/$CONF")
VERSION=$(awk -F'"' '/^DISTRO_VERSION=/{print $2}' "$HERE/$CONF")
RAW="${NAME}-${VERSION}.raw"
OUT="$ROOT/var/images/${NAME}-${VERSION}.qcow2"

# A golden image is the backing file of every overlay built on it. Overwriting
# one while an instance is running corrupts that instance's view of its own
# disk, and qemu-img's write lock only catches it AFTER the whole build and
# transfer have been paid for.
if [ -f "$OUT" ]; then
  holders=()
  for rec in "$ROOT"/var/run/*/instance.json; do
    [ -f "$rec" ] || continue
    python3 - "$rec" "$(basename "$OUT")" <<'PY' && holders+=("$(basename "$(dirname "$rec")")")
import json, sys, os, errno
rec = json.load(open(sys.argv[1]))
if rec.get("golden") != sys.argv[2] or not rec.get("pid"):
    sys.exit(1)
try:
    os.kill(rec["pid"], 0)
except OSError as e:
    sys.exit(0 if e.errno == errno.EPERM else 1)
PY
  done
  if [ ${#holders[@]} -gt 0 ]; then
    echo "refusing to overwrite $(basename "$OUT"): still backing ${holders[*]}" >&2
    echo "stop or destroy those instances first" >&2
    exit 1
  fi
fi

echo "==> pushing distro/ to $BUILDER"
scp -q -P "$PORT" "${SSHOPTS[@]}" -r "$HERE" "$USER@127.0.0.1:/tmp/"

echo "==> building on $BUILDER"
ssh -p "$PORT" "${SSHOPTS[@]}" "$USER@127.0.0.1" \
    "sudo sh /tmp/distro/build-image.sh /tmp/distro/$CONF"

echo "==> streaming image back"
# Compressed in flight: the raw image is mostly zeros, so this is many times
# faster than copying it and costs one cheap gzip level.
ssh -p "$PORT" "${SSHOPTS[@]}" "$USER@127.0.0.1" \
    "sudo gzip -1 -c /var/tmp/parkbsd/$RAW" | gunzip > "$ROOT/var/images/$RAW"

echo "==> converting to qcow2"
qemu-img convert -f raw -O qcow2 "$ROOT/var/images/$RAW" "$OUT"
rm -f "$ROOT/var/images/$RAW"

echo
qemu-img info "$OUT" | grep -E 'virtual size|disk size'
echo "golden image: $OUT"
echo
echo "boot it with:"
echo "  python3 vpsd/vps.py create demo --golden $(basename "$OUT") --start"
