import AnyRecKit
import SwiftUI

/// The recording page's speakers as the Kit reads them, and the changes the panel and the
/// transcript's labels make. Read off the main thread — it loads the voice library — when
/// the recording or its transcript changes, never from a view's body.
@MainActor
@Observable
final class SpeakerDesk {
    let directory: URL
    private let controller: RecordingController
    private(set) var speakers: RecordingSpeakers?
    var failure: String?

    init(directory: URL, controller: RecordingController) {
        self.directory = directory
        self.controller = controller
    }

    /// The call window's polls, kept from the first read or handed over by the page: they do
    /// not change once the call is over, and decoding them was half of every read on a long call.
    var participants: CallParticipants??
    /// The transcript files the latest read started from, and which read that is. Every
    /// answer reads again and also moves the library entry, whose change asks the page to
    /// read again: the second ask finds the same files and is not made.
    private var loadedRevision: Date??
    private var latest: UUID?

    func load() async {
        let directory = directory
        let revision = TranscriptStore.revision(of: TranscriptStore.layerFiles(in: directory))
        guard loadedRevision != .some(revision) else { return }
        loadedRevision = .some(revision)
        let read = UUID()
        latest = read
        let cached = participants
        let (found, observed) = await Task.detached(priority: .userInitiated) {
            let observed = cached ?? CallParticipants.read(in: directory)
            return (RecordingSpeakers.read(in: directory, participants: observed), observed)
        }.value
        participants = .some(observed)
        guard latest == read else { return }
        speakers = found
    }

    var busy: Bool { controller.working.contains(directory) }

    func accept(_ correction: SpeakerCorrection, as choice: PersonChoice? = nil) {
        guard let speakers else { return }
        let target = choice.map { $0.target(in: speakers) } ?? correction.to
        perform { try TranscriptSpeakerReview.apply(correction, as: target, in: directory) }
    }

    func keep(_ correction: SpeakerCorrection) {
        perform { try TranscriptSpeakerReview.dismiss(correction, in: directory) }
    }

    // MARK: People in this call

    /// Who an answer names: someone already speaking in this recording, or a name (a person
    /// the call window showed, one from the library, or someone new).
    enum PersonChoice: Equatable {
        case speaker(Speaker)
        case name(String, person: String?)

        func target(in speakers: RecordingSpeakers) -> Speaker {
            switch self {
            case .speaker(let speaker): speaker
            case .name(let name, _): speakers.speaker(named: name)
            }
        }
    }

    /// The answer to "who is this?" about a whole person. Someone already in this recording
    /// takes all of their lines (two rows become one); anyone else becomes their name, and
    /// the library keeps the voice when it safely can. Unclaimed bits are given line by line.
    func assign(_ speaker: Speaker, to choice: PersonChoice) {
        guard let speakers else { return }
        let lines = speakers.lineIndexes(of: speaker)
        switch (speaker, choice) {
        case (.others, .speaker(let target)): perform { try SpeakerEditing.reassign(lines, to: target, in: directory) }
        case (.others, .name(let name, _)): perform { try SpeakerEditing.reassign(lines, to: speakers.speaker(named: name), in: directory) }
        case (_, .speaker(let target)) where target == speaker: return
        case (_, .speaker(.me)): perform { try SpeakerEditing.giveToMe(speaker, in: directory) }
        case (_, .speaker(let target)): perform { try SpeakerEditing.give(speaker, to: target, in: directory) }
        case (_, .name(let name, let person)): perform { try SpeakerEditing.name(speaker, name, in: directory, person: person) }
        }
    }

    /// One line, or a few, to someone.
    func assignLines(_ lines: [Int], to choice: PersonChoice) {
        guard let speakers else { return }
        let target = choice.target(in: speakers)
        perform { try SpeakerEditing.reassign(lines, to: target, in: directory) }
    }

    /// Lines given to the person the call window showed during each, as one answer, one Undo.
    func assignGuesses(_ guesses: [Int: String]) {
        guard let speakers, !guesses.isEmpty else { return }
        let byName = Dictionary(grouping: guesses.keys, by: { guesses[$0]! })
        perform {
            var written: [URL] = []
            for (name, lines) in byName {
                written += try SpeakerEditing.reassign(lines.sorted(), to: speakers.speaker(named: name), in: directory)
            }
            return written
        }
    }

    /// The model that reads the call for the review, which also places the lines nobody claimed.
    var reviewProvider: SummaryProvider { controller.transcriptionOptions.reviewProvider }

    /// Asking the review's model who said the lines nobody claimed: true while it reads.
    private(set) var asking = false

    /// Sends the lines nobody claimed, each with the lines around it and what the call window
    /// showed, to the review's model. Its answers come back as fixes to confirm: the ones it is
    /// sure of as one group, the likely ones one by one. Nothing is assigned. Says what it found.
    func askAboutUnclaimed() async -> String? {
        guard !busy, !asking else { return nil }
        asking = true
        defer { asking = false }
        let directory = directory, provider = reviewProvider
        let result: Result<(asked: Int, placement: UnclaimedLineReview.Placement), Error> = await Task.detached(priority: .userInitiated) {
            do { return .success(try await UnclaimedLineReview.suggest(in: directory, using: provider)) } catch { return .failure(error) }
        }.value
        controller.reloadPeople()
        await controller.reloadLibrary()
        await load()
        switch result {
        case .success(let outcome):
            failure = nil
            return Wording.unclaimedPlaced(asked: outcome.asked, sure: outcome.placement.sure.count,
                                           likely: outcome.placement.likely.count, provider: provider.name)
        case .failure(let error):
            failure = error.localizedDescription
            return nil
        }
    }

    func confirm(_ speaker: Speaker, as name: String) {
        perform { try SpeakerEditing.name(speaker, name, in: directory) }
    }

    func sort(_ speaker: Speaker, picks: [Int: Speaker]) {
        perform { try SpeakerEditing.sort(speaker, picks: picks, in: directory) }
    }

    func acceptAll(_ corrections: [SpeakerCorrection]) {
        perform { try TranscriptSpeakerReview.apply(corrections, in: directory) }
    }

    /// Every answer can be taken back: the transcript's selection and layers, and the voice
    /// library, as they were just before it.
    private struct Snapshot {
        let files: [URL: Data]
        let library: VoiceLibrary
    }
    private var history: [Snapshot] = []
    var canUndo: Bool { !history.isEmpty }

    private func snapshot() -> Snapshot {
        let layout = RecordingLayout(directory: directory)
        var files: [URL: Data] = [:]
        for url in [layout.selection] + layout.files(in: .transcripts) + [layout.directory.appendingPathComponent("Transcript.md")] {
            if let data = try? Data(contentsOf: url) { files[url] = data }
        }
        return Snapshot(files: files, library: VoiceLibrary.load())
    }

    func undo() {
        guard !busy, let last = history.popLast() else { return }
        let layout = RecordingLayout(directory: directory)
        for url in layout.files(in: .transcripts) where last.files[url] == nil { try? FileManager.default.removeItem(at: url) }
        for (url, data) in last.files { try? data.write(to: url, options: .atomic) }
        try? last.library.save()
        _ = try? TranscriptStore.render(in: directory)
        failure = nil
        controller.reloadPeople()
        Task {
            await controller.reloadLibrary()
            await load()
        }
    }

    /// Each change is one small file and a re-render, so it runs here and then the library
    /// is re-read: the entry's revision moves and the page reloads what it shows.
    private func perform(_ change: () throws -> [URL]) {
        guard !busy else { return }
        history.append(snapshot())
        if history.count > 20 { history.removeFirst() }
        do {
            _ = try change()
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        controller.reloadPeople()
        Task {
            await controller.reloadLibrary()
            await load()
        }
    }
}
