#!/bin/sh
# PARKBSD image assembler. Runs INSIDE a FreeBSD builder VM, as root.
#
# Assembles a bootable UEFI disk image from pkgbase packages -- no source tree,
# no buildworld, no release tarballs. This is the NomadBSD approach updated for
# FreeBSD 15: because the base system is now shipped as ~509 packages, building
# a root filesystem is `pkg -r <dir> install`, and the rest is filesystem
# plumbing.
#
#   build-image.sh [config]      default: ./parkbsd.conf
#
# Produces: <workdir>/<NAME>-<VERSION>.raw
set -eu

HERE=$(dirname "$0")
CONF="${1-}"
[ -n "$CONF" ] || CONF="$HERE/parkbsd.conf"
[ -r "$CONF" ] || { echo "no such config: $CONF" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"

[ "$(id -u)" -eq 0 ] || { echo "must run as root (try: sudo $0 $*)" >&2; exit 1; }

WORK="${WORK:-/var/tmp/parkbsd}"
STAGE="$WORK/root"
ESPDIR="$WORK/esp"
IMG="$WORK/${DISTRO_NAME}-${DISTRO_VERSION}.raw"
LABEL="$(echo "$DISTRO_NAME" | tr '[:upper:]' '[:lower:]')root"

echo "==> $DISTRO_NAME $DISTRO_VERSION ($DISTRO_CODENAME) from FreeBSD $FREEBSD_MAJOR pkgbase"
# FreeBSD sets the system-immutable flag on parts of base (/sbin/init,
# /var/empty among them), so a plain `rm -rf` of a staged root fails with
# "Operation not permitted" and leaves a half-deleted tree that the next build
# then layers on top of. Clear the flags first.
if [ -d "$WORK" ]; then
  chflags -R noschg "$WORK" 2>/dev/null || true
  rm -rf "$WORK"
fi
mkdir -p "$STAGE" "$ESPDIR/EFI/BOOT"

# ---------------------------------------------------------------------------
# 1. seed trust into the empty root
#
# `pkg -r` resolves EVERY path against the target root, including the repo
# definitions and the signing keys. An empty directory therefore has no trusted
# certificates and pkg fails with "Error opening the trusted directory" -- which
# reads like a network or repo problem and is not. Seed them first.
# ---------------------------------------------------------------------------
echo "==> seeding repo config and signing keys"
mkdir -p "$STAGE/usr/share/keys" "$STAGE/etc/pkg"
cp -R "/usr/share/keys/pkgbase-${FREEBSD_MAJOR}" "$STAGE/usr/share/keys/"
[ -d /usr/share/keys/pkg ] && cp -R /usr/share/keys/pkg "$STAGE/usr/share/keys/"
cp /etc/pkg/*.conf "$STAGE/etc/pkg/" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 2. base system, from pkgbase
# ---------------------------------------------------------------------------
echo "==> installing base packages"
# shellcheck disable=SC2086
pkg -r "$STAGE" install -y -r "$BASE_REPO" $BASE_PKGS

# ---------------------------------------------------------------------------
# 3. ports packages
# ---------------------------------------------------------------------------
if [ -n "${PORT_PKGS# }" ]; then
  echo "==> installing ports packages"
  # shellcheck disable=SC2086
  pkg -r "$STAGE" install -y $PORT_PKGS
fi
pkg -r "$STAGE" clean -ay >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 4. configuration -- the part that makes it yours
# ---------------------------------------------------------------------------
echo "==> applying configuration"

# The root is found by GPT label, never by device name. vtbd0 under virtio,
# ada0 under SATA, nvd0 under NVMe -- a device-name fstab makes an image that
# only boots on the hypervisor it was built for.
cat > "$STAGE/etc/fstab" <<EOF
# Device            Mountpoint  FStype  Options  Dump  Pass#
/dev/gpt/$LABEL     /           ufs     rw       1     1
EOF

cat > "$STAGE/etc/rc.conf" <<EOF
# $DISTRO_NAME $DISTRO_VERSION
hostname="$(echo "$DISTRO_NAME" | tr '[:upper:]' '[:lower:]')"
ifconfig_DEFAULT="SYNCDHCP"
zfs_enable="NO"

# Deliberately NOT set: firstboot_pkg_upgrade_enable.
# FreeBSD's own cloud images enable it, so every instance spawned from them
# re-downloads ~512 MiB of base packages on first boot. Patching is a build-time
# job, done once here, not a per-instance tax paid forever.
EOF
for svc in $RC_SERVICES; do
  echo "${svc}_enable=\"YES\"" >> "$STAGE/etc/rc.conf"
done

# Serial console first. This image is built to be run headless by a supervisor,
# and a guest that only talks to a framebuffer cannot be driven or logged.
cat > "$STAGE/boot/loader.conf" <<EOF
console="comconsole,vidconsole"
boot_multicons="YES"
boot_serial="YES"
comconsole_speed="115200"
autoboot_delay="3"
vfs.root.mountfrom="ufs:/dev/gpt/$LABEL"
EOF

# Keep a serial getty so the console is usable without sshd.
if [ -f "$STAGE/etc/ttys" ]; then
  sed -i '' 's|^ttyu0.*|ttyu0	"/usr/libexec/getty 3wire"	vt100	onifconsole secure|' \
    "$STAGE/etc/ttys" || true
fi

# DON'T PROBE THE TERMINAL. FreeBSD's default .profile runs `resizewin -z` on a
# serial line, which writes ESC[999;999H ESC[6n and reads the cursor position
# back to learn the window size. Over a browser console the reply arrives after
# resizewin has already timed out and restored cooked mode -- at which point it
# is no longer an answer, it is keystrokes, and the shell runs them:
#
#     root@park1:~ # 4;80R
#     -sh: 4: not found
#     -sh: 80R: not found
#
# There is nothing to negotiate anyway: a serial console has no in-band resize,
# so PARKVPS's terminal is a fixed 80x24 and scales instead of reflowing. Give
# the shell the answer directly. `stty` is an external command, so one
# replacement line is valid in both the sh and csh dotfiles.
for prof in "$STAGE/root/.profile" "$STAGE/root/.login" \
            "$STAGE/usr/share/skel/dot.profile" "$STAGE/usr/share/skel/dot.login"; do
  [ -f "$prof" ] || continue
  sed -i '' 's|.*resizewin.*|stty rows 24 cols 80 >/dev/null 2>\&1|' "$prof"
done

cat > "$STAGE/etc/motd.template" <<EOF

  $DISTRO_NAME $DISTRO_VERSION "$DISTRO_CODENAME"
  FreeBSD $FREEBSD_MAJOR pkgbase - assembled, not installed.

EOF

# ---------------------------------------------------------------------------
# 4b. the graphical seat, when this flavour asks for one
# ---------------------------------------------------------------------------
if [ "${DESKTOP:-no}" = "yes" ]; then
  echo "==> configuring the desktop"

  # scfb draws on the framebuffer UEFI already programmed, so there is no mode
  # setting to do and no DRM module to match against the kernel. Xorg will not
  # pick it on its own when a VESA driver is also plausible, so name it.
  mkdir -p "$STAGE/usr/local/etc/X11/xorg.conf.d"
  cat > "$STAGE/usr/local/etc/X11/xorg.conf.d/10-scfb.conf" <<'EOF'
Section "Device"
    Identifier  "Card0"
    Driver      "scfb"
EndSection
EOF

  # Autologin on the VIDEO console only. ttyu0 (serial) keeps its normal login,
  # so the two consoles do not both hand out root -- the serial one is the one
  # reachable by anything that can open a unix socket.
  cat >> "$STAGE/etc/gettytab" <<'EOF'

#
# PARKBSD: autologin root on the graphical console so X can start without a
# display manager. Deliberately a SEPARATE entry from Pc, so only the tty that
# names it is affected.
#
Pc-autologin|Pc console with autologin:\
	:al=root:tc=Pc:
EOF
  sed -i '' 's|^ttyv0.*|ttyv0	"/usr/libexec/getty Pc-autologin"	xterm	onifexists secure|' \
    "$STAGE/etc/ttys"

  cat > "$STAGE/root/.xinitrc" <<EOF
#!/bin/sh
exec $DESKTOP_SESSION
EOF
  chmod 0755 "$STAGE/root/.xinitrc"

  # Start X from the login shell rather than exec'ing it. If startx fails, an
  # exec would end the session, getty would autologin again and try again --
  # a boot loop whose only symptom is a flickering black screen. Falling
  # through leaves a root shell on the console and a log to read.
  cat >> "$STAGE/root/.profile" <<'EOF'

# PARKBSD: the graphical console starts X; the serial console does not.
if [ "$(tty)" = "/dev/ttyv0" ] && [ -z "$DISPLAY" ]; then
	startx > /var/log/startx.log 2>&1
fi
EOF
fi

# An operator-supplied overlay wins over everything above, so local changes
# never require editing this script.
if [ -d "$HERE/overlay" ]; then
  echo "==> applying overlay/"
  cp -R "$HERE/overlay/." "$STAGE/"
fi

# FreeBSD gates every `KEYWORD: firstboot` rc script -- nuageinit and growfs
# among them -- on the existence of /firstboot, which the script deletes once it
# has run. Without this marker the image boots perfectly and silently ignores
# its seed drive, so no SSH key is ever installed and the instance is
# unreachable. The stock cloud images ship this file; an assembled one must
# create it.
touch "$STAGE/firstboot"

# resolv.conf must not be baked in: it would pin every instance to whatever
# nameserver the build host happened to use.
rm -f "$STAGE/etc/resolv.conf"
mkdir -p "$STAGE/var/db/parkvps"
echo "$DISTRO_NAME $DISTRO_VERSION $DISTRO_CODENAME" > "$STAGE/var/db/parkvps/distro"

# ---------------------------------------------------------------------------
# 5. EFI system partition
# ---------------------------------------------------------------------------
echo "==> building ESP"
cp "$STAGE/boot/loader.efi" "$ESPDIR/EFI/BOOT/BOOTX64.EFI"
makefs -t msdos -s "$ESP_SIZE" -o fat_type=16 -o sectors_per_cluster=1 \
       -o volume_label=EFISYS "$WORK/esp.img" "$ESPDIR"

# ---------------------------------------------------------------------------
# 6. root filesystem + disk image
# ---------------------------------------------------------------------------
echo "==> building root filesystem"
makefs -t ffs -B little -s "$ROOT_SIZE" -o version=2,bsize=32768,fsize=4096 \
       "$WORK/root.img" "$STAGE"

echo "==> assembling GPT image"
mkimg -s gpt -f raw \
      -p efi:="$WORK/esp.img" \
      -p "freebsd-ufs/$LABEL":="$WORK/root.img" \
      -o "$IMG"

rm -f "$WORK/esp.img" "$WORK/root.img"
echo
echo "==> done"
ls -lh "$IMG"
echo "image: $IMG"
