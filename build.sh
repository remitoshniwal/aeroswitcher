#!/bin/bash
set -e

APP_NAME="AeroSwitcher"
APP_BUNDLE="$APP_NAME.app"

# Which identity to sign with is decided first, before the slow build, so a
# typo stops the script in a second instead of after the whole compile.
# (The signing itself happens at the very end.)
#
# Background: macOS ties the permissions you grant (Input Monitoring, Screen
# Recording) to who signed the app. A certificate in your own Keychain that
# stays the same keeps the permissions across rebuilds, which is why the
# project's own builds use one named exactly AeroSwitcherCodeSign (README and
# installation guide say how to make it, once).
#
# Which identity is used:
#   - SIGN_IDENTITY set (e.g. SIGN_IDENTITY="Developer ID Application: ..."):
#     that one. It has to exist in your Keychain, or the build stops, so a
#     typo can never produce a quietly wrongly signed app. SIGN_IDENTITY=-
#     means "ad hoc" on purpose (no certificate at all).
#   - Not set, AeroSwitcherCodeSign exists: that one, exactly as before.
#   - Not set, no such certificate: sign ad hoc and say so. The app works,
#     but macOS counts every rebuild as a new app and asks for the
#     permissions again each time. The certificate is the fix for that.
# `-v` lists only certificates that are valid for signing.
if [ -n "$SIGN_IDENTITY" ]; then
    IDENTITY="$SIGN_IDENTITY"
    if [ "$IDENTITY" != "-" ] && ! security find-identity -v -p codesigning | grep -qF "\"$IDENTITY\""; then
        echo "ERROR: SIGN_IDENTITY is \"$IDENTITY\", but no valid signing certificate with that name is in your Keychain."
        echo "Run: security find-identity -v -p codesigning   (it lists the names you can use)"
        exit 1
    fi
elif security find-identity -v -p codesigning | grep -qF '"AeroSwitcherCodeSign"'; then
    IDENTITY="AeroSwitcherCodeSign"
else
    IDENTITY="-"
    FELL_BACK=1
fi

# Which kinds of Mac the app is built for. By default both: arm64 (Apple
# silicon) and x86_64 (Intel), joined into one "universal" program, so one
# download runs on either. Each kind is compiled on its own, into its own
# folder under .build, and then glued together with `lipo`. (The one-command
# way, `swift build --arch arm64 --arch x86_64`, needs the full Xcode app,
# this works with just the Command Line Tools.) To build only for the Mac you
# are on, which is quicker, run: ARCHS=arm64 ./build.sh   (or ARCHS=x86_64).
ARCHS="${ARCHS:-arm64 x86_64}"
BINARIES=()
for ARCH in $ARCHS; do
    echo "Building for $ARCH..."
    swift build -c release --triple "$ARCH-apple-macosx14.0" --scratch-path ".build/$ARCH"
    BINARIES+=(".build/$ARCH/$ARCH-apple-macosx/release/$APP_NAME")
done

echo "Assembling app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
lipo -create "${BINARIES[@]}" -output "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
echo "Architectures: $(lipo -archs "$APP_BUNDLE/Contents/MacOS/$APP_NAME")"
cp Info.plist "$APP_BUNDLE/Contents/Info.plist"
# The app icon (AppIcon.icns, made by make-icon.swift). Info.plist's
# CFBundleIconFile points at it by name. `set -e` above stops the build here
# if the file is missing, instead of quietly making an icon-less app.
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

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

if [ -n "$FELL_BACK" ]; then
    echo
    echo "NOTE: no AeroSwitcherCodeSign certificate found, so this build is signed ad hoc."
    echo "It works, but macOS will ask for Input Monitoring and Screen Recording again"
    echo "after every rebuild. To avoid that, create the certificate once (see the"
    echo "README or docs/AeroSwitcher_Installation_Guide.md, step 5a) and build again."
    echo
fi

if [ "$IDENTITY" = "-" ]; then
    echo "Signing ad hoc (no certificate)..."
else
    echo "Signing with \"$IDENTITY\"..."
fi
codesign --force --deep --sign "$IDENTITY" "$APP_BUNDLE"

echo "Done. Built: $APP_BUNDLE"
