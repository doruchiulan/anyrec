import AnyRecKit
import CoreGraphics
import Foundation

struct CallWindowMatch {
    struct Candidate {
        let id: CGWindowID
        let processID: pid_t
        let bounds: CGRect
        let title: String?
        let layer: Int
    }

    static func choice(for window: MuteButton.Window, in candidates: [Candidate]) -> CaptureChoice? {
        let matching = candidates.filter {
            $0.id != kCGNullWindowID && $0.layer == 0 && $0.processID == window.processID
                && near($0.bounds, window.bounds)
        }
        let title = window.title.flatMap { $0.isEmpty ? nil : $0 }
        let named = title.map { name in matching.filter { $0.title == name } } ?? []
        let eligible = named.isEmpty
            ? matching.filter { title == nil || $0.title == nil || $0.title?.isEmpty == true }
            : named
        guard eligible.count == 1, let candidate = eligible.first else { return nil }
        return CaptureChoice(target: .window(id: candidate.id), label: title ?? candidate.title,
                             ownerPID: window.processID)
    }

    private static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        a.width > 0 && a.height > 0 && b.width > 0 && b.height > 0
            && abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1
            && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }
}
