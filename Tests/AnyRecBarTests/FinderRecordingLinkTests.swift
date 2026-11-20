import Foundation
import Testing
@testable import AnyRecBar

@Suite struct FinderRecordingLinkTests {
    @Test func copiesOnlyFromTheNamedShareWindow() {
        let name = "QA & Doru.mp4"
        #expect(OneDriveLinkWindow.matches("Share \"QA & Doru.mp4\"", fileName: name))
        #expect(OneDriveLinkWindow.matches("Share “QA & Doru.mp4”", fileName: name))
        #expect(!OneDriveLinkWindow.matches("Share \"QA & Doru.mp4.backup\"", fileName: name))
        #expect(!OneDriveLinkWindow.matches("Share", fileName: name))
    }

    @Test func requiresFileInOneDrive() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = home.appendingPathComponent("Library/CloudStorage")
        let drive = storage.appendingPathComponent("OneDrive-Work")
        #expect(FinderRecordingLink.oneDriveRoot(for: drive.appendingPathComponent("Recordings/call.m4a"), home: home)?.path == drive.resolvingSymlinksInPath().path)
        #expect(FinderRecordingLink.oneDriveRoot(for: drive, home: home) == nil)
        #expect(FinderRecordingLink.oneDriveRoot(for: storage.appendingPathComponent("Downloads/call.mp4"), home: home) == nil)
        #expect(FinderRecordingLink.oneDriveRoot(for: drive.appendingPathComponent("../Other/file.mp4"), home: home) == nil)
    }

    @Test(arguments: ["https://company.sharepoint.com/:v:/s/team/example", "https://1drv.ms/v/example",
                      "https://onedrive.live.com/?id=example"])
    func acceptsProviderLink(_ raw: String) {
        #expect(FinderRecordingLink.providerURL(raw)?.absoluteString == raw)
    }

    @Test(arguments: ["https://sharepoint.com.example.org/file", "https://notsharepoint.com/file",
                      "file:///tmp/call.mp4", "https://example.org/link", "https://user@1drv.ms/file"])
    func ignoresUnrelatedClipboardData(_ raw: String) {
        #expect(FinderRecordingLink.providerURL(raw) == nil)
    }
}
