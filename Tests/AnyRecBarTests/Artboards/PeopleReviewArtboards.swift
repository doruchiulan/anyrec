import AppKit
import SwiftUI
import Testing
@testable import AnyRecBar
@testable import AnyRecKit

@MainActor
@Suite("People review artboards")
struct PeopleReviewArtboards {
    @Test func renderPeopleReview() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lines = [
            Utterance(start: 13, end: 15, text: "I'll send the notes.", speaker: .others),
            Utterance(start: 21, end: 23, text: "Thanks.", speaker: .others),
            Utterance(start: 26, end: 29, text: "See you Thursday.", speaker: .named("Alex Morgan"))
        ]
        let library = VoiceLibrary(people: [.init(name: "Taylor Reed", prints: [])])
        let fixes = [0, 1].map {
            SpeakerCorrection(line: $0, from: .others, to: .named("Alex Morgan"), reason: "Continues the sentence.",
                              quote: lines[$0].text, evidenceLine: 2, sure: false)
        }
        let speakers = RecordingSpeakers.build(lines: lines, voices: nil, suggestions: [], corrections: fixes,
                                              participants: nil, info: nil, library: library)
        let entry = RecordingLibrary.entry(at: directory)
        let desk = SpeakerDesk(directory: directory, controller: RecordingController(completedSetup: true))
        let playback = Playback(entry)
        func card(_ kind: RecordingSpeakers.Question.Kind) -> some View {
            QuestionCard(question: .init(kind: kind, id: "review"), position: 0, count: 1,
                         desk: desk, speakers: speakers, playback: playback, app: nil, names: [.others: "Not sure who"],
                         done: { _ in }, skip: { _ in }, move: { _ in }, listen: {}, asked: { _ in })
        }
        try render("likely-names", card(.fixes(fixes)).frame(width: 540))
        try render("mixed-voice", card(.sort(.others, names: ["Alex Morgan", "Sam Parker"], lines: [0, 1],
                                             guesses: [0: "Alex Morgan", 1: "Sam Parker"])).frame(width: 500))
        try render("unclaimed-lines", card(.unnamedBits(lines: [0, 1], seconds: 4, onlyOther: .named("Alex Morgan"))).frame(width: 500))
        let picker = PersonPickerContent(speakers: speakers, title: "Who said this?", current: nil,
                                         exclude: .others, offersMe: true, startsWithSearch: true, pick: { _ in })
        try render("someone-else", picker)
    }

    @Test func unnamedVoices() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let info = RecordingInfo(title: "Thursday planning", bundleID: "com.tinyspeck.slackmacgap",
                                 width: 0, height: 0, fps: 0, audioOnly: true,
                                 startedAt: Date(timeIntervalSince1970: 1750000000))
        try OutputPlan(directory: directory).layout.prepare()
        try info.write(to: directory)
        let lines = [Utterance(start: 0, end: 2, text: "I'll send the notes.", speaker: .others)]
        try TranscriptStore.publish(Transcript(utterances: lines, language: "en", engine: "test"), voices: nil, in: directory)
        let entry = RecordingLibrary.entry(at: directory)
        #expect(LibraryFilter.unnamed.includes(entry))
        try render("unnamed-voices", LibraryRow(entry: entry, working: false, progress: nil).frame(width: 340))
        try SpeakerEditing.reassign([0], to: .me, in: directory)
        #expect(!LibraryFilter.unnamed.includes(RecordingLibrary.entry(at: directory)))
    }

    private func render(_ name: String, _ view: some View) throws {
        let content = view.padding(10).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: content)
        let size = host.fittingSize
        #expect(size.width > 250 && size.height > 50)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        if let path = ProcessInfo.processInfo.environment["ANYREC_ARTBOARDS"] {
            try png.write(to: URL(filePath: path).appendingPathComponent(name + ".png"), options: .atomic)
        }
    }
}
