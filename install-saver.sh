#!/bin/bash
# Installs dist/WaterBreak.saver into ~/Library/Screen Savers.
#
# Installing for the current user only (rather than /Library) keeps this out of
# system directories and needs no sudo.
set -euo pipefail

cd "$(dirname "$0")"

SRC="dist/WaterBreak.saver"
DEST_DIR="$HOME/Library/Screen Savers"
DEST="$DEST_DIR/WaterBreak.saver"

if [ ! -d "$SRC" ]; then
    echo "error: $SRC not found — run ./build-saver.sh first" >&2
    exit 1
fi

mkdir -p "$DEST_DIR"

if [ -d "$DEST" ]; then
    echo "Replacing existing $DEST"
    rm -rf "$DEST"
fi

cp -R "$SRC" "$DEST"
echo "Installed $DEST"
echo
echo "Now select it:  System Settings > Screen Saver > WaterBreak"
echo
echo "If it does not appear, or shows as black, quit and reopen System Settings —"
echo "the screensaver list is cached per launch."
