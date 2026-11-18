import AppKit
import Observation
import SwiftUI
import Testing
import AnyRecKit

@testable import AnyRecBar

@Suite("Live level bars", .serialized)
@MainActor
struct LevelMeterTests {
    @Test("Normal speech is green, not a warning; only near clipping is orange")
    func tints() {
        #expect(LevelBars.bar(.systemAudio, peak: -9, muted: false).tint == .healthy,
                "−9 dB is ordinary speech; NSLevelIndicator painted it yellow")
        #expect(LevelBars.bar(.systemAudio, peak: -0.5, muted: false).tint == .hot)
        #expect(LevelBars.bar(.microphone, peak: -50, muted: false).tint == .quiet)
        #expect(LevelBars.bar(.microphone, peak: -120, muted: false).tint == .quiet)
        let muted = LevelBars.bar(.microphone, peak: -6, muted: true)
        #expect(muted.tint == .muted)
        #expect(muted.fraction <= 0.1, "a muted microphone is drawn low whatever it picks up in the room")
        #expect(abs(LevelBars.bar(.systemAudio, peak: -30, muted: false).fraction - Double(MeterScale.fraction(-30))) < 0.0001)
    }

    @Observable
    final class Source {
        let levels = LevelMonitor()
        var tick = 0
    }

    struct Probe: View {
        let source: Source

        var body: some View {
            let _ = source.tick
            LevelBars(tracks: AudioTrack.allCases, levels: source.levels, microphoneMuted: false)
        }
    }

    @Test("A displayed bar redraws when capture updates the same monitor")
    func refreshes() async throws {
        let source = Source()
        let host = NSHostingView(rootView: Probe(source: source))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }

        let quiet = try await settle(host, source: source, peak: -48)
        let loud = try await settle(host, source: source, peak: -6)
        #expect(quiet != loud)
    }

    private func settle(_ host: NSView, source: Source, peak: Float) async throws -> Data {
        for track in AudioTrack.allCases {
            source.levels.record(AudioLevel(peak: peak, rms: peak), for: track)
        }
        source.tick += 1
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}
