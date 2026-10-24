#!/bin/bash
set -e

APP_NAME="AeroSwitcher"
BUILD_DIR=".build/release"
APP_BUNDLE="$APP_NAME.app"

echo "Building..."
swift build -c release

echo "Assembling app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"
cp Info.plist "$APP_BUNDLE/Contents/Info.plist"

# Version numbers. The version people read ("0.9.0") is the one line you edit
# by hand, CFBundleShortVersionString in Info.plist. The build number and the
# commit are worked out here from git and written only into the copy of
# Info.plist inside the app, so the file in the repo never changes because of
# a build. Without git (a ZIP download) the build still works, it just says
# build 0 and commit "unknown". "-dirty" means there were uncommitted changes,
# so a test build can be told apart from a committed one.
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo 0)
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
if [ "$COMMIT" != "unknown" ] && [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    COMMIT="$COMMIT-dirty"
fi
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_NUMBER" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :AeroSwitcherCommit string $COMMIT" "$APP_BUNDLE/Contents/Info.plist"
echo "Version: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist") (build $BUILD_NUMBER, $COMMIT)"

echo "Signing with our stable certificate..."
codesign --force --deep --sign "AeroSwitcherCodeSign" "$APP_BUNDLE"

echo "Done. Built: $APP_BUNDLE"
