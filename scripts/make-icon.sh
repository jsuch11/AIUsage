#!/bin/bash
# Regenerates Resources/AppIcon.icns from the LogoMark SwiftUI view.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
swiftc -parse-as-library -target arm64-apple-macos14 scripts/make-icon.swift Sources/AIUsage/Views/Logo.swift -o "$TMP/make-icon"
"$TMP/make-icon" "$TMP/AppIcon.iconset"
iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
cp "$TMP/AppIcon.iconset/icon_512x512@2x.png" Resources/AppIcon-1024.png
rm -rf "$TMP"
echo "Wrote Resources/AppIcon.icns"
