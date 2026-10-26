#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
driver_binary="${1:-/tmp/AudioPatchDerived/Build/Products/Debug/AudioPatch.driver/Contents/MacOS/AudioPatch}"
test_directory="$(mktemp -d /tmp/AudioPatchDriverTests.XXXXXX)"
trap 'rm -rf "$test_directory"' EXIT
xcrun clang++ -std=c++20 -Wall -Wextra DriverTests/DriverHostTests.cpp -framework CoreFoundation -o "$test_directory/host-tests"
"$test_directory/host-tests" "$driver_binary"
