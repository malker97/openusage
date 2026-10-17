import Foundation

/// DeepSeek's output speed, read from pi's session logs.
///
/// DeepSeek's API exposes no usage, quota, or history endpoint — only a prepaid balance — so this card is
/// deliberately one row: the speed of the replies pi recorded, timed from request to last token. It shows
/// no spend and makes no network request. The credential probe is what turns it on for a machine where pi
/// already has a DeepSeek key (the source of the logged usage).
@MainActor
final class DeepSeekProvider: ProviderRuntime {
    let provider = Provider(
        id: "deepseek",
        displayName: "DeepSeek",
        icon: .providerMark("deepseek"),
        links: [
            ProviderLink(label: "Dashboard", url: "https://platform.deepseek.com/usage")
        ]
    )

    private let piScanner: PiUsageScanner
    private let authStore: DeepSeekAuthStore
    private let now: @Sendable () -> Date

    init(
        piScanner: PiUsageScanner = .shared,
        authStore: DeepSeekAuthStore = DeepSeekAuthStore(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.piScanner = piScanner
        self.authStore = authStore
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .values(
                id: "\(provider.id).outputSpeed", provider: provider, title: OutputSpeedMapper.label,
                selection: .kind(.count)
            )
        ]
    }

    func hasLocalCredentials() async -> Bool {
        await loadOffMainActor { [authStore] in authStore.hasPiAPIKey() }
    }

    func refresh() async -> ProviderSnapshot {
        let timestamp = now()
        var lines: [MetricLine] = []
        // pi is the only local source that times DeepSeek replies; without it the row reads "No data".
        if let timings = await piScanner.timings(cardID: provider.id, now: timestamp) {
            OutputSpeedMapper.appendOutputSpeed(timings, to: &lines, now: timestamp)
        }
        MetricLine.appendNoDataIfNeeded(&lines)
        return ProviderSnapshot.make(provider: provider, plan: nil, lines: lines, refreshedAt: timestamp)
    }
}
