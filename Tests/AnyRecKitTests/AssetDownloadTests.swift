import Foundation
import Testing

@testable import AnyRecKit

@Suite("AssetDownload")
struct AssetDownloadTests {
    /// The whole point of the checksum: a model that arrived wrong must not be left
    /// where whisper will pick it up, and whisper picks the largest file it finds.
    @Test("refuses a file that does not match its checksum, and leaves nothing behind")
    func rejectsCorrupt() async throws {
        let (source, directory) = try scratch(contents: "not the model")
        defer { try? FileManager.default.removeItem(at: directory) }

        let asset = AssetDownload.Asset(
            name: "model.bin", url: source, sha256: String(repeating: "0", count: 64), bytes: 13)

        await #expect(throws: AssetDownload.Failure.self) {
            try await AssetDownload.fetch(asset, into: directory) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("model.bin").path))
    }

    @Test("installs a file that matches, under the name it was asked for")
    func installsVerified() async throws {
        let (source, directory) = try scratch(contents: "model")
        defer { try? FileManager.default.removeItem(at: directory) }

        let asset = AssetDownload.Asset(
            name: "model.bin", url: source,
            sha256: "9372c470eeadd5ecd9c3c74c2b3cb633f8e2f2fad799250a0f70d652b6b825e4", bytes: 5)

        let installed = try await AssetDownload.fetch(asset, into: directory) { _ in }

        #expect(installed.lastPathComponent == "model.bin")
        #expect(try String(contentsOf: installed, encoding: .utf8) == "model")
    }

    @Test("sizes a download the way the screen shows it")
    func describes() {
        #expect(AssetDownload.describe(885_098) == "885 KB")
        #expect(AssetDownload.describe(574_041_195) == "574 MB")
    }

    private func scratch(contents: String) throws -> (source: URL, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("anyrec-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("source")
        try Data(contents.utf8).write(to: source)
        return (source, directory)
    }
}

@Suite("WhisperSetup")
struct WhisperSetupTests {
    @Test("strips the colour and spinners brew draws even when told not to")
    func plainOutput() {
        #expect(WhisperSetup.plain("\u{1B}[32m==>\u{1B}[0m Fetching whisper-cpp") == "==> Fetching whisper-cpp")
        #expect(WhisperSetup.plain("\u{1B}[2K  downloading") == "downloading")
        #expect(WhisperSetup.plain("\u{1B}[?25l") == "")
    }

    @Test("says what each step will cost before it starts")
    func stepLabels() {
        #expect(WhisperSetup.Step.install(formula: "ffmpeg", binary: "ffmpeg").detail
            == "brew install ffmpeg")
        #expect(WhisperSetup.Step.fetch(WhisperSetup.model).detail == "574 MB")
        #expect(WhisperSetup.Step.fetch(WhisperSetup.model).title
            == "Download ggml-large-v3-turbo-q5_0.bin")
    }
}

@Suite("Shell.Tail")
struct ShellTailTests {
    @Test("reports only the lines a file has grown since it was last read")
    func growth() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("anyrec-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }

        try "one\ntwo\n".write(to: file, atomically: true, encoding: .utf8)
        var tail = Shell.Tail(url: file)
        #expect(tail.fresh() == ["one", "two"])

        try "one\ntwo\nthree\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(tail.fresh() == ["three"])
        #expect(tail.fresh() == [])
    }

    /// A progress bar redrawing in place is the only sign some children are alive.
    @Test("treats a carriage return as a line of its own")
    func carriageReturns() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("anyrec-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }

        try "10%\r50%\r".write(to: file, atomically: true, encoding: .utf8)
        var tail = Shell.Tail(url: file)

        #expect(tail.fresh() == ["10%", "50%"])
    }

    @Test("holds back a line that is still being written")
    func partialLine() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("anyrec-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }

        try "done\nhalf".write(to: file, atomically: true, encoding: .utf8)
        var tail = Shell.Tail(url: file)
        #expect(tail.fresh() == ["done"])

        try "done\nhalf way\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(tail.fresh() == ["half way"])
    }
}
