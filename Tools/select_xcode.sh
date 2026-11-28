# Sourced by build.sh and validate.sh to choose the developer directory.
# SwiftUI's macro plugins and XCTest ship with Xcode, not with the Command Line Tools.
# An explicit DEVELOPER_DIR always wins. Otherwise use the xcode-select choice, falling back
# to /Applications/Xcode.app when that choice is the Command Line Tools (or nothing at all).
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || true)"
  if [[ -z "$DEVELOPER_DIR" || "$DEVELOPER_DIR" == */CommandLineTools* ]]; then
    xcode=/Applications/Xcode.app/Contents/Developer
    if [[ -d "$xcode" ]]; then
      echo "xcode-select selects ${DEVELOPER_DIR:-no developer directory}, which is not a full Xcode; using $xcode." >&2
      DEVELOPER_DIR="$xcode"
    else
      script="Tools/$(basename "$0")"
      cat >&2 <<MESSAGE
$script needs Xcode: SwiftUI's macros and XCTest are not in the Command Line Tools.
No Xcode was found at /Applications/Xcode.app. Either install Xcode, or point to your copy:

  DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer $script

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
