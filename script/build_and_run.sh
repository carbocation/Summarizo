#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Summarizo"
BUNDLE_ID="com.carbocation.Summarizo"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ENTITLEMENTS="$ROOT_DIR/Summarizo.entitlements"
ASSET_CATALOG="$ROOT_DIR/Sources/Summarizo/Resources/Assets.xcassets"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/module-cache"
export SWIFTPM_CACHE_PATH="$ROOT_DIR/.build/swiftpm-cache"

swift build
BUILD_BINARY="$(swift build --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

if [[ -d "$ASSET_CATALOG" ]]; then
  ASSET_INFO_PLIST="$APP_CONTENTS/assetcatalog_generated_info.plist"
  if ! /usr/bin/xcrun actool \
    --compile "$APP_RESOURCES" \
    --platform macosx \
    --minimum-deployment-target "$MIN_SYSTEM_VERSION" \
    --app-icon AppIcon \
    --output-partial-info-plist "$ASSET_INFO_PLIST" \
    "$ASSET_CATALOG" >/dev/null 2>&1; then
    echo "failed to compile app icon asset catalog at $ASSET_CATALOG" >&2
    exit 1
  fi
  rm -f "$ASSET_INFO_PLIST"
fi

if [[ -f "$ENTITLEMENTS" ]]; then
  /usr/bin/codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP_BUNDLE" >/dev/null
fi

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  build)
    ;;
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [build|run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
