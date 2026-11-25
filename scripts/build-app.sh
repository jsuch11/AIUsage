#!/bin/bash
# Builds "AI Usage.app" into ./build and (optionally) copies it to /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

# Assemble and sign outside the project: iCloud Drive (Documents) re-adds Finder/file-provider
# attributes to bundles it syncs, and codesign rejects those ("detritus not allowed").
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/AI Usage.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/AIUsage "$APP/Contents/MacOS/AIUsage"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] || ./scripts/make-icon.sh
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
xattr -cr "$APP"
# A stable identity keeps Keychain access across rebuilds (run scripts/setup-signing.sh once).
# Without it, fall back to ad-hoc signing, which asks for Keychain access after every build.
IDENTITY="AI Usage Local Signing"
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  codesign --force --deep --sign "$IDENTITY" "$APP"
else
  echo "Note: no \"$IDENTITY\" certificate; signing ad-hoc. Run scripts/setup-signing.sh to fix Keychain prompts."
  codesign --force --deep --sign - "$APP"
fi

rm -rf "build/AI Usage.app"
mkdir -p build
ditto "$APP" "build/AI Usage.app"
echo "Built: build/AI Usage.app"
if [[ "${1:-}" == "--install" ]]; then
  pkill -x AIUsage 2>/dev/null || true
  # Wait for the old copy to quit, or `open` fails with error -600.
  for _ in {1..25}; do pgrep -x AIUsage >/dev/null || break; sleep 0.2; done
  rm -rf "/Applications/AI Usage.app"
  ditto "$APP" "/Applications/AI Usage.app"
  open "/Applications/AI Usage.app"
  echo "Installed to /Applications"
fi
