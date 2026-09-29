import ActivityKit
import SwiftUI
import WidgetKit

@main
struct NazzelWidgets: WidgetBundle {
    var body: some Widget {
        DownloadLiveActivity()
    }
}

/// Download progress on the Lock Screen and in the Dynamic Island.
struct DownloadLiveActivity: Widget {
    private let tint = Color(red: 0.05, green: 0.58, blue: 0.53)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            LockScreenDownloadView(state: context.state, tint: tint)
                .environment(\.layoutDirection, .rightToLeft)
                .activityBackgroundTint(Color.black.opacity(0.78))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.finished ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                        .font(.title2)
                        .foregroundStyle(tint)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(percent(context.state))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.state.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        ProgressView(value: context.state.finished ? 1 : (context.state.fraction ?? 0))
                            .tint(tint)
                        Text(context.state.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .environment(\.layoutDirection, .rightToLeft)
                }
            } compactLeading: {
                Image(systemName: context.state.finished ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(tint)
            } compactTrailing: {
                Text(percent(context.state))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white)
            } minimal: {
                Gauge(value: context.state.finished ? 1 : (context.state.fraction ?? 0)) {
                    Image(systemName: "arrow.down")
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(tint)
            }
        }
    }

    private func percent(_ state: DownloadActivityAttributes.ContentState) -> String {
        if state.finished { return "✓" }
        guard let fraction = state.fraction else { return "…" }
        return "\(Int((min(1, max(0, fraction)) * 100).rounded()))%"
    }
}

private struct LockScreenDownloadView: View {
    let state: DownloadActivityAttributes.ContentState
    let tint: Color

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.18), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: state.finished ? 1 : CGFloat(state.fraction ?? 0.02))
                    .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: state.finished ? "checkmark" : "arrow.down")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 4) {
                Text(state.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(state.detail)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                if state.active > 1, !state.finished {
                    Text("و\(state.active - 1) تحميلات ثانية")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("نزّل")
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
        }
        .padding(16)
    }
}
