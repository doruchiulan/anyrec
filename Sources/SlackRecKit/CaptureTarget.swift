import CoreGraphics
import Foundation
import ScreenCaptureKit

public enum CaptureTarget: Sendable, Equatable {
    /// Every window belonging to an application, composited on its display.
    case application(bundleID: String)
    case display(index: Int)
    case window(id: CGWindowID)
    /// The first known call app that is running — see `CallApps.known`.
    case autoDetect

    public static let slackBundleID = "com.tinyspeck.slackmacgap"
    public static var slack: CaptureTarget { .application(bundleID: slackBundleID) }
}

public enum TargetError: Error, CustomStringConvertible {
    case applicationNotRunning(String)
    case noCallAppRunning
    case noDisplays
    case displayOutOfRange(index: Int, count: Int)
    case windowNotFound(CGWindowID)

    public var description: String {
        switch self {
        case .applicationNotRunning(let id):
            "No running application with bundle id \(id). Open it and join the call first."
        case .noCallAppRunning:
            """
            No call app is running. Looked for \
            \(CallApps.known.filter { !$0.isBrowser }.map(\.name).joined(separator: ", ")).
            Open one, or capture something else with --display, --window or --bundle-id.
            """
        case .noDisplays:
            "ScreenCaptureKit reported no capturable displays."
        case .displayOutOfRange(let index, let count):
            "Display \(index) does not exist (\(count) available). Run `slack-rec sources`."
        case .windowNotFound(let id):
            "No capturable window with id \(id). Run `slack-rec sources`."
        }
    }
}

public struct ResolvedTarget {
    public let filter: SCContentFilter
    public let width: Int
    public let height: Int
    public let describing: String
}
