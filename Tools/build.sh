#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
app="$PWD/build/oMLX Inspector.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
python3 Tools/source_files.py > build/swift-sources.list
sources=()
while IFS= read -r -d '' source; do sources+=("$source"); done < build/swift-sources.list
xcrun swiftc -parse-as-library -O -swift-version 6 -target arm64-apple-macos27.0 -sdk "$(xcrun --show-sdk-path)" "${sources[@]}" -o "$app/Contents/MacOS/oMLX Inspector"
cp Resources/Info.plist "$app/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$app/Contents/Resources/"; fi
codesign --force --sign - --options runtime "$app"
codesign --verify --deep --strict "$app"
echo "$app"
