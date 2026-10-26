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
        for track in AudioTrack.allCases {
            source.levels.record(AudioLevel(peak: -48, rms: -50), for: track)
        }
        let host = NSHostingView(rootView: Probe(source: source))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 70),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        #expect(indicators(in: host).count == 2)
        #expect(indicators(in: host).allSatisfy { abs($0.doubleValue - 0.2) < 0.01 })
        let initial = try pixels(of: #require(indicators(in: host).first))

        for track in AudioTrack.allCases {
            source.levels.record(AudioLevel(peak: -6, rms: -10), for: track)
        }
        source.tick += 1
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        #expect(indicators(in: host).allSatisfy { abs($0.doubleValue - 0.9) < 0.01 })
        #expect(try pixels(of: #require(indicators(in: host).first)) != initial)

        try await Task.sleep(for: .milliseconds(450))
        source.tick += 1
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        #expect(indicators(in: host).allSatisfy { $0.doubleValue == 0 })
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
