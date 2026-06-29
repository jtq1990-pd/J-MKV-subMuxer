#!/usr/bin/env bash
set -euo pipefail

PRODUCT_NAME="J-MKV-subMuxer"
BUNDLE_ID="com.jmkv.submuxer"
VERSION="0.1.4"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_ROOT="$SCRIPT_DIR/build"
FIXED_ROOT="$OUTPUT_DIR/${PRODUCT_NAME}-fixed"
APP_PATH="$FIXED_ROOT/${PRODUCT_NAME}.app"
CONTENTS_DIR="$APP_PATH/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ZIP_PATH="$OUTPUT_DIR/${PRODUCT_NAME}-fixed.zip"

if [[ -e "$FIXED_ROOT" || -e "$ZIP_PATH" ]]; then
  echo "输出已存在：$FIXED_ROOT 或 $ZIP_PATH"
  echo "请先手动移走旧文件，再重新构建。"
  exit 1
fi

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$BUILD_ROOT/swift-module-cache"

CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/swift-module-cache" swiftc \
  -O \
  -framework AppKit \
  -framework WebKit \
  "$SCRIPT_DIR/JMKVSubMuxerApp.swift" \
  -o "$MACOS_DIR/${PRODUCT_NAME}"

python3 "$SCRIPT_DIR/bundle-homebrew-tools.py" "$RESOURCES_DIR/Tools"
cp "$SCRIPT_DIR/assets/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
cp "$SCRIPT_DIR/assets/app-icon-source.png" "$RESOURCES_DIR/app-icon-source.png"

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

if command -v codesign >/dev/null 2>&1; then
  find "$RESOURCES_DIR/Tools" -type f -perm +111 -exec codesign --force --sign - {} \; >/dev/null 2>&1 || true
  codesign --force --deep --sign - "$APP_PATH" >/dev/null 2>&1 || true
fi

ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "修复版 App：$APP_PATH"
echo "修复版 ZIP：$ZIP_PATH"
