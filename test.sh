#!/bin/bash
# Runs the DiscodromeCore test suite. With only the Command Line Tools installed, SwiftPM's
# default build system doesn't hand the Swift Testing macro plugin to the compiler, so point
# it there explicitly.
set -euo pipefail
cd "$(dirname "$0")"
PLUGINS="$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins/testing"
exec swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
