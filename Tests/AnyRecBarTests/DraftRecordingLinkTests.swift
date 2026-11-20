import AnyRecKit
import Foundation
import Testing
@testable import AnyRecBar

@Suite struct DraftRecordingLinkTests {
    @Test func videoAndAudio() throws {
        let raw = "https://example.sharepoint.com/:v:/s/project/recording?e=abc&view=1"
        let link = try #require(DraftRecordingLink.parse(raw))
        #expect(DraftRecordingLink.message("Minutes", link: link, audioOnly: false) == "Minutes\n\nRecording\n" + raw)
        #expect(DraftRecordingLink.message("Minutes", link: link, audioOnly: true) == "Minutes\n\nAudio\n" + raw)
        #expect(DraftRecordingLink.message("Minutes", link: nil, audioOnly: false) == "Minutes")
    }

    @Test func perRecording() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func file(_ name: String) -> URL {
            RecordingLayout(directory: root.appendingPathComponent(name)).url("cloud-media-link.txt")
        }
        let first = file("first"), second = file("second")
        let url = try #require(DraftRecordingLink.parse("https://www.icloud.com/iclouddrive/example"))
        try DraftRecordingLink.save(url, at: first)
        #expect(DraftRecordingLink.read(first) == url)
        #expect(first.deletingLastPathComponent().lastPathComponent == RecordingLayout.dataName)
        #expect(DraftRecordingLink.read(second) == nil)
        try DraftRecordingLink.save(nil, at: first)
        #expect(DraftRecordingLink.read(first) == nil)
    }

    @Test(arguments: ["file:///Users/example/a.mp4", "/Volumes/OneDrive/a.m4a", "https://", "http://example.org",
                      "https://example.org/a\nmessage", "https://user:password@example.org/a"])
    func invalidLink(_ input: String) {
        #expect(DraftRecordingLink.parse(input) == nil)
    }
}
