#!/bin/bash
# Builds build/Okumalık.app. Pass --install to copy it into /Applications.
set -euo pipefail
cd "$(dirname "$0")"
APP="build/Okumalık.app"
SCRATCH="${SCRATCH:-.build}"

# Without Xcode, the newest SDK's SwiftUI macros (@State) have no compiler plugin;
# fall back to the macOS 26 SDK that ships with Command Line Tools.
if [[ "$(xcode-select -p)" == *CommandLineTools* ]]; then
  SDK=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1 || true)
  [ -n "$SDK" ] && export SDKROOT="$SDK"
fi

# A failed build must stop here; otherwise the previous binary would be packaged.
set +e
swift build -c release --build-system native --scratch-path "$SCRATCH" 2>&1 | grep -v "has been deprecated"
status=${PIPESTATUS[0]}
set -e
BIN="$SCRATCH/release/Okumalik"
[ "$status" -eq 0 ] && [ -x "$BIN" ] || { echo "Derleme başarısız."; exit 1; }
[ -f Resources/AppIcon.icns ] || ./scripts/make-icon.sh

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Resources/Vendor/defuddle.js Resources/Vendor/defuddle-LICENSE.txt "$APP/Contents/Resources/"
codesign --force --sign - "$APP"

if [ "${1:-}" = "--install" ]; then
  rm -rf "/Applications/Okumalık.app"
  cp -R "$APP" /Applications/
  echo "Kuruldu: /Applications/Okumalık.app"
else
  echo "Hazır: $APP"
fi
