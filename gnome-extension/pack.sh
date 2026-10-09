#!/bin/bash
# pack.sh — build the extension zip (extensions.gnome.org format) into dist/
#
#   ./gnome-extension/pack.sh
#   gnome-extensions install --force gnome-extension/dist/egpu-indicator@quazardous.github.io.shell-extension.zip
#
# The zip holds only what the shell loads: metadata.json, extension.js,
# stylesheet.css, icons/ and the license (review guidelines: no build or
# install scripts, no unused files).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
UUID=egpu-indicator@quazardous.github.io
SRC="$HERE/$UUID"
OUT="$HERE/dist"

mkdir -p "$OUT"
# gnome-extensions pack takes extra sources relative to the extension dir.
cp "$HERE/../LICENSE" "$SRC/LICENSE"
trap 'rm -f "$SRC/LICENSE"' EXIT
gnome-extensions pack "$SRC" --force --out-dir="$OUT" \
    --extra-source=icons --extra-source=LICENSE

ZIP="$OUT/$UUID.shell-extension.zip"
echo "Built $ZIP:"
unzip -l "$ZIP" | sed -n '4,$p' | head -n -2 | awk '{print "  " $4}'
