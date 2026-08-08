#!/bin/sh
# startx path. The session itself lives in parkbsd-session so this and the
# SDDM entry cannot disagree about what a session is.
exec /usr/local/bin/parkbsd-session
