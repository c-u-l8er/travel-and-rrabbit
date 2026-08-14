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

# What the stack needs, and only when the stack is coming. The interpreter is
# most of what the stack costs -- 14 MB of python against a 260 MB python -- so
# a flavour that is not carrying TRVM should not pay for it. Installed here
# rather than beside the files further down so it lands before `pkg clean -ay`
# -- installing after that would leave the package cache in the image.
if [ -n "${STACK_DIST:-}" ] && [ -n "${STACK_PKGS:-}" ] && [ -n "${STACK_PKGS# }" ]; then
  echo "==> installing what the verifiable stack runs on"
  # shellcheck disable=SC2086
  pkg -r "$STAGE" install -y $STACK_PKGS
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

  # ASK UEFI FOR A BIG FRAMEBUFFER, because nothing after this point can.
  #
  # scfb draws on whatever mode the EFI GOP was left in and cannot change it at
  # runtime -- no DRM, no RandR, no xrandr. So the desktop's resolution is
  # decided here, in the loader, or not at all. Left alone this image came up at
  # 1280x800 and stayed there on a 4K monitor, with the whole desktop in the
  # top-left eighth of the screen and black around it.
  #
  # `efi_max_resolution` is a CEILING, not a demand: the loader picks the largest
  # mode the firmware offers that does not exceed it, so a machine whose display
  # tops out lower still gets its own best mode. Measured under OVMF with the
  # `vga` adapter: 2160p asks for and gets 3840x2160.
  #
  # THE ADAPTER HAS TO HAVE THE MEMORY FOR IT. 3840*2160*4 is 31.6 MiB, so the
  # 32 MB this image was previously run with had nothing to spare; `contrib/
  # tandr-libvirt.xml` asks for 64 MB. A framebuffer the card cannot hold means
  # the mode is simply not offered and you silently get a smaller one.
  echo 'efi_max_resolution="2160p"' >> "$STAGE/boot/loader.conf"

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

  # pkg's post-install scripts do not reliably run when installing into a staged
  # root with `pkg -r`, so the caches they would have built get built on first
  # boot instead.
  #
  # THIS IS NOT ONLY A SPEED PROBLEM, and it was written as if it were. Without
  # a fontconfig cache fontconfig still works by scanning, so the cost is time.
  # The MIME database is not like that: without
  # `/usr/local/share/mime/mime.cache`, gdk-pixbuf recognises **no image format
  # at all** -- not SVG, not even a 409-byte PNG -- and every GTK application
  # dies on its first themed icon in a `g_assert` that cannot be caught:
  #
  #   Gtk:ERROR:gtkiconhelper.c:495: Failed to load .../image-missing.svg:
  #   Unrecognized image file format
  #   Bail out!
  #
  # mousepad aborted with SIGABRT and firefox with SIGSEGV inside 200 ms, and
  # `gtk3-demo` did the same on a plain X session, so it is the image and not the
  # road. It reads like a broken gdk-pixbuf -- the library dlopens no loader and
  # exports no builtin -- and it is one missing cache file.
  #
  # The service keeps the name `parkvps_fccache` because both flavour configs
  # name it in RC_SERVICES; it builds all of them now.
  cat > "$STAGE/etc/rc.d/parkvps_fccache" <<'EOF'
#!/bin/sh
# PROVIDE: parkvps_fccache
# REQUIRE: FILESYSTEMS
# BEFORE: LOGIN
# KEYWORD: firstboot
#
# The desktop caches `pkg -r` did not build. Each guarded, because a missing
# tool must not stop the others -- and none of them is fatal to boot.
. /etc/rc.subr
name="parkvps_fccache"
build_caches() {
    [ -x /usr/local/bin/fc-cache ] && /usr/local/bin/fc-cache -f >/dev/null 2>&1
    # Without this, GTK cannot load a single image. See build-image.sh.
    [ -x /usr/local/bin/update-mime-database ] && \
        /usr/local/bin/update-mime-database /usr/local/share/mime >/dev/null 2>&1
    [ -x /usr/local/bin/gdk-pixbuf-query-loaders ] && \
        /usr/local/bin/gdk-pixbuf-query-loaders --update-cache >/dev/null 2>&1
    [ -x /usr/local/bin/gtk-update-icon-cache ] && \
        for d in /usr/local/share/icons/*/; do
            [ -f "$d/index.theme" ] && \
                /usr/local/bin/gtk-update-icon-cache -q -t -f "$d" >/dev/null 2>&1
        done
    return 0
}
start_cmd="build_caches"
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

# The RRABBIT shell, if the operator built one. It is a separate repo, so the
# image takes a BUILT TREE rather than sources: `npx vite build` on a
# workstation produces dist/, and RRABBIT_DIST points at the repo that holds it.
# Nothing here needs node -- the bridge is stdlib python and serves the bundle
# itself.
#
# Absent, the rrabbit session entry simply falls back to the T&R cockpit, which
# is why this is optional rather than a hard dependency.
if [ -n "${RRABBIT_DIST:-}" ]; then
  if [ -d "$RRABBIT_DIST/dist" ] && [ -f "$RRABBIT_DIST/bridge.py" ]; then
    echo "==> installing the RRABBIT shell from $RRABBIT_DIST"
    mkdir -p "$STAGE/usr/local/share/rrabbit"
    cp -R "$RRABBIT_DIST/dist" "$STAGE/usr/local/share/rrabbit/"
    cp "$RRABBIT_DIST/bridge.py" "$STAGE/usr/local/share/rrabbit/bridge.py"
    chmod 0755 "$STAGE/usr/local/bin/rrabbit-session" 2>/dev/null || true
  else
    echo "!!! RRABBIT_DIST=$RRABBIT_DIST has no dist/ + bridge.py -- run: npx vite build" >&2
    exit 1
  fi
fi

# The verifiable stack: TRVM (the runtime) and TRAAVIIS (`trvs`, the verifier
# that turns a run into a bundle somebody else can replay). Both are pure python
# against the standard library, which is the only reason a distro image can
# carry them without carrying a package manager for them.
#
# `forge` finds the native runtime at ../runtime/c/ic32 RELATIVE TO ITSELF, so
# the two must stay siblings under one root -- this is a layout, not a pile of
# files.
if [ -n "${STACK_DIST:-}" ]; then
  if [ ! -d "$STACK_DIST/trvm/forge" ] || [ ! -d "$STACK_DIST/traaviis" ]; then
    echo "!!! STACK_DIST=$STACK_DIST has no trvm/forge + traaviis" >&2
    exit 1
  fi
  echo "==> installing the verifiable stack (TRVM + trvs)"
  mkdir -p "$STAGE/usr/local/lib/trvm" "$STAGE/usr/local/lib/traaviis"
  cp -R "$STACK_DIST/trvm/forge" "$STAGE/usr/local/lib/trvm/"
  cp -R "$STACK_DIST/trvm/runtime" "$STAGE/usr/local/lib/trvm/"
  cp -R "$STACK_DIST/traaviis" "$STAGE/usr/local/lib/traaviis/"

  # ic32 is C, and the copy on a Linux workstation is a Linux ELF that a FreeBSD
  # guest cannot run. This build host IS FreeBSD, so compile it here and ship a
  # binary -- the image needs no compiler, which is the whole point of pkgbase.
  if [ -f "$STACK_DIST/trvm/runtime/c/ic32.c" ]; then
    if cc -O2 -o "$STAGE/usr/local/lib/trvm/runtime/c/ic32" \
          "$STACK_DIST/trvm/runtime/c/ic32.c" 2>/dev/null; then
      echo "    ic32: compiled for $(uname -m) on this builder"
    else
      # Named, not swallowed: trvs still runs on the reference interpreter, and
      # `trvs doctor` will say ic32 is missing rather than pretend otherwise.
      rm -f "$STAGE/usr/local/lib/trvm/runtime/c/ic32"
      echo "!!! ic32 did NOT compile -- shipping the reference interpreter only" >&2
    fi
  fi

  # One entry point that knows the layout, so nothing on the image has to be
  # told where the engine lives.
  cat > "$STAGE/usr/local/bin/trvs" <<'EOF'
#!/bin/sh
# trvs -- the verifiable world terminal, wired to the engine this image ships.
TRVM_ROOT=/usr/local/lib/trvm
export TRVS_FORGE_DIR="${TRVS_FORGE_DIR:-$TRVM_ROOT/forge}"
export PYTHONPATH="/usr/local/lib/traaviis:$TRVM_ROOT/runtime/python${PYTHONPATH:+:$PYTHONPATH}"
exec python3 -m traaviis.cli "$@"
EOF
  chmod 0755 "$STAGE/usr/local/bin/trvs"
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

  # SAY WHICH SESSION IS THE DEFAULT. The block above removed icewm's entries
  # because a greeter picks among sessions by sort order; with RRABBIT
  # installed this image ships two of its OWN, and `rrabbit.desktop` sorts
  # before `tandr.desktop`. Measured on a fresh boot: SDDM preselected RRABBIT,
  # the greeter's session label was blank, and there was no way to pick the
  # cockpit -- so the shell's own rule, "beside the cockpit, never instead of
  # it", was false on the only screen where it is decided.
  #
  # Seeding SDDM's state file makes the default a decision taken here rather
  # than an alphabetical accident. The greeter's F2 still reaches RRABBIT, and
  # SDDM overwrites this the first time anyone logs in, so it sets the initial
  # state without pinning it.
  if [ -n "${RRABBIT_DIST:-}" ]; then
    mkdir -p "$STAGE/var/lib/sddm"
    cat > "$STAGE/var/lib/sddm/state.conf" <<EOF
[Last]
Session=/usr/local/share/xsessions/${DEFAULT_SESSION:-tandr}.desktop
EOF
    chmod 0644 "$STAGE/var/lib/sddm/state.conf"
    # The TARGET's sddm uid, read out of the staged passwd -- `chown sddm`
    # would resolve against the builder, where that user need not exist.
    sddm_uid=$(awk -F: '$1=="sddm"{print $3":"$4}' "$STAGE/etc/passwd" 2>/dev/null)
    [ -n "$sddm_uid" ] && chown -R "$sddm_uid" "$STAGE/var/lib/sddm" 2>/dev/null || true
    echo "==> default session: ${DEFAULT_SESSION:-tandr} (F2 at the greeter for the other)"
  fi
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
