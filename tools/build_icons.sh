#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

swiftc -O make_icon.swift -o make_icon -framework AppKit
BIN="./make_icon"
SET="AppIcon.iconset"
mkdir -p "$SET"

gen() { "$BIN" "$1" "$SET/$2"; }

gen 16  icon_16x16.png
gen 32  icon_16x16@2x.png
gen 32  icon_32x32.png
gen 64  icon_32x32@2x.png
gen 128 icon_128x128.png
gen 256 icon_128x128@2x.png
gen 256 icon_256x256.png
gen 512 icon_256x256@2x.png
gen 512 icon_512x512.png
gen 1024 icon_512x512@2x.png

iconutil -c icns "$SET" -o AppIcon.icns
echo "Built tools/AppIcon.icns"