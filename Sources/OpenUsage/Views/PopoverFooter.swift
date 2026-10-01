import SwiftUI
import Perception

/// Fixed popover footer chrome: app identity, refresh status, dashboard actions, and copy confirmation.
/// It uses the destination screen so both pages mounted during a slide draw the same footer.
struct PopoverFooter: View {
    let screen: PopoverScreen
    let layout: LayoutStore
    let dataStore: WidgetDataStore
    let horizontalPadding: CGFloat
    let onHeightChange: (PopoverScreen, CGFloat) -> Void

    @ViewBuilder
    var body: some View {
        WithPerceptionTracking { trackedBody }
    }

    private var trackedBody: some View {
        Group {
            if screen == .customize {
                EmptyView()
            } else {
                HStack(alignment: .center, spacing: 8) {
                    footerIdentity
                    Spacer(minLength: 8)
                    HeaderView(screen: screen)
                }
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .barGlass()
        .background(GeometryReader { proxy in
            Color.clear.preference(key: FooterHeightKey.self, value: proxy.size.height)
        })
        .onPreferenceChange(FooterHeightKey.self) { height in
            onHeightChange(screen, height)
        }
        .overlay(alignment: .top) {
            WithPerceptionTracking {
                if screen == .dashboard, layout.shareConfirmation {
                    shareCopiedPill
                        .offset(y: -34)
                }
            }
        }
        .animation(Motion.spring, value: layout.shareConfirmation)
        .animation(Motion.spring, value: layout.shareConfirmationTrigger)
    }

    private struct FooterHeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }

    private var shareCopiedPill: some View {
        TransientPill(
            systemImage: "checkmark.circle.fill",
            text: "Copied to clipboard",
            tint: Theme.positive,
            trigger: layout.shareConfirmationTrigger
        )
    }

    private var footerIdentity: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("OpenUsage \(AppInfo.version)")
            if let notice = layout.pinLimitNotice {
                Text(notice)
                    .foregroundStyle(Theme.notice)
                    .denyShake(trigger: layout.pinNoticeShakeTrigger, shakeOnAppear: true)
            } else {
                nextUpdateButton
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .animation(Motion.spring, value: layout.pinLimitNotice)
    }

    private var nextUpdateButton: some View {
        Button {
            refreshNow()
        } label: {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                WithPerceptionTracking {
                    HStack(spacing: 5) {
                        Text(updateStatusText(now: context.date))
                            .monospacedDigit()
                            .numericTextTransition()
                        if isUpdating {
                            MotionAwareProgressView(controlSize: .mini)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("r", modifiers: .command)
        .hoverTooltip("Refresh now (⌘R)")
        .disabled(isUpdating)
    }

    private var isUpdating: Bool {
        !dataStore.refreshingProviderIDs.isEmpty
    }

    private func refreshNow() {
        guard !isUpdating else { return }
        Task { await dataStore.refreshAll(force: true) }
    }

    private func updateStatusText(now: Date) -> String {
        if isUpdating { return "Updating…" }
        let base = dataStore.lastRefreshAt ?? now
        let remaining = max(0, base.addingTimeInterval(RefreshSetting.interval).timeIntervalSince(now))
        let totalSeconds = Int(remaining.rounded(.up))
        if totalSeconds >= 60 {
            let minutes = Int((Double(totalSeconds) / 60).rounded(.up))
            return "Next update in \(minutes)m"
        }
        return "Next update in \(totalSeconds)s"
    }
}
