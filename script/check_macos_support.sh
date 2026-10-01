#!/usr/bin/env bash
set -euo pipefail

# Check every shipped Mach-O, not just Info.plist: changing the install gate cannot back-deploy code.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/macos_support.sh"
APP_BUNDLE="${1:?usage: check_macos_support.sh <app-bundle>}"
PLIST="$APP_BUNDLE/Contents/Info.plist"
PLIST_MIN="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")"
[ "$PLIST_MIN" = "$MIN_SYSTEM_VERSION" ] || {
  echo "Info.plist minimum is $PLIST_MIN, expected $MIN_SYSTEM_VERSION" >&2
  exit 1
}
for binary in "$APP_BUNDLE/Contents/MacOS/OpenUsage" "$APP_BUNDLE/Contents/Helpers/openusage"; do
  [ -x "$binary" ] || { echo "Missing executable: $binary" >&2; exit 1; }
done

find "$APP_BUNDLE" -type f -print0 | while IFS= read -r -d '' binary; do
  if ! file -b "$binary" | grep -q 'Mach-O'; then continue; fi
  versions="$(xcrun vtool -show-build "$binary" | awk '
    $1 == "cmd" { legacy = ($2 == "LC_VERSION_MIN_MACOSX") }
    $1 == "minos" || ($1 == "version" && legacy) { print $2 }
  ')"
  [ -n "$versions" ] || { echo "Cannot read deployment target: $binary" >&2; exit 1; }
  for version in $versions; do
    if ! awk -v actual="$version" -v expected="$MIN_SYSTEM_VERSION" 'BEGIN {
      split(actual, a, "."); split(expected, e, ".");
      exit !(a[1] < e[1] || (a[1] == e[1] && (a[2] < e[2] || (a[2] == e[2] && a[3] <= e[3]))))
    }'; then
      echo "Incompatible deployment target $version (expected <= $MIN_SYSTEM_VERSION): $binary" >&2
      exit 1
    fi
  done
  echo "==> compatible Mach-O ($versions): $binary"
done
