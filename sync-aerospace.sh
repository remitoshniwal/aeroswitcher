#!/bin/bash
# sync-aerospace.sh: copies your REAL AeroSpace setup into this repo's
# aerospace/ folder, so the copy on GitHub matches what's actually running
# on your Mac.
#
# It only ever copies in one direction, Mac to repo. It reads your live
# files and never writes to them, so running it can't break your current
# setup no matter what. The worst it can do is overwrite the repo copies,
# which git can always undo (`git checkout aerospace/`).
#
# Run it any time you've edited ~/.aerospace.toml or one of the scripts,
# then look at what it printed and commit if it looks right:
#
#   ./sync-aerospace.sh
#   git add aerospace && git commit -m "Sync AeroSpace config"

set -e

# Always work from the folder this script lives in (the repo), no matter
# which folder you ran it from. Without this, running it from somewhere
# else would copy files into the wrong place.
cd "$(dirname "$0")"

# Where the live files are. If you ever move them, this is the part to
# change. The scripts folder name has to be exactly "AeroSpace", because
# .aerospace.toml points at it by that exact path.
LIVE_TOML="$HOME/.aerospace.toml"
LIVE_SCRIPTS="$HOME/Library/Application Support/AeroSpace"
SCRIPTS="maximize.applescript restore.applescript toggle-maximize.sh"

# .aerospace.toml and toggle-maximize.sh spell out /Users/remitoshniwal
# in full (AeroSpace commands don't understand ~). On a Mac with any other
# username those paths point nowhere, so say so loudly instead of quietly
# syncing a config that wouldn't work there.
if [ "$HOME" != "/Users/remitoshniwal" ]; then
    echo "WARNING: your home folder is $HOME, but the AeroSpace files have"
    echo "/Users/remitoshniwal written into them. They won't work on this Mac"
    echo "until those paths are changed. See step 4 of the install guide."
    echo
fi

# Copy one file into aerospace/, but skip it (with a message) if the live
# file doesn't exist. Skipping matters: copying "nothing" over the repo
# copy would look like you deleted it.
copy_in() {
    if [ -f "$1" ]; then
        cp "$1" "aerospace/$2"
        echo "copied  $1"
    else
        echo "SKIPPED $1 (not found, repo copy left as it was)"
    fi
}

copy_in "$LIVE_TOML" ".aerospace.toml"
for f in $SCRIPTS; do
    copy_in "$LIVE_SCRIPTS/$f" "$f"
done

# Show what actually changed compared to the last commit. Nothing listed
# here means the repo was already up to date.
echo
if git diff --quiet -- aerospace/; then
    echo "No changes. The repo copies already match your Mac."
else
    echo "Changed since the last commit:"
    git diff --stat -- aerospace/
    echo
    echo "See the exact lines with:  git diff aerospace/"
fi

# While we're here, compare .aerospace.toml against AeroSwitcher's
# config.json and point out apps that are set up in one but not the other.
# Only prints, never changes anything. See check-drift.js for details.
echo
osascript -l JavaScript check-drift.js
