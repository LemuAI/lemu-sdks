#!/bin/sh
# Runs `swift test`. With only the Command Line Tools installed (no Xcode),
# SwiftPM doesn't find the swift-testing framework on its own, so pass its path.
set -e
cd "$(dirname "$0")/.."
DEV="$(xcode-select -p 2>/dev/null || true)"
case "$DEV" in
  *CommandLineTools*)
    F="$DEV/Library/Developer/Frameworks"
    L="$DEV/Library/Developer/usr/lib"
    exec swift test \
      -Xswiftc -F -Xswiftc "$F" \
      -Xlinker -F -Xlinker "$F" \
      -Xlinker -rpath -Xlinker "$F" \
      -Xlinker -rpath -Xlinker "$L" "$@"
    ;;
  *)
    exec swift test "$@"
    ;;
esac
