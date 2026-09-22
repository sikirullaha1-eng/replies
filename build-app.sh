#!/bin/bash
# Builds Replies.app — a real double-clickable Mac app. No Xcode required.
set -e
cd "$(dirname "$0")"

APP="Replies.app"
BIN="Replies"

echo "Compiling…"
rm -rf "$APP" "$BIN"
# Sources are nested, so gather them with find rather than a flat glob.
SRC=$(find Sources -name '*.swift' | sort)
if [ -z "$SRC" ]; then echo "No sources found under Sources/"; exit 1; fi
# shellcheck disable=SC2086
swiftc -O -parse-as-library $SRC -o "$BIN"

echo "Packaging…"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$BIN" "$APP/Contents/MacOS/$BIN"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Replies</string>
    <key>CFBundleDisplayName</key>       <string>Replies</string>
    <key>CFBundleExecutable</key>        <string>Replies</string>
    <key>CFBundleIdentifier</key>        <string>com.sikiru.replies</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>26.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>LSApplicationCategoryType</key> <string>public.app-category.utilities</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
</dict>
</plist>
PLIST

if [ -f AppIcon.icns ]; then cp AppIcon.icns "$APP/Contents/Resources/"; fi

echo "Signing…"
codesign --force --deep --sign - "$APP" 2>/dev/null || codesign --force --sign - "$APP"

echo
echo "Built:  $(pwd)/$APP"
echo "Open it with:   open \"$APP\""
