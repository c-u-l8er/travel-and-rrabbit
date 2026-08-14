#!/bin/sh
# Push overlay-desktop/ changes into a RUNNING guest, instead of rebuilding the
# image to see them.
#
# `overlay-desktop/` maps 1:1 onto the guest's filesystem -- overlay-desktop/foo
# IS /foo in the image -- so updating a running machine is a file copy, and the
# only real question is WHICH files actually differ.
#
#   ./sync-overlay.sh                       # report differences, change nothing
#   ./sync-overlay.sh /usr/local/share/...  # push exactly these paths
#   ./sync-overlay.sh --all                 # push everything that differs
#
#   SSH_PORT=2224 ./sync-overlay.sh         # default; tandr-preview's hostfwd
#   SSH_USER=park SSH_KEY=../PARKVPS/var/parkvps_ed25519 ./sync-overlay.sh
#
# REPORTING IS THE DEFAULT ON PURPOSE. A guest accumulates hand edits that were
# never carried back here -- on 2026-08-13 the running tandr-preview had a
# `rrabbit-session` that started the compositor-proxy and this overlay's copy
# did not, so a blind push would have silently switched native windows back off.
# Look at the list before you push it, and carry the guest's side back into the
# overlay when the guest is the one that is right.
#
# Every file it touches is backed up in the guest as <file>.bak first.
set -eu

SSH_PORT=${SSH_PORT:-2224}
SSH_USER=${SSH_USER:-park}
SSH_KEY=${SSH_KEY:-$(cd "$(dirname "$0")/../PARKVPS/var" 2>/dev/null && pwd)/parkvps_ed25519}
SSH_HOST=${SSH_HOST:-127.0.0.1}
OVERLAY=$(cd "$(dirname "$0")" && pwd)/overlay-desktop

[ -d "$OVERLAY" ] || { echo "!!! no overlay-desktop beside this script" >&2; exit 1; }
[ -f "$SSH_KEY" ] || { echo "!!! no ssh key at $SSH_KEY -- set SSH_KEY" >&2; exit 1; }

SSH="ssh -p $SSH_PORT -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
SCP="scp -P $SSH_PORT -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
TARGET="$SSH_USER@$SSH_HOST"

$SSH "$TARGET" true 2>/dev/null || { echo "!!! cannot reach $TARGET:$SSH_PORT" >&2; exit 1; }

push_one() {
    guest=$1
    local_file="$OVERLAY$guest"
    dir=$(dirname "$guest")
    base=$(basename "$guest")
    echo "==> $guest"
    $SSH "$TARGET" "sudo mkdir -p '$dir'; [ -f '$guest' ] && sudo cp '$guest' '$guest.bak' || true"
    $SCP "$local_file" "$TARGET:/tmp/.sync-$base" >/dev/null
    $SSH "$TARGET" "sudo cp '/tmp/.sync-$base' '$guest' && sudo chmod --reference='$guest.bak' '$guest' 2>/dev/null || true; rm -f '/tmp/.sync-$base'"
}

# Explicit paths: push those, nothing else, no questions.
if [ $# -gt 0 ] && [ "$1" != "--all" ]; then
    for guest in "$@"; do
        [ -f "$OVERLAY$guest" ] || { echo "!!! not in the overlay: $guest" >&2; exit 1; }
        push_one "$guest"
    done
    echo "Done. A greeter or session change applies at the next LOGOUT, not now."
    exit 0
fi

differs=""
for local_file in $(find "$OVERLAY" -type f); do
    guest=${local_file#"$OVERLAY"}
    here=$(md5sum "$local_file" | cut -d' ' -f1)
    there=$($SSH "$TARGET" "md5 -q '$guest' 2>/dev/null" 2>/dev/null || true)
    if [ "$here" != "$there" ]; then
        differs="$differs $guest"
        printf '  %-58s %s\n' "$guest" "${there:-MISSING IN GUEST}"
    fi
done

if [ -z "$differs" ]; then
    echo "Guest matches the overlay."
    exit 0
fi

if [ "${1:-}" = "--all" ]; then
    for guest in $differs; do push_one "$guest"; done
    echo "Done. A greeter or session change applies at the next LOGOUT, not now."
else
    echo
    echo "Reporting only. Push with:  $0 --all"
    echo "or name the paths:          $0$differs"
fi
