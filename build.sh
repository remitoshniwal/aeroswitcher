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

echo "Signing with our stable certificate..."
codesign --force --deep --sign "AeroSwitcherCodeSign" "$APP_BUNDLE"

echo "Done. Built: $APP_BUNDLE"
