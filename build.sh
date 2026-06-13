#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="IslandRadio"
APP_BUNDLE="../${APP_NAME}.app"
BUILD_DIR=".build/debug"

echo "==> Building ${APP_NAME}..."
swift build -c debug

echo "==> Updating app bundle..."
cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

echo "==> Signing with ad-hoc identity + entitlements..."
codesign --force --deep --sign - --entitlements "${APP_NAME}.entitlements" "${APP_BUNDLE}"

echo "==> Clearing quarantine attributes..."
xattr -cr "${APP_BUNDLE}"

echo "==> Done! Run: open ${APP_BUNDLE}"