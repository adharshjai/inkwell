#!/bin/zsh
# Builds Inkwell.app from the SwiftPM release binary + generated icon.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/Inkwell.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Inkwell "$APP/Contents/MacOS/Inkwell"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Inkwell</string>
    <key>CFBundleDisplayName</key>     <string>Inkwell</string>
    <key>CFBundleIdentifier</key>      <string>app.inkwell.Inkwell</string>
    <key>CFBundleExecutable</key>      <string>Inkwell</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>2.7</string>
    <key>CFBundleVersion</key>         <string>3</string>
    <key>LSMinimumSystemVersion</key>  <string>26.0</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.education</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key> <false/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key> <string>PDF Document</string>
            <key>CFBundleTypeRole</key> <string>Editor</string>
            <key>LSHandlerRank</key>    <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array><string>com.adobe.pdf</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1
echo "Built $APP"
