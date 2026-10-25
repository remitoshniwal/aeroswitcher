#!/bin/bash
# toggle-maximize.sh — the alt-f toggle. Keeps track of which windows are
# currently "restored" (un-maximized) using an empty marker file per
# window ID, same idea as the earlier fullscreen attempt, except this
# time nothing external (AeroSpace) is fighting the state we set, so
# there's nothing to re-apply on every switch — this script only ever
# runs when you actually press alt-f, never automatically.

ID=$(aerospace list-windows --focused --format %{window-id})
MARKER_DIR=/tmp/aerospace-restored
MARKER="$MARKER_DIR/$ID"
SCRIPT_DIR="$HOME/Library/Application Support/AeroSpace"

mkdir -p "$MARKER_DIR"

if [ -f "$MARKER" ]; then
    # currently restored/smaller -> maximize it, clear the marker
    rm -f "$MARKER"
    # "force" skips maximize.applescript's dialog check, alt-f is always
    # your own choice. $ID tells it exactly which window to resize (see the
    # comment at the top of maximize.applescript)
    osascript "$SCRIPT_DIR/maximize.applescript" force "$ID"
else
    # currently maximized -> restore it, remember that
    touch "$MARKER"
    osascript "$SCRIPT_DIR/restore.applescript" "$ID"
fi
