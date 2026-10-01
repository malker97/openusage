# macOS Compatibility

This checkout targets **macOS 12 (Monterey) and later**, including macOS 12.6.8 on Apple Silicon.
Existing published releases may still require macOS 15; editing their Info.plist does not make them
compatible. Use a newly built app instead. A full Monterey app smoke test is still required before
publishing these changes as a release.

## What Works Differently

Usage fetching, menu-bar metrics, customization, notifications, and PNG sharing keep the same code
paths. State changes use Perception, an Observation backport, so refreshes still update the interface
on systems older than macOS 14. Monterey uses AppKit to render menu-bar images and share cards.

**Launch at Login requires macOS 13 or later.** On Monterey, Settings explains that limitation instead
of offering a non-working switch. You can add the app manually in **System Preferences → Users &
Groups → Login Items**. TLS connections to an `https://` proxy require macOS 14; `http://` and
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

This development app has separate settings, no automatic updates, and no provisioned iCloud sync.
It is ad-hoc signed rather than notarized; if Gatekeeper blocks your own build, use the system's
**Open Anyway** action after checking its origin. No security setting needs to be turned off globally.

## Verification

CI builds and runs the regression tests, including an explicitly forced Monterey image-rendering
path. Packaging also checks Info.plist and every embedded executable/framework's actual deployment
target. SDK stamping refuses to lower a binary's compiler-selected minimum OS.

Before release, test the complete app on Monterey: launch, credential loading, refresh and live
menu-bar updates, opening/closing the panel, scrolling, Customize, Settings, hover details, keyboard
shortcuts, PNG sharing, and quit/relaunch. Also smoke-test a newer macOS to confirm its native path.
