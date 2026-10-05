#!/bin/bash
# Builds build/Cortexy.app (ad-hoc signed). Needs only Xcode Command Line Tools.
#   ./build.sh            build
#   ./build.sh install    build, copy to /Applications, launch
#   ./build.sh dist       build for Apple silicon and Intel, zipped to share: build/Cortexy-<version>.zip
#   ./build.sh test       run the tests
set -euo pipefail
cd "$(dirname "$0")"

if [[ "${1:-}" == "test" ]]; then
    # Command Line Tools keep the Testing macro plugin in a subfolder the compiler doesn't search.
    exec swift test -Xswiftc -plugin-path -Xswiftc "$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
fi

# To share, one binary for both kinds of Mac (macOS 26 is the last for Intel ones); here, just this Mac's.
ARCH=()
[[ "${1:-}" == "dist" ]] && ARCH=(--arch arm64 --arch x86_64)
swift build -c release ${ARCH[@]+"${ARCH[@]}"}
APP=build/Cortexy.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release ${ARCH[@]+"${ARCH[@]}"} --show-bin-path)/Cortexy" "$APP/Contents/MacOS/Cortexy"
cp Resources/AppIcon.icns Resources/Cortexy.sdef "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.cortexy.app</string>
    <key>CFBundleName</key><string>Cortexy</string>
    <key>CFBundleExecutable</key><string>Cortexy</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.10.2</string>
    <key>CFBundleVersion</key><string>13</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSAppleScriptEnabled</key><true/>
    <key>OSAScriptingDefinition</key><string>Cortexy.sdef</string>
    <key>NSServices</key>
    <array><dict>
        <key>NSMenuItem</key><dict><key>default</key><string>New Cortexy Note</string></dict>
        <key>NSMessage</key><string>newNote</string>
        <key>NSPortName</key><string>Cortexy</string>
        <key>NSSendTypes</key><array><string>public.utf8-plain-text</string><string>NSStringPboardType</string></array>
    </dict></array>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleURLTypes</key>
    <array><dict>
        <key>CFBundleURLName</key><string>com.cortexy.app</string>
        <key>CFBundleURLSchemes</key><array><string>cortexy</string></array>
    </dict></array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "dist" ]]; then
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
    ZIP="build/Cortexy-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP" # keeps the signature and bundle intact (Finder's Compress does the same)
    echo "Packed $ZIP ($(lipo -archs "$APP/Contents/MacOS/Cortexy")) — see README → Running it on another Mac"
fi

if [[ "${1:-}" == "install" ]]; then
    pkill -x Cortexy || true
    rm -rf /Applications/Cortexy.app
    cp -R "$APP" /Applications/
    open /Applications/Cortexy.app
    echo "Installed to /Applications"
fi
