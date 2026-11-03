#!/bin/bash
# Fetches a Defuddle release from npm into Resources/Vendor. Usage: scripts/update-defuddle.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-latest}"
TMP=$(mktemp -d)
(cd "$TMP" && npm pack "defuddle@$VERSION" --silent >/dev/null && tar xzf defuddle-*.tgz)
cp "$TMP/package/dist/index.full.js" Resources/Vendor/defuddle.js
cp "$TMP/package/LICENSE" Resources/Vendor/defuddle-LICENSE.txt
echo "defuddle $(node -p "require('$TMP/package/package.json').version" 2>/dev/null || echo "$VERSION")"
rm -rf "$TMP"
