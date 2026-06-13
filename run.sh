#!/bin/bash
# Island Radio — Build & Run script
# Usage: ./run.sh [build|run|clean]

set -e
cd "$(dirname "$0")"

APP_NAME="IslandRadio"
APP_DIR=".build/${APP_NAME}.app"
ENTITLEMENTS="/tmp/${APP_NAME}.entitlements"

# Detect build architecture automatically
ARCH=$(uname -m)
BUILD_TRIPLE="${ARCH}-apple-macosx"
BINARY=".build/${BUILD_TRIPLE}/debug/${APP_NAME}"

build() {
    echo "==> Building..."
    swift build

    echo "==> Creating app bundle..."
    rm -rf "$APP_DIR"
    mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
    cp "$BINARY" "$APP_DIR/Contents/MacOS/${APP_NAME}"

    # Copy app icon
    ICON_SRC="src/Resources/IslandRadio.icns"
    [ -f "$ICON_SRC" ] && cp "$ICON_SRC" "$APP_DIR/Contents/Resources/IslandRadio.icns"

    # Copy resource bundle if exists
    BUNDLE=".build/${BUILD_TRIPLE}/debug/${APP_NAME}_${APP_NAME}.bundle"
    [ -d "$BUNDLE" ] && cp -R "$BUNDLE" "$APP_DIR/Contents/Resources/"

    # Info.plist
    cat > "$APP_DIR/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>IslandRadio</string>
    <key>CFBundleIdentifier</key>
    <string>com.islandradio.app</string>
    <key>CFBundleName</key>
    <string>Island Radio</string>
    <key>CFBundleDisplayName</key>
    <string>Island Radio</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>IslandRadio</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Island Radio needs microphone access for speech recognition.</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST

    # Entitlements
    cat > "$ENTITLEMENTS" << 'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>com.apple.security.network.server</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
ENT

    codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP_DIR"
    echo "==> Build complete: $APP_DIR"
}

run() {
    # Kill existing instance
    pkill -f "${APP_NAME}.app/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
    sleep 0.5
    echo "==> Launching..."
    open "$APP_DIR"
}

clean() {
    echo "==> Cleaning..."
    swift package clean
    rm -rf "$APP_DIR"
    echo "==> Clean complete"
}

case "${1:-run}" in
    build)
        build
        ;;
    run)
        build
        run
        ;;
    clean)
        clean
        ;;
    *)
        echo "Usage: $0 [build|run|clean]"
        exit 1
        ;;
esac
