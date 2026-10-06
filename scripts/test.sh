#!/bin/sh
# The command line tools keep the Swift Testing macro plugin in a `testing` subfolder,
# and the build does not always search it. Without this path the build fails with
# "plugin for module 'TestingMacros' not found".
set -eu
cd "$(dirname "$0")/.."
PLUGINS="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
swift build --build-tests -Xswiftc -plugin-path -Xswiftc "$PLUGINS"
swift test --skip-build "$@"
