# Monterey Compatibility Validation

## Build

The complete app builds and tests on GitHub Actions with a Monterey deployment target.

- Source: `d0325460` on `malker97/openusage`.
- [Successful CI run](https://github.com/malker97/openusage/actions/runs/36815457185), manually dispatched
  with `icloud_history=production`; artifact: **OpenUsage-Monterey-production-history**.
- Build host: macOS 26 arm64, Swift 6.3.3, macOS 26.5 SDK.
- Tests: 1,529 executed, 3 skipped, 0 failures.
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

## Cross-Mac Sync Check

The initial compatibility artifact used the isolated development container, so its local device row
was not evidence that it could sync with Macs running released OpenUsage. The production-history
artifact explicitly joins the released app's container while keeping separate `.dev` preferences.

Verified on Monterey with the real iCloud account:

- Two peer files were present in the production container, initially as remote-only placeholders.
- The new app loaded both peers, wrote this Mac's own separate file, and listed all three Macs in
  Settings. Logs identify the production container and report `3 Macs (2 peers, 0 pending downloads)`.
- macOS reported this Mac's production file as uploaded, with no upload or download error.
- The local usage API changed from local-only to combined spend/token totals.
- Subsequent real peer updates triggered automatic downloads and reloads. Pending downloads went
  from one to zero twice, about three to four seconds apart, without a manual app refresh.
- The process remained running, with no new Perception runtime warnings.

The other Macs' screens have not been inspected from this machine. Confirm the new Mac appears there
after iCloud delivery; a local write alone is not an end-to-end receipt acknowledgement.

## Remaining Checks

This is a development artifact, not a notarized or universal release. Finish the full
[compatibility smoke checklist](../compatibility.md#verification) before publishing a release,
especially drag/reorder, keyboard shortcut recording, and hover details.
