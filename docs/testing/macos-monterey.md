# Monterey Compatibility Validation

## Build

The complete app builds and tests on GitHub Actions with a Monterey deployment target.

- Source: `2d316008` on `malker97/openusage`.
- [Successful CI run](https://github.com/malker97/openusage/actions/runs/36812162489).
- Build host: macOS 26 arm64, Swift 6.3.3, macOS 26.5 SDK.
- Tests: 1,522 executed, 3 skipped, 0 failures.
- The app and CLI are arm64; embedded Sparkle code includes both architectures.
- Info.plist and every shipped Mach-O passed the macOS 12 deployment check.
- The dependency lockfile was resolved on CI and committed.

## Monterey Smoke Test

Test host: macOS 12.6.8 (21G725), MacBook Air arm64. The CI artifact was downloaded, extracted, and
its nested code signatures verified before launching the app bundle.

Passed:

- App startup and menu-bar rendering; bundled CLI help.
- Real Claude and Codex refreshes, with dashboard and menu-bar usage displayed.
- Dashboard and Settings navigation; Monterey's Launch at Login limitation displayed correctly.
- iCloud activity regression: the original build trapped in SwiftUI's native-control layout checks
  when sync activity appeared. The fixed build uses a fixed-size Monterey activity path.
- Sync was disabled/enabled three times on the real Settings screen without another crash; the
  device list showed this Mac and its update time. Sync was left enabled as it was before the test.
- Relaunch with sync still enabled; Claude/Codex refreshes succeeded again.
- Deferred hover bindings no longer emitted the earlier Perception runtime warnings.

The earlier standalone smoke checks also passed: locked concurrent updates, fractional delay
conversion, cancellation, and transparent shape/Canvas/text rendering at 2×. CI forces the legacy
rendering path, including a real share-card PNG export and finite activity-indicator sizes.

## Remaining Checks

This is a development artifact, not a notarized or universal release. A second Mac is still needed to
verify actual cross-device history merging. Finish the full [compatibility smoke checklist](../compatibility.md#verification)
before publishing a release, especially drag/reorder, keyboard shortcut recording, and hover details.
