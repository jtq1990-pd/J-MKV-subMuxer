#!/usr/bin/env bash
set -euo pipefail

PRODUCT_NAME="J-MKV-subMuxer"
BUNDLE_ID="com.jmkv.submuxer"
VERSION="0.1.3"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_ROOT="$SCRIPT_DIR/build"
DMG_PATH="$OUTPUT_DIR/${PRODUCT_NAME}.dmg"

if ! command -v hdiutil >/dev/null 2>&1; then
  echo "未检测到 hdiutil。此脚本必须在 macOS 上运行。"
  exit 1
fi

if [[ -e "$DMG_PATH" ]]; then
  echo "输出文件已存在：$DMG_PATH"
  echo "请先移动或删除该文件，再重新构建。"
  exit 1
fi

mkdir -p "$BUILD_ROOT"
STAGING_DIR="$(mktemp -d "$BUILD_ROOT/dmg-staging.XXXXXX")"
APP_PATH="$STAGING_DIR/${PRODUCT_NAME}.app"
CONTENTS_DIR="$APP_PATH/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

SWIFT_CACHE="$BUILD_ROOT/swift-module-cache"
mkdir -p "$SWIFT_CACHE"

CLANG_MODULE_CACHE_PATH="$SWIFT_CACHE" swiftc \
  -O \
  -framework AppKit \
  -framework WebKit \
  "$SCRIPT_DIR/JMKVSubMuxerApp.swift" \
  -o "$MACOS_DIR/${PRODUCT_NAME}"

python3 "$SCRIPT_DIR/bundle-homebrew-tools.py" "$RESOURCES_DIR/Tools"
cp "$SCRIPT_DIR/assets/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
cp "$SCRIPT_DIR/assets/app-icon-source.png" "$RESOURCES_DIR/app-icon-source.png"

cp "$SCRIPT_DIR/README.md" "$STAGING_DIR/README.md"
cp "$SCRIPT_DIR/GitHub-Release-Notes.md" "$STAGING_DIR/GitHub-Release-Notes.md"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>${PRODUCT_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${PRODUCT_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleExecutable</key>
  <string>${PRODUCT_NAME}</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon.icns</string>
  <key>LSMinimumSystemVersion</key>
  <string>11.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

echo "APPL????" > "$CONTENTS_DIR/PkgInfo"

ln -s /Applications "$STAGING_DIR/Applications"

if command -v codesign >/dev/null 2>&1; then
  find "$RESOURCES_DIR/Tools" -type f -perm +111 -exec codesign --force --sign - {} \; >/dev/null 2>&1 || true
  codesign --force --deep --sign - "$APP_PATH" >/dev/null 2>&1 || true
fi

hdiutil create \
  -volname "$PRODUCT_NAME" \
  -srcfolder "$STAGING_DIR" \
  -format UDZO \
  "$DMG_PATH"

echo "DMG 已生成：$DMG_PATH"
