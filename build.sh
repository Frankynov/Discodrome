#!/bin/bash
# Builds Discodrome and assembles a double-clickable .app bundle.
# No Xcode required — just the Swift toolchain from the Command Line Tools.
#
#   ./build.sh              release, this Mac's architecture
#   ./build.sh universal    release, Apple silicon + Intel in one binary
#   ./build.sh debug        debug, this Mac's architecture — much faster to build
set -euo pipefail
cd "$(dirname "$0")"

MODE=${1:-release}
APP="build/Discodrome.app"

# The single source of truth for the app's version.
APP_VERSION="1.0"
DEPLOYMENT=15.0

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

case "$MODE" in
  debug)
    echo "▸ Compiling (debug)…"
    swift build -c debug --product Discodrome
    cp "$(swift build -c debug --show-bin-path)/Discodrome" "$APP/Contents/MacOS/Discodrome"
    ;;
  universal)
    for triple in "arm64-apple-macosx$DEPLOYMENT" "x86_64-apple-macosx$DEPLOYMENT"; do
      echo "▸ Compiling (release, $triple)…"
      swift build -c release --product Discodrome --triple "$triple"
    done
    echo "▸ Joining into a universal binary…"
    lipo -create \
      "$(swift build -c release --triple "arm64-apple-macosx$DEPLOYMENT" --show-bin-path)/Discodrome" \
      "$(swift build -c release --triple "x86_64-apple-macosx$DEPLOYMENT" --show-bin-path)/Discodrome" \
      -output "$APP/Contents/MacOS/Discodrome"
    ;;
  *)
    echo "▸ Compiling (release)…"
    swift build -c release --product Discodrome
    cp "$(swift build -c release --show-bin-path)/Discodrome" "$APP/Contents/MacOS/Discodrome"
    ;;
esac

echo "▸ Writing Info.plist…"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Discodrome</string>
  <key>CFBundleDisplayName</key><string>Discodrome</string>
  <key>CFBundleExecutable</key><string>Discodrome</string>
  <key>CFBundleIdentifier</key><string>com.discodrome.app</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>CFBundleVersion</key><string>$APP_VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$DEPLOYMENT</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Discodrome</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <!-- Home servers are often plain HTTP behind names like music.home or a LAN address. -->
    <key>NSAllowsArbitraryLoads</key><true/>
  </dict>
  <key>NSLocalNetworkUsageDescription</key>
  <string>Discodrome streams and copies music from your Navidrome server on the local network.</string>
  <key>NSRemovableVolumesUsageDescription</key>
  <string>Discodrome reads and writes the music on your SNOWSKY DISC's memory card.</string>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>com.discodrome.library-item</string>
      <key>UTTypeDescription</key><string>Discodrome Library Item</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  (ad-hoc signing skipped)"
touch "$APP"

echo "▸ Done: $APP"
lipo -archs "$APP/Contents/MacOS/Discodrome" | sed 's/^/  architectures: /'
