#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/build/Richard.app"
XCODE_BUILD_DIR="$ROOT_DIR/build/xcode"

xcodebuild \
  -project "$ROOT_DIR/Richard.xcodeproj" \
  -scheme Richard \
  -configuration Debug \
  -destination 'platform=macOS' \
  CONFIGURATION_BUILD_DIR="$XCODE_BUILD_DIR" \
  build

rm -rf "$APP_DIR"
mkdir -p "$(dirname "$APP_DIR")"
cp -R "$XCODE_BUILD_DIR/Richard.app" "$APP_DIR"

echo "$APP_DIR"
