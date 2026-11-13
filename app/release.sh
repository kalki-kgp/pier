#!/bin/sh
# Builds a self-contained Pier.app (its own Python + engine) and packs dist/Pier-<version>.dmg.
set -e
cd "$(dirname "$0")"
./build.sh
APP="Pier.app"
RES="$APP/Contents/Resources"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)

# A relocatable CPython (python-build-standalone, as uv installs it).
uv python install 3.13 >/dev/null
PY_HOME=$(dirname "$(dirname "$(uv python find 3.13)")")
cp -R "$PY_HOME" "$RES/python"
rm -rf "$RES/python/lib/python3.13/test" "$RES/python/lib/python3.13/idlelib" \
       "$RES/python/lib/python3.13/tkinter" "$RES/python/lib/python3.13/turtledemo" "$RES/python/share"
PY="$RES/python/bin/python3.13"

# The engine and its packages, outside the interpreter so PYTHONPATH picks them up.
mkdir -p "$RES/engine"
cp -R ../engine/pierd "$RES/engine/"
uv pip install -q --python "$PY" --target "$RES/engine/site-packages" -r ../engine/pyproject.toml
find "$RES" -name "__pycache__" -type d -prune -exec rm -rf {} +
# Compile now: the app must never write into its own signed bundle.
"$PY" -m compileall -q -j 0 "$RES/engine" "$RES/python/lib/python3.13" >/dev/null || true

codesign --force --deep --sign - --identifier dev.kalki.pier "$APP"
codesign --verify --deep --strict "$APP"

mkdir -p dist
DMG="dist/Pier-$VERSION.dmg"
rm -f "$DMG"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
create-dmg \
    --volname "Pier $VERSION" \
    --volicon Assets/AppIcon.icns \
    --window-size 540 360 \
    --icon-size 112 \
    --icon "Pier.app" 140 170 \
    --app-drop-link 400 170 \
    --hide-extension "Pier.app" \
    --no-internet-enable \
    "$DMG" "$STAGE" >/dev/null
rm -rf "$STAGE"
du -sh "$APP" "$DMG"
