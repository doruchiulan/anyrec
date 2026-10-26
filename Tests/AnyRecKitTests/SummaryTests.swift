import Foundation
import Testing

@testable import AnyRecKit

@Suite("Summary")
struct SummaryTests {
    @Test("reads the object out of a fenced, chatty reply")
    func fenced() throws {
        let reply = """
            Here you go:
            ```json
            {"overview": "Shipped it.", "decisions": ["Ship Friday"],
             "actions": [{"task": "Write notes", "owner": "Ana", "at": 754}]}
            ```
            """

        let summary = try #require(Summary.parse(reply, provider: "Claude Code"))

        #expect(summary.overview == "Shipped it.")
        #expect(summary.decisions == ["Ship Friday"])
        #expect(summary.actions == [Summary.Action(task: "Write notes", owner: "Ana", at: 754)])
    }

    @Test("an answer with no object is a failure, not an empty summary")
    func prose() {
        #expect(Summary.parse("The call went well.", provider: "x") == nil)
    }

    @Test("leaves out sections with nothing in them")
    func markdown() {
        let summary = Summary(overview: "Short.", decisions: [], actions: [], provider: "x")
        #expect(summary.markdown == "Short.\n")
    }

    @Test("round trips through its file with the Markdown beside it")
    func file() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("anyrec-summary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(Summary.fileName(engine: "whisper"))
        let summary = Summary(
            overview: "O", decisions: ["D"],
            actions: [Summary.Action(task: "T", done: true)], provider: "Codex")

        try summary.write(to: url)

        #expect(Summary.read(url) == summary)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("summary-whisper.md").path))
    }
}

@Suite("Recording info")
struct RecordingInfoTests {
    @Test("a known call app makes a call, and a display does not")
    func calls() {
        let teams = RecordingInfo(title: "Weekly sync", bundleID: "com.microsoft.teams2", width: 1, height: 1, fps: 30)
        let display = RecordingInfo(title: "Display", bundleID: nil, width: 1, height: 1, fps: 30)

        #expect(teams.isCall && teams.appName == "Microsoft Teams")
        #expect(!display.isCall && display.appName == nil)
    }

    @Test("is read back from the folder it was written to")
    func roundTrip() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("anyrec-info-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let info = RecordingInfo(title: "T", bundleID: "us.zoom.xos", width: 10, height: 20, fps: 24)

        try info.write(to: folder)

        #expect(RecordingInfo.read(folder) == info)
    }
}
