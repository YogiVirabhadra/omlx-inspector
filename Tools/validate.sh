#!/bin/bash
# Complete local validation. The optional 2 GiB test is enabled with --large.
set -euo pipefail
cd "$(dirname "$0")/.."

# `swift test` needs XCTest, which ships with Xcode but not with the Command Line Tools.
# An explicit DEVELOPER_DIR always wins. Otherwise use the xcode-select choice, falling back
# to /Applications/Xcode.app when that choice is the Command Line Tools (or nothing at all).
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || true)"
  if [[ -z "$DEVELOPER_DIR" || "$DEVELOPER_DIR" == */CommandLineTools* ]]; then
    xcode=/Applications/Xcode.app/Contents/Developer
    if [[ -d "$xcode" ]]; then
      echo "xcode-select selects ${DEVELOPER_DIR:-no developer directory}, which has no XCTest; using $xcode." >&2
      DEVELOPER_DIR="$xcode"
    else
      cat >&2 <<'MESSAGE'
validate.sh needs Xcode: the tests use XCTest, which the Command Line Tools do not include.
No Xcode was found at /Applications/Xcode.app. Either install Xcode, or point to your copy:

  DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer Tools/validate.sh

To make that choice permanent for this Mac:

  sudo xcode-select -s /path/to/Xcode.app/Contents/Developer
MESSAGE
      exit 1
    fi
  fi
elif [[ ! -d "$DEVELOPER_DIR" ]]; then
  echo "DEVELOPER_DIR does not exist: $DEVELOPER_DIR" >&2
  exit 1
fi
export DEVELOPER_DIR
export PYTHONDONTWRITEBYTECODE=1
case "${1:-}" in
  --large) export INSPECTOR_LARGE_LOG_BYTES="${INSPECTOR_LARGE_LOG_BYTES:-2147483648}" ;;
  '') ;;
  *) echo 'Usage: Tools/validate.sh [--large]' >&2; exit 2 ;;
esac
swift test -c release
python3 Tools/test_source_files.py
# The Xcode project is generated; fail if regenerating it changes anything.
project='oMLX Inspector.xcodeproj/project.pbxproj'
previous="$(mktemp)"
cp "$project" "$previous"
python3 Tools/make_project.py
if ! cmp -s "$previous" "$project"; then
  rm -f "$previous"
  echo "$project was out of date and has been regenerated; review and commit it." >&2
  exit 1
fi
rm -f "$previous"
python3 Tools/check_format.py
git diff --check
bash Tools/build.sh
