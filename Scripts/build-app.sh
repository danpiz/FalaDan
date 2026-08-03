#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/version.env"

APP_NAME="FalaDan"
CLI_NAME="faladancli"
BUILD_CONFIG="${1:-release}"
BUILD_DIR=".build/${BUILD_CONFIG}"
APP_BUNDLE="build/${APP_NAME}.app"
BUNDLE_ID_DEBUG="com.faladan.dev"
BUNDLE_ID_RELEASE="com.faladan.app"

if [[ "$BUILD_CONFIG" == "debug" ]]; then
    BUNDLE_ID="$BUNDLE_ID_DEBUG"
    # Same display name as release. Upstream suffixed debug builds with "Dev" to
    # tell two installed copies apart; FalaDan only ever installs the local
    # build, and the bundle IDs already differ, so the suffix was only ever
    # visible clutter in the menu bar and /Applications.
    DISPLAY_NAME="FalaDan"
    FEED_URL=""
    AUTO_CHECKS=false
else
    BUNDLE_ID="$BUNDLE_ID_RELEASE"
    DISPLAY_NAME="FalaDan"
    FEED_URL="https://raw.githubusercontent.com/andyhtran/FalaDan/main/appcast.xml"
    AUTO_CHECKS=true
fi

if [[ -n "${SPARKLE_FEED_URL_OVERRIDE:-}" ]]; then
    if [[ "$BUILD_CONFIG" != "debug" ]]; then
        echo "SPARKLE_FEED_URL_OVERRIDE is only allowed for debug builds." >&2
        exit 1
    fi
    # Local update-flow testing points the feed at a localhost appcast
    # (see Scripts/test-update-flow.sh).
    FEED_URL="$SPARKLE_FEED_URL_OVERRIDE"
fi

echo "Building $APP_NAME ($BUILD_CONFIG)..."

swift build -c "$BUILD_CONFIG" --product "$APP_NAME"
swift build -c "$BUILD_CONFIG" --product "$CLI_NAME"

echo "Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"
cp "$BUILD_DIR/$CLI_NAME" "$APP_BUNDLE/Contents/Resources/"
chmod +x "$APP_BUNDLE/Contents/Resources/$CLI_NAME"

# Embed whisper.framework with proper macOS versioned structure
FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"
if [ -d "$BUILD_DIR/whisper.framework" ]; then
    mkdir -p "$FRAMEWORKS_DIR/whisper.framework/Versions/A"
    cp -R "$BUILD_DIR/whisper.framework/Versions/A/Headers" "$FRAMEWORKS_DIR/whisper.framework/Versions/A/"
    cp -R "$BUILD_DIR/whisper.framework/Versions/A/Modules" "$FRAMEWORKS_DIR/whisper.framework/Versions/A/"
    cp -R "$BUILD_DIR/whisper.framework/Versions/A/Resources" "$FRAMEWORKS_DIR/whisper.framework/Versions/A/"
    cp "$BUILD_DIR/whisper.framework/Versions/A/whisper" "$FRAMEWORKS_DIR/whisper.framework/Versions/A/"
    ln -sf A "$FRAMEWORKS_DIR/whisper.framework/Versions/Current"
    ln -sf Versions/Current/Headers "$FRAMEWORKS_DIR/whisper.framework/Headers"
    ln -sf Versions/Current/Modules "$FRAMEWORKS_DIR/whisper.framework/Modules"
    ln -sf Versions/Current/Resources "$FRAMEWORKS_DIR/whisper.framework/Resources"
    ln -sf Versions/Current/whisper "$FRAMEWORKS_DIR/whisper.framework/whisper"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/Resources/$CLI_NAME" 2>/dev/null || true
fi

# Embed Sparkle.framework
if [[ -d "$BUILD_DIR/Sparkle.framework" ]]; then
    mkdir -p "$FRAMEWORKS_DIR"
    cp -R "$BUILD_DIR/Sparkle.framework" "$FRAMEWORKS_DIR/"
    chmod -R a+rX "$FRAMEWORKS_DIR/Sparkle.framework"
    install_name_tool -add_rpath "@executable_path/../Frameworks" \
        "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true

    SPARKLE_FW="$FRAMEWORKS_DIR/Sparkle.framework"

    if [[ "$BUILD_CONFIG" == "debug" ]]; then
        CODESIGN_ARGS=(--force --sign "-")
    else
        CODESIGN_ARGS=(--force --timestamp --options runtime --sign "${CODESIGN_IDENTITY:--}")
    fi

    resign() { codesign "${CODESIGN_ARGS[@]}" "$1"; }

    resign "$SPARKLE_FW/Versions/B/Sparkle"
    resign "$SPARKLE_FW/Versions/B/Autoupdate"
    resign "$SPARKLE_FW/Versions/B/Updater.app/Contents/MacOS/Updater"
    resign "$SPARKLE_FW/Versions/B/Updater.app"
    resign "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
    resign "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc"
    resign "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer"
    resign "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc"
    resign "$SPARKLE_FW/Versions/B"
    resign "$SPARKLE_FW"
fi

cat > "$APP_BUNDLE/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>${DISPLAY_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${MARKETING_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Andy Tran. All rights reserved.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>FalaDan needs microphone access to record and transcribe speech.</string>
    <key>SUFeedURL</key>
    <string>${FEED_URL}</string>
    <key>SUPublicEDKey</key>
    <string>${SU_PUBLIC_ED_KEY}</string>
    <key>SUEnableAutomaticChecks</key>
    <${AUTO_CHECKS}/>
    <key>SUAutomaticallyUpdate</key>
    <false/>
    <key>SUAllowsAutomaticUpdates</key>
    <false/>
</dict>
</plist>
PLIST

cp "Sources/FalaDan/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"

# Ship Claude Code skills alongside the app so users can toggle them on
# from Settings. See Services/ClaudeSkillManager.swift for the sync logic.
if [ -d "Sources/FalaDan/Resources/skills" ]; then
    cp -R "Sources/FalaDan/Resources/skills" "$APP_BUNDLE/Contents/Resources/"
fi

echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy entitlements (used by signing in justfile, not embedded in bundle)
cp "Sources/FalaDan/Resources/FalaDan.entitlements" "build/"

echo "Bundle created: $APP_BUNDLE"
