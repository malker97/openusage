# Monterey Compatibility Validation

## Host

- macOS 12.6.8, build 21G725, arm64.
- Apple Swift 5.7.2; command-line tools only, with the macOS 13.1 SDK.

## Passed Locally

A standalone smoke executable compiled the actual `Locked.swift`, `AsyncDelay.swift`, and
`ViewImageRenderer.swift` sources for macOS 12. Only the app logging seam was stubbed; providers and
telemetry were not started.

It verified concurrent locked updates, fractional delay conversion, cancellation of a long delay,
and off-screen SwiftUI rendering on Monterey. Transparent shapes, Canvas content used by menu-bar
bars, and text rendered successfully at 2× scale. The executable also ran after stamping its linked
SDK to 26.0 and re-signing it, while preserving minos 12.0.

The packaging checker accepted a fixture with both executables targeting 12.0 and rejected an
embedded executable targeting 13.0. SDK stamping refused to rewrite a fixture reporting minos 15.0.
View-source parsing, shell syntax checks, and `git diff --check` passed.

## Still Required

These checks are **not** a successful full app build or an end-to-end Monterey app test.

- `swift build` is blocked by the installed Swift 5.7 toolchain; the package needs Swift 6.2.
- `swift test` is also blocked: this command-line-tools installation reports XCTest unavailable.
- Dependency resolution and the regenerated `Package.resolved` need the newer build toolchain.
- The new CI workflow and the full regression suite have not been run from this machine.
- Build the complete app with Xcode 26, then run the [compatibility smoke checklist](../compatibility.md#verification)
  on Monterey and on a newer macOS before publishing a release.
