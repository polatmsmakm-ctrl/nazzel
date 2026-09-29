import ActivityKit
import Foundation

/// The download progress shown on the Lock Screen and in the Dynamic Island.
/// (This file is part of both the app and the widget extension.)
@available(iOS 16.1, *)
struct DownloadActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// What is downloading now (or the summary when everything finished).
        var title: String
        /// 0...1, nil while it is still reading the link.
        var fraction: Double?
        /// Short line under the title: speed, size, "جاري التجهيز"…
        var detail: String
        /// How many downloads are still running.
        var active: Int
        /// True for the last update, when everything is done.
        var finished: Bool
    }
}
