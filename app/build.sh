#!/bin/sh
# Builds Pier.app with the Command Line Tools alone (no Xcode project).
set -e
cd "$(dirname "$0")"
APP="Pier.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macosx26.0 \
    -framework SwiftUI -framework AppKit \
    Sources/*.swift -o "$APP/Contents/MacOS/Pier"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --identifier dev.kalki.pier "$APP"
echo "built $PWD/$APP"
