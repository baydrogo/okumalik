#!/bin/bash
# Zips the Firefox extension for signing at addons.mozilla.org (or for about:debugging).
set -euo pipefail
cd "$(dirname "$0")/../Extensions/Firefox"
mkdir -p ../../build
OUT=../../build/okumalik-firefox.zip
rm -f "$OUT"
zip -qr -X "$OUT" manifest.json background.js popup.html popup.css popup.js icons
echo "Hazır: build/okumalik-firefox.zip"
