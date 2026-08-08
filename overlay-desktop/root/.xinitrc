#!/bin/sh
# PARKBSD desktop session.
#
# Overrides the .xinitrc build-image.sh writes, because the overlay is applied
# last. Same rule as there: icewm is exec'd LAST and owns the session, so when
# it exits X exits.

# The panel first, in the background. It is not the session leader -- if tint2
# dies you lose the panel, not the desktop.
tint2 >/dev/null 2>&1 &

# Belt and braces on the wallpaper. icewm sets it from ~/.icewm/preferences,
# but that path depends on how icewm was built (it needs image support), and a
# desktop that comes up plain black looks broken rather than unconfigured.
# xwallpaper is 30 KB and does not care.
[ -x /usr/local/bin/xwallpaper ] && \
    xwallpaper --zoom /usr/local/share/parkbsd/wallpaper.jpg >/dev/null 2>&1

exec icewm-session
