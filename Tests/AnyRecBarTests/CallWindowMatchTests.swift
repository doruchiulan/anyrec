import CoreGraphics
import Foundation
import Testing

@testable import AnyRecBar
@testable import AnyRecKit

@Suite("Call banner recording target")
struct CallWindowMatchTests {
    private let bounds = CGRect(x: 100, y: 200, width: 900, height: 600)

    @Test("records the attached call window rather than another window or app")
    func attachedWindow() throws {
        let choice = try #require(CallWindowMatch.choice(for: reference(), in: [
            candidate(1, bounds: CGRect(x: 0, y: 0, width: 1400, height: 900)),
            candidate(2, processID: 99), candidate(37),
        ]))
        #expect(choice.target == .window(id: 37))
        #expect(choice.ownerPID == 42)
        #expect(choice.label == "Meeting")
    }

    @Test("uses the call title to distinguish overlapping windows from the same process")
    func overlappingWindows() {
        let choice = CallWindowMatch.choice(for: reference(), in: [
            candidate(1, title: "Chat"), candidate(2),
        ])
        #expect(choice?.target == .window(id: 2))
    }

    @Test("supports a missing window-server title when the process and bounds identify one window")
    func missingTitle() {
        #expect(CallWindowMatch.choice(for: reference(), in: [candidate(3, title: nil)])?.target == .window(id: 3))
        #expect(CallWindowMatch.choice(for: reference(title: nil), in: [candidate(3)])?.target == .window(id: 3))
    }

    @Test("refuses ambiguous targets instead of picking the first window")
    func ambiguous() {
        #expect(CallWindowMatch.choice(for: reference(), in: [candidate(1), candidate(2)]) == nil)
        #expect(CallWindowMatch.choice(for: reference(title: nil), in: [candidate(1), candidate(2)]) == nil)
    }

    @Test("does not substitute another app, title, popup or moved window for a missing call")
    func unavailable() {
        let candidates = [candidate(1, processID: 99), candidate(2, title: "Chat"),
                          candidate(3, layer: 3), candidate(4, bounds: CGRect(x: 50, y: 50, width: 900, height: 600))]
        #expect(CallWindowMatch.choice(for: reference(), in: candidates) == nil)
        #expect(CallWindowMatch.choice(for: reference(), in: []) == nil)
    }

    @Test("tolerates a point of coordinate rounding but rejects invalid window geometry and IDs")
    func geometry() {
        let rounded = bounds.offsetBy(dx: 0.5, dy: -0.5)
        #expect(CallWindowMatch.choice(for: reference(), in: [candidate(1, bounds: rounded)]) != nil)
        #expect(CallWindowMatch.choice(for: reference(), in: [candidate(0), candidate(1, bounds: .zero)]) == nil)
    }

    private func reference(title: String? = "Meeting") -> MuteButton.Window {
        MuteButton.Window(identity: UUID(), processID: 42, bounds: bounds, title: title)
    }

    private func candidate(_ id: CGWindowID, processID: pid_t = 42, title: String? = "Meeting",
                           layer: Int = 0, bounds: CGRect? = nil) -> CallWindowMatch.Candidate {
        CallWindowMatch.Candidate(id: id, processID: processID, bounds: bounds ?? self.bounds,
                                 title: title, layer: layer)
    }
}
