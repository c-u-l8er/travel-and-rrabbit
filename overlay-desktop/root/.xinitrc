#!/bin/sh
# startx path. The session itself lives in tandr-session so this and the
# SDDM entry cannot disagree about what a session is.
exec /usr/local/bin/tandr-session
