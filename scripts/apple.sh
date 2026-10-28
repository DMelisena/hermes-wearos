#!/usr/bin/env bash
# Apple Watch port (apple/, SPEC §14): test the pure core, generate the Xcode project, build.
#   scripts/apple.sh test       # HermesCore unit tests (works with Command Line Tools only)
#   scripts/apple.sh project    # xcodegen → apple/HermesWatch.xcodeproj
#   scripts/apple.sh build      # xcodebuild for the watchOS simulator (needs full Xcode)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APPLE="$ROOT/apple"

cmd="${1:-test}"
case "$cmd" in
  test)
    cd "$APPLE/HermesCore"
    if xcrun --find xctest >/dev/null 2>&1; then
      swift test
    else
      # Command Line Tools ship swift-testing but not on the default search path.
      F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
      swift test -Xswiftc -F"$F" -Xlinker -F"$F" -Xlinker -rpath -Xlinker "$F"
    fi
    ;;
  project)
    command -v xcodegen >/dev/null || { echo "install xcodegen: brew install xcodegen" >&2; exit 1; }
    cd "$APPLE" && xcodegen generate
    ;;
  build)
    "$0" project
    cd "$APPLE"
    xcodebuild -project HermesWatch.xcodeproj -scheme HermesWatch \
      -destination 'generic/platform=watchOS Simulator' -configuration Debug build
    ;;
  *)
    echo "usage: $0 {test|project|build}" >&2; exit 2
    ;;
esac
