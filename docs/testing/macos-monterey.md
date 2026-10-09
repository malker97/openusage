# Monterey Compatibility Validation

## Build

The complete app builds and tests on GitHub Actions with a Monterey deployment target.

- Source: `543a5450` on `malker97/openusage`.
- [Successful CI run](https://github.com/malker97/openusage/actions/runs/37890573339), manually dispatched
  with `package=personal` and `icloud_history=production`; artifact:
  **OpenUsage-Monterey-personal-production-history**.
- Build host: macOS 26 arm64, Swift 6.3.3, macOS 26.5 SDK.
- Tests: 1,547 executed, 3 skipped, 0 failures.
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

## Low-Space Failure and Recovery

A later real sync failure was caused by macOS refusing iCloud downloads: Cocoa error 640 reported
about 2.84 GB available with a 3.22 GB reserve required. The original reader threw on the download
error before reading valid cached JSON, which removed both peer Macs and reverted combined usage.

The fix separates download failures from invalid history. It retains coordinated, validated cached
files, shows a low-space/stale-data warning, backs failed download requests off to once a minute,
and watches only the selected container's history. Corrupt files are still rejected. Regression tests
cover cached history under metadata/request errors, retry backoff, and recovery/warning removal.

Disk space was subsequently restored to about 20 GiB; no personal files were deleted by the agent.
After deploying the new artifact, a roughly 11-minute soak sampled the live app 22 times and crossed
two automatic refresh batches. All samples succeeded with the same process, combined usage remained
visible, and logs kept three Macs including two peers. Six later peer updates automatically went from
one pending download to zero. At the final check all three files were current and uploaded, with no
upload/download error, new crash, or Perception fault. Low-space behavior is covered by injected
regression tests; the test did not refill the user's disk to reproduce the shortage.

## Installed Personal Build

The personal package is an optimized build (34 MB, versus 68 MB for the debug artifact) labeled
`0.7.13-beta.3-monterey`, build 629, with telemetry off and no update feed. It was downloaded with
the GitHub CLI, so it carries no quarantine flag, then installed as `/Applications/OpenUsage.app`.
Its nested signatures verified after installation.

Verified on the Monterey host:

- Startup logged the new version, `telemetry inert`, and the dormant updater. Settings hid the
  analytics switch and showed the new version in the footer.
- Existing settings and iCloud identity carried over. Sync loaded the same three Macs and kept
  updating this Mac's existing file, with no duplicate device. No Keychain prompt appeared.
- Launch at Login is now a working switch on Monterey. Turning it on wrote a per-user launcher that
  opens `/Applications/OpenUsage.app`. A simulated login (`launchctl bootstrap` after quitting the app)
  started the installed app, and the switch still read on after relaunch.
- A 6.5-minute soak crossed an automatic refresh with the same process, combined usage updating,
  current uploaded iCloud files, and no crash or Perception runtime warning.
- Earlier extracted test copies were removed so Spotlight and LaunchServices can't open an old
  debug build; their CI zips were kept.

The Mac's Spotlight index was read-only at the time (likely left over from the earlier low-space
period), so the new install wasn't searchable yet. Launchpad, Finder, and login launch don't depend on it.

## Memory Leak Found After a Week

After about eight days of continuous running, the installed build had a 763 MB memory footprint. It
hadn't crashed: the process was still alive, there was no crash or hang report, and the panel still
opened in about half a second. A heap snapshot showed the cause:

- 113,934 pending Perception observations and 809,925 retained closures (430 MB).
- 88,615 copies of a single row's density setting storage, plus 9,225 copies of the Settings screen's
  storage. Each pending observation was holding a copy of the view that created it.

On macOS 13 and earlier, Perception's `WithPerceptionTracking` adds an observation on every re-render
and removes an older one only when the state it read changes (an open upstream problem,
pointfreeco/swift-perception#51; 2.0.12 is the latest release). Views re-render for other reasons too.
Over the week the log recorded 13,522 iCloud reloads, each re-rendering the dashboard (even while it
was hidden), plus 30-second reset-countdown ticks. Views that read rarely changing state, such as row
hover state and settings stores, piled up observations. Changing that state, for example by opening
the panel, flushed thousands at once.

The fix replaces all 31 uses with `PerceptionScope`, which retires the previous observation before
installing its replacement. Regression tests prove repeated evaluations keep exactly one
observation, re-evaluation cancels observation of state no longer read, and retiring never triggers an
extra render. A control test documents the upstream accumulation.

On the Monterey host, the fixed build (632) replaced the leaking one:

| | Leaking build, day 8 | Fixed build, 1 min | Fixed build, 23 min |
|---|---|---|---|
| Pending observations | 113,934 | 35 | 44 |
| Retained closures | 809,925 | 4,067 | 7,447 |
| Footprint | 763 MB | 50 MB | 73 MB |

The 23-minute sample covered 32 iCloud reloads and 3 refreshes; the leaking build would have added
about 400 observations in that time. The live heap grew from 19.6 MB to 27.6 MB while the panel,
Settings, and the UI-automation accessibility tree were first built. After that it stayed flat: 27.77 MB
at 43 minutes, still with 44 pending observations. The leaking build's live heap was 596 MB. Footprint
kept rising to 90 MB because the allocator retains memory that refreshes free; most of it is reported as
reclaimable. Dashboard, Settings, Back, Esc, sync with three Macs, and refreshes all worked.

## Remaining Checks

This is a development artifact, not a notarized or universal release. Finish the full
[compatibility smoke checklist](../compatibility.md#verification) before publishing a release,
especially drag/reorder, keyboard shortcut recording, and hover details.
