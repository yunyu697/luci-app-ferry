#!/bin/sh
[ "$1" = "upgrade" ] && exit 0
[ -x /usr/lib/ferry/uninstall.sh ] && /usr/lib/ferry/uninstall.sh
exit 0
