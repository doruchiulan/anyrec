import Foundation
import Testing
@testable import AnyRecKit

@Suite("Summaries that refer to speakers by label")
struct SummaryReferenceTests {
    private let transcript = Transcript(utterances: [
        Utterance(start: 0, end: 4, text: "Can you send the report?", speaker: .me),
        Utterance(start: 4, end: 8, text: "Yes, by Friday.", speaker: .voice("B")),
        Utterance(start: 8, end: 12, text: "I'll check the numbers.", speaker: .voice("A")),
    ], language: "en", engine: "parakeet")

    private var summary: Summary {
        Summary(overview: "Speaker B agreed to send the report; Alex checks the numbers.",
                decisions: ["Speaker B owns the report"],
                actions: [.init(task: "Send the report to Speaker A", owner: "Speaker B", at: 4)],
                provider: "test", basis: .init(transcript: transcript, names: ["A": "Alex"]))
    }

    @Test("labels are filled in from the names voices have now, everywhere in the summary")
    func filled() {
        let named = summary.named(["A": "Alex", "B": "Maria"])
        #expect(named.overview == "Maria agreed to send the report; Alex checks the numbers.")
        #expect(named.decisions == ["Maria owns the report"])
        #expect(named.actions[0].owner == "Maria")
        #expect(named.actions[0].task == "Send the report to Alex")
        #expect(summary.named(["A": "Alex"]).actions[0].owner == "Speaker B")
        #expect(Summary.fill("Speaker AB and Speaker 27", ["A": "X", "27": "Y"]) == "Speaker AB and Y")
    }

    @Test("naming a speaker later is not staleness; new words or a changed name are")
    func staleness() {
        #expect(summary.staleness(of: transcript, names: ["A": "Alex", "B": "Maria"]) == .current)
        #expect(summary.staleness(of: transcript, names: ["A": "Alexandra"]) == .nameChanged)
        #expect(summary.staleness(of: transcript, names: [:]) == .nameChanged)
        var lines = transcript.utterances
        lines[1].text = "Yes, by Monday."
        let reworded = Transcript(utterances: lines, language: "en", engine: "reviewed")
        #expect(summary.staleness(of: reworded, names: ["A": "Alex"]) == .transcriptChanged)
        lines = transcript.utterances
        lines[2].speaker = .voice("B")
        #expect(summary.staleness(of: Transcript(utterances: lines, language: "en", engine: "parakeet"), names: ["A": "Alex"])
                == .transcriptChanged)
    }

    @Test("a summary written before labels were kept reads as it is and is never stale")
    func legacy() throws {
        let old = try JSONDecoder().decode(Summary.self, from: Data(#"{"overview":"Old","decisions":[],"actions":[],"provider":"Claude Code"}"#.utf8))
        #expect(old.basis == nil)
        #expect(old.staleness(of: transcript, names: [:]) == .current)
    }

    @Test("the pass writes the summary after the transcript, by label, and selects it; a failure is reported, not thrown")
    func inThePass() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("anyrec-summary-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let voices = RecordingVoices(voices: [.init(letter: "A", print: [], sample: "", start: 8, end: 12, name: "Alex"),
                                              .init(letter: "B", print: [], sample: "", start: 4, end: 8)])
        let candidates = TranscriptionCandidates(primary: .init(transcript: transcript, voices: voices),
                                                 transcripts: [transcript], failures: [])
        let outcome = try await TranscriptPass.publish(candidates, in: directory, options: TranscriptionOptions(),
                                                       summary: SummaryRequest(provider: .claude), progress: { _ in }) { instructions, input, _ in
            #expect(instructions.contains("Speaker B"))
            #expect(input.contains("Speaker B: Yes, by Friday.") && input.contains("Alex: I'll check"))
            return #"{"overview":"Speaker B will send the report.","decisions":[],"actions":[{"task":"Send the report","owner":"Speaker B","at":4}]}"#
        }
        guard case .written(_, _, _, .written(let url)?) = outcome else { Issue.record("Expected a summary"); return }
        let stored = try #require(Summary.read(url))
        #expect(stored.actions[0].owner == "Speaker B")
        #expect(stored.basis?.names == ["A": "Alex"])
        #expect(TranscriptStore.activeSummary(in: directory)?.lastPathComponent == url.lastPathComponent)
        let current = try #require(TranscriptStore.current(in: directory))
        #expect(stored.staleness(of: current.transcript, names: current.voices?.names ?? [:]) == .current)

        try VoiceNaming.apply(["B": "Maria"], in: directory, library: directory.appendingPathComponent("voices"))
        let markdown = try String(contentsOf: url.deletingPathExtension().appendingPathExtension("md"), encoding: .utf8)
        #expect(markdown.contains("Maria will send the report") && markdown.contains("— Maria"))

        let failed = try await TranscriptPass.publish(candidates, in: directory, options: TranscriptionOptions(),
                                                      summary: SummaryRequest(provider: .claude), progress: { _ in }) { _, _, _ in
            "no json"
        }
        guard case .written(_, _, _, .failed?) = failed else { Issue.record("Expected a reported failure"); return }
    }
}
