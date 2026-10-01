# macOS Compatibility

This checkout targets **macOS 12 (Monterey) and later**, including macOS 12.6.8 on Apple Silicon.
Existing published releases may still require macOS 15; editing their Info.plist does not make them
compatible. Use a newly built app instead. The compatibility app has now built on CI and run on
Monterey; see the [validation record](testing/macos-monterey.md). Finish the full smoke checklist
before publishing these changes as a release.

## What Works Differently

Usage fetching, menu-bar metrics, customization, notifications, and PNG sharing keep the same code
paths. State changes use Perception, an Observation backport, so refreshes still update the interface
on systems older than macOS 14. Monterey uses AppKit to render menu-bar images and share cards.
Loading and sync status also use a Monterey-safe path so changing activity state cannot trip the
older system's native progress-control layout checks.

**Launch at Login** works on Monterey through a per-user launcher instead of the macOS 13 login-item
registry; the Settings switch behaves the same. TLS connections to an `https://` proxy require macOS 14; `http://` and
`socks5://` proxies are supported on Monterey (see [Proxy](proxy.md)). Providers and their own coding
tools may have separate OS requirements.

## Build Without Upgrading the Target Mac

Building and running have different requirements:

- **Run:** macOS 12 or later.
- **Build:** Swift 6.2 or later and the macOS 26 SDK (Xcode 26), on a Mac that can run that toolchain.

The CI workflow builds on a newer Mac while keeping the Monterey deployment target. Push these
changes to your fork's main branch, run **Actions → CI → Run workflow**, then download the
**OpenUsage-Monterey** artifact from the
successful run. Extract the artifact and its inner zip, move OpenUsage.app to Applications, and open
it on the older Mac. The artifact is a host-architecture development build, not a universal release.

This development app has separate settings and no automatic updates. Its default development iCloud
container is also separate from released apps. To join those Macs, explicitly select **production**
for **icloud_history** when running the workflow, then download **OpenUsage-Monterey-production-history**.
See [iCloud Sync](icloud-sync.md#development-and-release-setup). The ad-hoc artifact has no iCloud
provisioning profile, so container access and delivery must be verified on the target Mac.
It is ad-hoc signed rather than notarized; if Gatekeeper blocks your own build, use the system's
**Open Anyway** action after checking its origin. No security setting needs to be turned off globally.

### Personal Build for Everyday Use

For a copy you keep in Applications, run the workflow with **package → personal** (and
**icloud_history → production** to sync with Macs running released OpenUsage). This produces the
**OpenUsage-Monterey-personal-production-history** artifact: an optimized build labeled with the
upstream version it is based on (for example `0.7.13-beta.3-monterey`), with telemetry switched off
so it never reports into the official project's analytics. The artifact is kept for one day.
Download it, then replace `/Applications/OpenUsage.app` with the extracted app. It keeps the same
settings and iCloud identity as earlier compatibility builds. It doesn't update itself; repeat these
steps for a newer build.

The OpenUsage name and logo are covered by the [trademark policy](../TRADEMARK.md): keep such builds
for personal use rather than publishing them.

## Verification

CI builds and runs the regression tests, including an explicitly forced Monterey image-rendering
path. Packaging also checks Info.plist and every embedded executable/framework's actual deployment
target. SDK stamping refuses to lower a binary's compiler-selected minimum OS.

Before release, test the complete app on Monterey: launch, credential loading, refresh and live
menu-bar updates, opening/closing the panel, scrolling, Customize, Settings, hover details, keyboard
shortcuts, PNG sharing, and quit/relaunch. Also smoke-test a newer macOS to confirm its native path.
