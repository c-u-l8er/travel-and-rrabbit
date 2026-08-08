#!/bin/sh
# T&R image assembler. Runs INSIDE a FreeBSD builder VM, as root.
#
# Assembles a bootable UEFI disk image from pkgbase packages -- no source tree,
# no buildworld, no release tarballs. This is the NomadBSD approach updated for
# FreeBSD 15: because the base system is now shipped as ~509 packages, building
# a root filesystem is `pkg -r <dir> install`, and the rest is filesystem
# plumbing.
#
#   build-image.sh [config]      default: ./tandr.conf
#
# Produces: <workdir>/<NAME>-<VERSION>.raw
set -eu

HERE=$(dirname "$0")
CONF="${1-}"
[ -n "$CONF" ] || CONF="$HERE/tandr.conf"
[ -r "$CONF" ] || { echo "no such config: $CONF" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"

[ "$(id -u)" -eq 0 ] || { echo "must run as root (try: sudo $0 $*)" >&2; exit 1; }

# DISTRO_NAME is a DISPLAY name and may contain anything -- "T&R" does. Paths
# may not: "&" is invalid in a hostname, and it needs quoting in every shell
# command and GPT label that touches it. So everything that becomes a path,
# a label or a hostname uses DISTRO_SLUG, and only prose uses DISTRO_NAME.
DISTRO_SLUG="${DISTRO_SLUG:-$(echo "$DISTRO_NAME" | tr '[:upper:]' '[:lower:]' \
                             | sed 's/[^a-z0-9]//g')}"

WORK="${WORK:-/var/tmp/tandr}"
STAGE="$WORK/root"
ESPDIR="$WORK/esp"
IMG="$WORK/${DISTRO_SLUG}-${DISTRO_VERSION}.raw"
LABEL="${DISTRO_SLUG}root"

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
hostname="$DISTRO_SLUG"
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

  # Core X font paths. Xft/fontconfig apps do not need these, but a window
  # manager falling back to the core font 'fixed' does -- and fluxbox exits
  # outright when it cannot find it.
  cat > "$STAGE/usr/local/etc/X11/xorg.conf.d/20-fonts.conf" <<'EOF'
Section "Files"
    FontPath    "/usr/local/share/fonts/misc/"
    FontPath    "/usr/local/share/fonts/dejavu/"
    FontPath    "/usr/local/share/fonts/Liberation/"
EndSection
EOF

  # pkg's post-install scripts do not reliably build a fontconfig cache when
  # installing into a staged root with `pkg -r`, so do it on first boot. Without
  # a cache fontconfig still works by scanning, but the first X start pays for
  # it every single time.
  cat > "$STAGE/etc/rc.d/parkvps_fccache" <<'EOF'
#!/bin/sh
# PROVIDE: parkvps_fccache
# REQUIRE: FILESYSTEMS
# BEFORE: LOGIN
# KEYWORD: firstboot
. /etc/rc.subr
name="parkvps_fccache"
start_cmd="/usr/local/bin/fc-cache -f >/dev/null 2>&1 || true"
stop_cmd=":"
load_rc_config $name
run_rc_command "$1"
EOF
  chmod 0555 "$STAGE/etc/rc.d/parkvps_fccache"

  if [ -z "${DISPLAY_MANAGER:-}" ]; then
    # NO display manager: autologin root on the VIDEO console only and start X
    # from the shell. ttyu0 (serial) keeps its normal login, so the two consoles
    # do not both hand out root -- the serial one is reachable by anything that
    # can open a unix socket.
    cat >> "$STAGE/etc/gettytab" <<'EOF'

#
# T&R: autologin root on the graphical console so X can start without a
# display manager. Deliberately a SEPARATE entry from Pc, so only the tty that
# names it is affected.
#
Pc-autologin|Pc console with autologin:\
	:al=root:tc=Pc:
EOF
    sed -i '' 's|^ttyv0.*|ttyv0	"/usr/libexec/getty Pc-autologin"	xterm	onifexists secure|' \
      "$STAGE/etc/ttys"

    # Start X from the login shell rather than exec'ing it. If startx fails, an
    # exec would end the session, getty would autologin again and try again --
    # a boot loop whose only symptom is a flickering black screen. Falling
    # through leaves a root shell on the console and a log to read.
    cat >> "$STAGE/root/.profile" <<'EOF'

# T&R: the graphical console starts X; the serial console does not.
if [ "$(tty)" = "/dev/ttyv0" ] && [ -z "$DISPLAY" ]; then
	startx > /var/log/startx.log 2>&1
fi
EOF
  else
    echo "==> display manager: $DISPLAY_MANAGER"
    # A display manager OWNS the graphical console, so the autologin+startx path
    # above must NOT also exist. Both would fight over ttyv0, and the symptom is
    # a screen flickering between a greeter and a shell.
    mkdir -p "$STAGE/etc/rc.conf.d"
    echo "${DISPLAY_MANAGER}_enable=\"YES\"" > "$STAGE/etc/rc.conf.d/$DISPLAY_MANAGER"

    mkdir -p "$STAGE/usr/local/etc"
    cat > "$STAGE/usr/local/etc/sddm.conf" <<EOF
[General]
DisplayServer=x11
HaltCommand=/sbin/shutdown -p now
RebootCommand=/sbin/shutdown -r now

[Theme]
Current=tandr

[Autologin]
Session=tandr

[Users]
DefaultPath=/usr/local/bin:/usr/local/sbin:/bin:/sbin:/usr/bin:/usr/sbin
MaximumUid=65000
MinimumUid=1000

[X11]
SessionDir=/usr/local/share/xsessions
UserAuthFile=.Xauthority
EOF
  fi
fi

# An operator-supplied overlay wins over everything above, so local changes
# never require editing this script. The directory is named by the config, so a
# flavour brings its own -- the desktop's theme must not land in the server
# image, which has no X to theme.
OVL="$HERE/${OVERLAY_DIR:-overlay}"
if [ -d "$OVL" ]; then
  echo "==> applying $(basename "$OVL")/"
  cp -R "$OVL/." "$STAGE/"
  chmod 0755 "$STAGE/root/.xinitrc" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 5b. the desktop user, and the cockpit config for every home
#
# Runs AFTER the overlay because it copies the overlay's own dotfiles. A greeter
# needs somebody to greet: root is refused for graphical login and the nuageinit
# user is created with a locked password, so the image carries a real one.
# ---------------------------------------------------------------------------
if [ "${DESKTOP:-no}" = "yes" ] && [ -n "${DISPLAY_MANAGER:-}" ]; then
  DU="${DESKTOP_USER:-driver}"
  # An empty DESKTOP_PASSWORD means "generate one". That is the default, so a
  # public repo carries no password at all -- the secret is created at build
  # time, printed once, and written into the image where the operator can find
  # it. Setting it in the config still works and is honoured as-is.
  if [ -z "${DESKTOP_PASSWORD:-}" ]; then
    DESKTOP_PASSWORD="$(LC_ALL=C tr -dc 'a-hj-km-np-z2-9' < /dev/urandom | head -c 12)"
    GENERATED_PW=1
  else
    GENERATED_PW=0
  fi
  echo "==> desktop user $DU"
  echo "$DESKTOP_PASSWORD" | \
    pw -R "$STAGE" useradd "$DU" -u 1010 -c "T&R desktop" \
       -G wheel,video,operator -m -s /bin/sh -h 0
  # Somewhere findable from inside the machine, since the greeter can tell you
  # the username but obviously not the password.
  printf '%s\n' "$DU:$DESKTOP_PASSWORD" > "$STAGE/root/DESKTOP-LOGIN"
  chmod 0600 "$STAGE/root/DESKTOP-LOGIN"
  cat >> "$STAGE/etc/motd.template" <<EOF
  desktop login:  $DU / $DESKTOP_PASSWORD
EOF
fi

if [ "${DESKTOP:-no}" = "yes" ] && [ -n "${DISPLAY_MANAGER:-}" ]; then
  # ONE SESSION. The icewm package ships its own xsession entries
  # (icewm-session.desktop, icewm.desktop, xinitrc.desktop) and a greeter picks
  # among them by sort order, so SDDM launched `icewm-session` directly and the
  # tint2 panel never started -- a desktop that comes up looking almost right,
  # missing only the thing that makes it ours. This image ships one desktop, so
  # it should offer one session; tandr.desktop runs tandr-session, which
  # starts the panel AND icewm.
  rm -f "$STAGE/usr/local/share/xsessions/icewm.desktop" \
        "$STAGE/usr/local/share/xsessions/icewm-session.desktop" \
        "$STAGE/usr/local/share/xsessions/xinitrc.desktop"
fi

if [ "${DESKTOP:-no}" = "yes" ]; then
  # One cockpit, every home. The canonical copies live under the overlay's
  # /root; anyone else gets the same files rather than a second definition that
  # can drift.
  for home in "$STAGE/root" "$STAGE/home/${DESKTOP_USER:-driver}"; do
    [ -d "$home" ] || continue
    [ "$home" = "$STAGE/root" ] || {
      mkdir -p "$home/.icewm" "$home/.config/tint2"
      cp -R "$STAGE/root/.icewm/." "$home/.icewm/" 2>/dev/null || true
      cp "$STAGE/root/.config/tint2/tint2rc" "$home/.config/tint2/" 2>/dev/null || true
      cp "$STAGE/root/.xinitrc" "$home/" 2>/dev/null || true
      chown -R 1010:1010 "$home" 2>/dev/null || true
    }
  done
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
if [ "${GENERATED_PW:-0}" = "1" ]; then
  echo
  echo "    desktop login:  $DU / $DESKTOP_PASSWORD"
  echo "    (generated for this build; also in /root/DESKTOP-LOGIN and the motd)"
fi
