#!/bin/bash
# Complete local validation. The optional 2 GiB test is enabled with --large.
set -euo pipefail
cd "$(dirname "$0")/.."

source Tools/select_xcode.sh
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
