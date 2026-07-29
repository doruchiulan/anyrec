import CoreGraphics
import Foundation
import ScreenCaptureKit

public enum CaptureTarget: Sendable, Equatable {
    case display(index: Int)
    case window(id: CGWindowID)
}

public enum TargetError: Error, LocalizedError, CustomStringConvertible {
    case displayOutOfRange(index: Int, count: Int)
    case windowNotFound(CGWindowID)

    /// Both of these are answered by listing the targets again, which every interface
    /// does its own way — so neither says how.
    public var description: String {
        switch self {
        case .displayOutOfRange(let index, let count):
            "Display \(index) does not exist — this Mac has \(count)."
        case .windowNotFound(let id):
            "No capturable window with id \(id). It may have been closed."
        }
    }

    public var errorDescription: String? { description }
}

public struct ResolvedTarget {
    public let filter: SCContentFilter
    public let width: Int
    public let height: Int
    public let describing: String
}
