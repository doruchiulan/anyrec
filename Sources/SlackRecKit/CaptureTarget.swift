import CoreGraphics
import Foundation
import ScreenCaptureKit

public enum CaptureTarget: Sendable, Equatable {
    /// Every window belonging to an application, composited on its display.
    case application(bundleID: String)
    case display(index: Int)
    case window(id: CGWindowID)

    public static let slackBundleID = "com.tinyspeck.slackmacgap"
    public static var slack: CaptureTarget { .application(bundleID: slackBundleID) }
}

public enum TargetError: Error, CustomStringConvertible {
    case applicationNotRunning(String)
    case noDisplays
    case displayOutOfRange(index: Int, count: Int)
    case windowNotFound(CGWindowID)

    public var description: String {
        switch self {
        case .applicationNotRunning(let id):
            "No running application with bundle id \(id). Open Slack and join the call first."
        case .noDisplays:
            "ScreenCaptureKit reported no capturable displays."
        case .displayOutOfRange(let index, let count):
            "Display \(index) does not exist (\(count) available). Run `slack-rec displays`."
        case .windowNotFound(let id):
            "No capturable window with id \(id). Run `slack-rec windows`."
        }
    }
}

public struct ResolvedTarget {
    public let filter: SCContentFilter
    public let width: Int
    public let height: Int
    public let describing: String
}
