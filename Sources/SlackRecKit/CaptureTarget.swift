import CoreGraphics
import Foundation
import ScreenCaptureKit

public enum CaptureTarget: Sendable, Equatable {
    case display(index: Int)
    case window(id: CGWindowID)
}

public enum TargetError: Error, CustomStringConvertible {
    case displayOutOfRange(index: Int, count: Int)
    case windowNotFound(CGWindowID)

    public var description: String {
        switch self {
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
