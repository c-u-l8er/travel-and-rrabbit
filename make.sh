#!/usr/bin/env bash
# Build a T&R golden image, end to end, from a Linux (or any) host.
#
# The image has to be ASSEMBLED ON FreeBSD -- makefs, mkimg and pkg's -r mode
# are all FreeBSD-native -- so this pushes the tree into a FreeBSD builder over
# ssh, builds there, and streams the result back.
#
#   ./make.sh [config] [builder]
#
# The builder is any reachable FreeBSD 15 machine with pkg and ~8 GB free:
#
#   BUILDER_SSH=root@10.0.0.5 ./make.sh tandr-desktop.conf
#   BUILDER_SSH=park@127.0.0.1:2222 BUILDER_KEY=~/.ssh/id_ed25519 ./make.sh
#
# If PARKVPS is alongside (../PARKVPS, or PARKVPS_ROOT=...), a named instance
# from its fleet is used instead and none of the above is needed:
#
#   ./make.sh tandr-desktop.conf builder
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${1:-tandr.conf}"
BUILDER="${2:-builder}"
OUT_DIR="${OUT_DIR:-$HERE/images}"
[ -r "$HERE/$CONF" ] || { echo "no such config: $HERE/$CONF" >&2; exit 1; }

#--------------------------------------------------------------- find a builder
# Two ways in, and the explicit one wins. PARKVPS is a convenience, not a
# dependency: this repo builds an operating system and should not require a
# particular hypervisor to do it.
KEYOPT=()
if [ -n "${BUILDER_SSH:-}" ]; then
  SSH_USER="${BUILDER_SSH%@*}"
  hostport="${BUILDER_SSH#*@}"
  SSH_HOST="${hostport%:*}"
  SSH_PORT="22"
  [ "$hostport" != "${hostport#*:}" ] && SSH_PORT="${hostport##*:}"
  [ -n "${BUILDER_KEY:-}" ] && KEYOPT=(-i "$BUILDER_KEY")
else
  PARKVPS="${PARKVPS_ROOT:-$(dirname "$HERE")/PARKVPS}"
  REC="$PARKVPS/var/run/$BUILDER/instance.json"
  if [ ! -f "$REC" ]; then
    echo "No builder. Either set BUILDER_SSH=user@host[:port] for any FreeBSD" >&2
    echo "machine, or put PARKVPS alongside this repo and name one of its" >&2
    echo "instances (looked for $REC)." >&2
    exit 1
  fi
  SSH_HOST=127.0.0.1
  SSH_PORT=$(python3 -c "import json;print(json.load(open('$REC'))['ssh_port'])")
  SSH_USER=$(python3 -c "import json;print(json.load(open('$REC'))['user'])")
  KEYOPT=(-i "$PARKVPS/var/parkvps_ed25519")
  if ! python3 "$PARKVPS/vpsd/vps.py" status "$BUILDER" | grep -q '"ssh_ready": true'; then
    echo "builder '$BUILDER' is not reachable over ssh; start it first" >&2
    exit 1
  fi
fi
SSHOPTS=("${KEYOPT[@]}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
         -o LogLevel=ERROR)

#-------------------------------------------------------------------- identity
# The SLUG, not the display name: the display name is "T&R" and an ampersand in
# a filename needs quoting in every command that touches it.
SLUG=$(awk -F'"' '/^DISTRO_SLUG=/{print $2}' "$HERE/$CONF")
VERSION=$(awk -F'"' '/^DISTRO_VERSION=/{print $2}' "$HERE/$CONF")
RAW="${SLUG}-${VERSION}.raw"
OUT="$OUT_DIR/${SLUG}-${VERSION}.qcow2"
mkdir -p "$OUT_DIR"

# A golden image is the backing file of every overlay built on it. Overwriting
# one while a VM is running corrupts that VM's view of its own disk, and
# qemu-img's write lock only catches it AFTER the whole build and transfer have
# been paid for. Only checkable when PARKVPS is the one running them.
if [ -f "$OUT" ] && [ -z "${BUILDER_SSH:-}" ] && [ -d "${PARKVPS:-/nonexistent}/var/run" ]; then
  holders=()
  for rec in "$PARKVPS"/var/run/*/instance.json; do
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
    exit 1
  fi
fi

echo "==> pushing tree to $SSH_USER@$SSH_HOST:$SSH_PORT"
ssh -p "$SSH_PORT" "${SSHOPTS[@]}" "$SSH_USER@$SSH_HOST" 'rm -rf /tmp/tandr'
scp -q -P "$SSH_PORT" "${SSHOPTS[@]}" -r "$HERE" "$SSH_USER@$SSH_HOST:/tmp/tandr"

echo "==> building"
ssh -p "$SSH_PORT" "${SSHOPTS[@]}" "$SSH_USER@$SSH_HOST" \
    "sudo sh /tmp/tandr/build-image.sh /tmp/tandr/$CONF"

echo "==> streaming image back"
# Compressed in flight: the raw image is mostly zeros, so this is many times
# faster than copying it and costs one cheap gzip level.
ssh -p "$SSH_PORT" "${SSHOPTS[@]}" "$SSH_USER@$SSH_HOST" \
    "sudo gzip -1 -c /var/tmp/tandr/$RAW" | gunzip > "$OUT_DIR/$RAW"

if command -v qemu-img >/dev/null; then
  echo "==> converting to qcow2"
  qemu-img convert -f raw -O qcow2 "$OUT_DIR/$RAW" "$OUT"
  rm -f "$OUT_DIR/$RAW"
  qemu-img info "$OUT" | grep -E 'virtual size|disk size'
  echo "golden image: $OUT"
else
  echo "raw image: $OUT_DIR/$RAW  (no qemu-img here; convert it where you run it)"
fi
