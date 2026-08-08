# T&R — Travel & RRABBIT

A FreeBSD distribution, assembled rather than installed.

T&R is built from **FreeBSD 15 pkgbase** — the base system as ~509 packages —
so making a root filesystem is `pkg -r <dir> install`. There is no source tree,
no `buildworld` and no release tarballs. `tandr.conf` *is* the distro;
`build-image.sh` is the mechanism and should not need editing to make a
different flavour.

Two flavours, the same system with and without a screen:

| | server (`tandr.conf`) | desktop (`tandr-desktop.conf`) |
|---|---|---|
| golden image | **364 MB** | **~5.2 GB** |
| packages | 50 | ~350 |
| what you get | sshd, cron, serial console | X.org, icewm + a vertical tint2 panel, Firefox, SDDM |

For comparison, FreeBSD's own cloud image is 2.51 GB with 504 packages, and a
VM spawned from it writes ~3 GB to its overlay on first boot. A T&R server
instance writes **51 MB**, because the image is already patched and does not
re-download its own base every time it starts.

## Build

The image must be assembled **on FreeBSD** (`makefs`, `mkimg` and `pkg -r` are
FreeBSD-native), so the build pushes this tree to a FreeBSD 15 builder over ssh
and streams the result back. Any reachable FreeBSD machine with ~8 GB free will
do:

```bash
BUILDER_SSH=root@10.0.0.5 ./make.sh tandr-desktop.conf
```

If [PARKVPS](https://github.com/c-u-l8er/PARKVPS) is alongside, name one of its
instances instead and the ssh details are looked up for you:

```bash
./make.sh tandr-desktop.conf builder
```

## What is in the box

- **Assembled from pkgbase.** Deliberately absent: `FreeBSD-tests` (~200 MB of
  test suites), every `-dbg` package, every `lib32` package.
- **Serial console first.** `comconsole,vidconsole` with `boot_multicons`,
  because this image is built to be run headless by a supervisor and a guest
  that only talks to a framebuffer cannot be driven or logged.
- **Root is found by GPT label, never device name.** `vtbd0` under virtio,
  `ada0` under SATA, `nvd0` under NVMe — a device-name fstab makes an image
  that only boots on the hypervisor it was built on.
- **No `firstboot_pkg_upgrade`.** FreeBSD's own cloud images enable it, so every
  instance re-downloads ~512 MiB of base packages on first boot, forever.
  Patching is a build-time job done once.
- **The desktop is themed as a cockpit** — the palette comes from
  [RAVIO](https://github.com/c-u-l8er/RAVIO): amber `#F2C14E` for the focused
  window, cyan `#2DE2E6` for live readouts, bronze rims, on `#03040a`. SDDM's
  greeter is a QML theme of its own with an **IGNITION** button.

## Things that will cost you a day if you rediscover them

Written down because each one presents as something other than what it is.

- **`xorg-minimal` installs font *libraries* and zero font *files*.** A fontless
  icewm does not merely draw blank labels — it **stops moving windows** (press,
  drag, release moves a window by exactly its decoration offset and no further),
  and fluxbox refuses to start at all. This reads as "click and drag is broken"
  and sends you through the whole input stack.
- **A `usb-tablet` is mandatory for a usable desktop under VNC.** VNC speaks
  *absolute* pointer positions; with only a PS/2 mouse the hypervisor converts
  them to relative motion and press/move/release land in three different places.
- **`QtVersion=6` in an SDDM theme's `metadata.desktop` is load-bearing.**
  Without it SDDM 0.21 looks for the Qt5 greeter, does not find it, and falls
  back to its default theme. It looks exactly like a wrong theme name.
- **The icewm package ships three xsession entries of its own**, and a greeter
  picks among them by sort order — so the panel silently never starts.
- **icewm colours must live in a theme file**, not in `~/.icewm/preferences`;
  a loaded theme overrides that file and colours set there do nothing.
- **tint2's `panel_size` is `width height` horizontally and *swapped*
  vertically.** A 62 px full-height column is `100% 62`.
- **FreeBSD sets `schg` on parts of base**, so `rm -rf` cannot clean a staged
  root. `chflags -R noschg` first.
- **`pkg -r` resolves trust against the *target* root**, so an empty directory
  has no signing keys and fails with "Error opening the trusted directory" —
  which reads like a network fault.
- **Four base packages look optional and are not**: `FreeBSD-rc` (no `/etc/rc`
  at all), `FreeBSD-ufs` (no `fsck_ufs`, boot aborts), `FreeBSD-geom` (`gpart`,
  needed by growfs), `FreeBSD-utilities` (`awk`). Plus `FreeBSD-pam` for sshd.
  The ssh package is `FreeBSD-ssh`, not `FreeBSD-openssh`.

## Logging in

The desktop flavour ships a user for the greeter, because root is refused for
graphical login and the cloud-init user's password is locked. **The password is
generated at build time**, printed once when the build finishes, and written to
`/root/DESKTOP-LOGIN` and the MOTD inside the image. Set `DESKTOP_PASSWORD` in
the config to pin one instead.

Note the serial console is marked `secure` and root has no password, so anyone
who can reach the console is root. That is fine for a disposable local VM and
wrong the moment one listens on a real address.

## Name

**T&R** is Travel & RRABBIT. The ampersand is a display name only — it is
invalid in a hostname and needs quoting in every path that touches it, so
`DISTRO_SLUG` (`tandr`) is what filenames, the GPT label and the hostname are
built from.
