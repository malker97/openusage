#!/usr/bin/env bash
# Shared packaging floor. Keep Package.swift's .macOS(.v12) in sync (covered by a regression test).
MIN_SYSTEM_VERSION="12.0"
LINKED_SDK_VERSION="26.0"

require_build_toolchain() {
  local swift_version sdk_version
  swift_version="$(swift --version | awk '/Swift version/ { for (i=1; i<NF; i++) if ($i == "version") { print $(i+1); exit } }')"
  if ! awk -v version="$swift_version" 'BEGIN { split(version, v, "."); exit !(v[1] > 6 || (v[1] == 6 && v[2] >= 2)) }'; then
    echo "Build requires Swift 6.2 or newer; found ${swift_version:-unknown}." >&2
    echo "Running OpenUsage only requires macOS $MIN_SYSTEM_VERSION. Build on a Mac with Xcode 26, or use the CI compatibility artifact; no OS upgrade is needed to run it." >&2
    return 1
  fi
  sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
  if ! awk -v version="$sdk_version" 'BEGIN { split(version, v, "."); exit !(v[1] >= 26) }'; then
    echo "Build requires the macOS 26 SDK (Xcode 26); found $sdk_version. The app still targets macOS $MIN_SYSTEM_VERSION." >&2
    return 1
  fi
}

stamp_linked_sdk() {
  local binary="$1" versions
  versions="$(xcrun vtool -show-build "$binary" | awk '$1 == "minos" { print $2 }')"
  [ -n "$versions" ] || { echo "Cannot read compiler deployment target: $binary" >&2; return 1; }
  for version in $versions; do
    [ "$version" = "$MIN_SYSTEM_VERSION" ] || {
      echo "Compiler targeted $version, expected $MIN_SYSTEM_VERSION: $binary. Refusing to lower minos with vtool." >&2
      return 1
    }
  done
  xcrun vtool -set-build-version macos "$MIN_SYSTEM_VERSION" "$LINKED_SDK_VERSION" \
    -replace -output "$binary.tmp" "$binary"
  mv "$binary.tmp" "$binary"
  chmod +x "$binary"
}
