#!/bin/bash
# 构建未签名的 Release 版 IPA，供 SideStore / AltStore 侧载时重新签名。
# 用法：./scripts/build-ipa.sh   产物：build/ZhihuPlusPlus.ipa
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build"
APP_NAME="ZhihuPlusPlus"

rm -rf "$BUILD_DIR/Payload" "$BUILD_DIR/$APP_NAME.ipa"

xcodebuild \
  -project "$ROOT/$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true

APP_PATH="$BUILD_DIR/DerivedData/Build/Products/Release-iphoneos/$APP_NAME.app"
if [ ! -d "$APP_PATH" ]; then
  echo "构建失败：未找到 $APP_PATH" >&2
  exit 1
fi

mkdir -p "$BUILD_DIR/Payload"
cp -R "$APP_PATH" "$BUILD_DIR/Payload/"
(cd "$BUILD_DIR" && zip -qry "$APP_NAME.ipa" Payload)
rm -rf "$BUILD_DIR/Payload"

echo "已生成：$BUILD_DIR/$APP_NAME.ipa"
