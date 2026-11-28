#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
app="${INSPECTOR_BUILD_DIR:-$PWD/build}/oMLX Inspector.app"
mkdir -p build "$app/Contents/MacOS" "$app/Contents/Resources"
python3 Tools/source_files.py > build/swift-sources.list
sources=()
while IFS= read -r -d '' source; do sources+=("$source"); done < build/swift-sources.list
compiler_options=(-parse-as-library)
# Nested compiler-plugin sandboxes are unavailable in some restricted build hosts.
if [ "${INSPECTOR_DISABLE_COMPILER_SANDBOX:-0}" = 1 ]; then compiler_options+=(-disable-sandbox); fi
xcrun swiftc "${compiler_options[@]}" -O -swift-version 6 -target "${INSPECTOR_BUILD_ARCH:-$(uname -m)}-apple-macos27.0" -sdk "$(xcrun --show-sdk-path)" "${sources[@]}" -o "$app/Contents/MacOS/oMLX Inspector"
cp Resources/Info.plist "$app/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$app/Contents/Resources/"; fi
xattr -cr "$app"
codesign --force --sign - --options runtime "$app"
codesign --verify --deep --strict "$app"
echo "$app"
