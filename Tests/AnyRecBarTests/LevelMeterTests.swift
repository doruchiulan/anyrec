import AppKit
import Observation
import SwiftUI
import Testing
import AnyRecKit

@testable import AnyRecBar

@Suite("Live audio meter", .serialized)
@MainActor
struct LevelMeterTests {
    @Observable
    final class Source {
        let levels = LevelMonitor()
        var tick = 0
    }

    struct Probe: View {
        let source: Source

        var body: some View {
            let _ = source.tick
            RecordingMeters(tracks: AudioTrack.allCases, levels: source.levels)
        }
    }

    @Test("refreshes a displayed meter when capture updates the same monitor")
    func refreshes() async throws {
        let source = Source()
        let host = NSHostingView(rootView: Probe(source: source))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 70),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        try await waitForMeters(in: host, source: source, peak: -48, fraction: 0.2)
        let initial = try pixels(of: #require(indicators(in: host).first))

        try await waitForMeters(in: host, source: source, peak: -6, fraction: 0.9)
        #expect(try pixels(of: #require(indicators(in: host).first)) != initial)

        try await waitForMeters(in: host, source: source, peak: nil, fraction: 0)
    }

    private func waitForMeters(in host: NSView, source: Source,
                               peak: Float?, fraction: Double) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if let peak {
                for track in AudioTrack.allCases {
                    source.levels.record(AudioLevel(peak: peak, rms: peak), for: track)
                }
            }
            source.tick += 1
            try await Task.sleep(for: .milliseconds(20))
            host.layoutSubtreeIfNeeded()
            let meters = indicators(in: host)
            if meters.count == 2 && meters.allSatisfy({ abs($0.doubleValue - fraction) < 0.01 }) {
                return
            }
        }
        Issue.record("Meters did not reach \(fraction): \(indicators(in: host).map(\.doubleValue))")
    }

    private func indicators(in view: NSView) -> [NSLevelIndicator] {
        if let indicator = view as? NSLevelIndicator { return [indicator] }
        return view.subviews.flatMap { indicators(in: $0) }
    }

    private func pixels(of view: NSView) throws -> Data {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}
