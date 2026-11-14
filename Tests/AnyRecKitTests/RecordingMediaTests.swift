import CoreMedia
import Foundation
import Testing

@testable import AnyRecKit

/// The merged file's name and which file in a folder plays. Titles here are made up; they
/// only have the shapes real windows were seen with.
@Suite("Recording media")
struct RecordingMediaTests {
    private static let utc = TimeZone(identifier: "UTC")!
    /// 2026-11-03 10:08:42 UTC.
    private static let started = Date(timeIntervalSince1970: 1_793_700_522)

    private func name(_ title: String, app: String? = "Slack", audioOnly: Bool = false) -> String {
        RecordingMedia.fileName(title: title, app: app, started: Self.started, audioOnly: audioOnly, timeZone: Self.utc)
    }

    // MARK: Naming

    @Test("title, app and start, joined by dashes, with the date in a form with no colons")
    func shape() {
        #expect(name("Design review") == "Design review – Slack – 2026-11-03 10.08.mp4")
        #expect(name("Design review", audioOnly: true) == "Design review – Slack – 2026-11-03 10.08.m4a")
    }

    @Test("the date ignores the locale and the calendar a user has set")
    func stamp() {
        #expect(RecordingMedia.stamp(Self.started, timeZone: Self.utc) == "2026-11-03 10.08")
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        #expect(RecordingMedia.stamp(Self.started, timeZone: tokyo) == "2026-11-03 19.08")
    }

    @Test("drops the trailing app name and unread counters, and keeps the workspace")
    func slackNoise() {
        #expect(name("Jane Example - Acme - Slack") == "Jane Example - Acme – Slack – 2026-11-03 10.08.mp4")
        #expect(name("Ana-Maria Pop, Bo Lee, Cy Dee - Acme - 2 new items - Slack")
                == "Ana-Maria Pop, Bo Lee, Cy Dee - Acme – Slack – 2026-11-03 10.08.mp4")
        #expect(name("Jane Example - Acme - 1 new item - Slack").hasPrefix("Jane Example - Acme – Slack"))
        #expect(name("Jane Example - Acme - 13 New Messages - Slack").hasPrefix("Jane Example - Acme – Slack"))
    }

    @Test("a title that is only its own text stays as it is")
    func plainTitle() {
        #expect(name("Quarterly planning", app: "Microsoft Teams")
                == "Quarterly planning – Microsoft Teams – 2026-11-03 10.08.mp4")
    }

    @Test("strips the app however the title joins it, including a browser's longer name")
    func appSuffixes() {
        #expect(name("Weekly | Microsoft Teams", app: "Microsoft Teams").hasPrefix("Weekly – Microsoft Teams – "))
        #expect(name("Weekly | Microsoft Teams", app: "Microsoft Teams (classic)")
                .hasPrefix("Weekly – Microsoft Teams (classic) – "))
        #expect(name("Meet - abc-defg-hij - Google Chrome", app: "Chrome")
                .hasPrefix("Meet - abc-defg-hij – Chrome – "))
        #expect(name("(3) Inbox — Safari", app: "Safari").hasPrefix("Inbox – Safari – "))
    }

    @Test("the app is not stripped from a title that is nothing else, nor repeated after it")
    func titleIsApp() {
        #expect(name("Slack") == "Slack – 2026-11-03 10.08.mp4")
        #expect(name("Slack - Slack") == "Slack – 2026-11-03 10.08.mp4")
    }

    @Test("characters Finder, zip or Windows reject or mangle are replaced or dropped")
    func illegalCharacters() {
        let cleaned = name("a/b: c\\d|e <f> \"g\"? *h\u{0007}\u{200B}i")
        #expect(cleaned == "a-b- c-d-e f g hi – Slack – 2026-11-03 10.08.mp4")
        #expect(!cleaned.dropLast(4).contains(":") && !cleaned.contains("/"))
        #expect(!name("...hidden").hasPrefix("."))
        #expect(name("trailing.  ").hasPrefix("trailing – "))
        #expect(name("tab\tand\n  newline").hasPrefix("tab and newline – "))
    }

    @Test("an empty or generated title falls back to the app, then to Recording")
    func fallbacks() {
        #expect(name("") == "Slack – 2026-11-03 10.08.mp4")
        #expect(name("   ") == "Slack – 2026-11-03 10.08.mp4")
        #expect(name("", app: nil) == "Recording – 2026-11-03 10.08.mp4")
        #expect(name("window 4182", app: nil) == "Recording – 2026-11-03 10.08.mp4")
        #expect(name("display 0", app: nil) == "Display – 2026-11-03 10.08.mp4")
        #expect(name("/:", app: "") == "Recording – 2026-11-03 10.08.mp4")
    }

    @Test("a long title is cut at a character, well inside a file name's 255 bytes")
    func lengthCap() {
        let long = String(repeating: "Ünïcödé wörds ", count: 40) + "- Slack"
        let cut = name(long)
        #expect(cut.utf8.count < 200)
        #expect(cut.contains("… – Slack – 2026-11-03 10.08.mp4"))
        let emoji = name(String(repeating: "👩‍👩‍👧‍👦", count: 60), app: String(repeating: "App", count: 30))
        #expect(emoji.utf8.count < 255)
        #expect(emoji.hasSuffix("2026-11-03 10.08.mp4"))
    }

    @Test("a folder with no recording.json keeps the name every reader already finds")
    func noInfo() {
        let directory = URL(fileURLWithPath: "/tmp/rec-2026-11-03-100842")
        #expect(RecordingMedia.mergedName(in: directory, info: nil, audioOnly: false) == "call.mp4")
    }

    @Test("a folder's start comes from its name")
    func folderStart() {
        let directory = URL(fileURLWithPath: "/tmp/rec-2026-11-03-100842")
        let info = RecordingInfo(title: "Standup - Acme - Slack", bundleID: "com.tinyspeck.slackmacgap",
                                 width: 2, height: 2, fps: 30)
        #expect(RecordingMedia.mergedName(in: directory, info: info, audioOnly: false)
                == "Standup - Acme – Slack – 2026-11-03 10.08.mp4")
    }

    // MARK: Resolution

    private func folder() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("anyrec-media-\(UUID())/rec-2026-11-03-100842")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return OutputPlan(directory: directory).directory
    }

    private func touch(_ names: String..., in directory: URL) throws {
        for name in names { try Data("x".utf8).write(to: directory.appendingPathComponent(name)) }
    }

    @Test("plays the stored name, else call.mp4, else screen.mov, else nothing")
    func resolutionOrder() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let named = "Standup – Slack – 2026-11-03 10.08.mp4"
        let info = RecordingInfo(title: "Standup", bundleID: nil, width: 2, height: 2, fps: 30, mergedFile: named)
        try info.write(to: directory)

        #expect(RecordingMedia.playable(in: directory) == nil)
        try touch("screen.mov", in: directory)
        #expect(RecordingMedia.playable(in: directory)?.lastPathComponent == "screen.mov")
        #expect(RecordingMedia.merged(in: directory) == nil)
        try touch("call.mp4", in: directory)
        #expect(RecordingMedia.playable(in: directory)?.lastPathComponent == "call.mp4")
        try touch(named, in: directory)
        #expect(RecordingMedia.playable(in: directory)?.lastPathComponent == named)
        #expect(RecordingLibrary.entry(at: directory).media?.lastPathComponent == named)
    }

    @Test("the picture's master is screen.mov while it exists, then the merged file; none for audio only")
    func videoMaster() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let named = "Standup – Slack – 2026-11-03 10.08.mp4"
        try RecordingInfo(title: "Standup", bundleID: nil, width: 2, height: 2, fps: 30, mergedFile: named)
            .write(to: directory)
        try touch("screen.mov", named, in: directory)
        #expect(RecordingMedia.video(in: directory)?.lastPathComponent == "screen.mov")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("screen.mov"))
        #expect(RecordingMedia.video(in: directory)?.lastPathComponent == named)
        #expect(RecordingLibrary.entry(at: directory).tracks == 1)

        let audio = RecordingInfo(title: "Standup", bundleID: nil, width: 2, height: 2, fps: 1, audioOnly: true,
                                  mergedFile: named)
        #expect(RecordingMedia.video(in: directory, info: audio) == nil)
    }

    @Test("a stored name that is not a plain file name in the folder is ignored")
    func unsafeStoredName() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        try touch("call.mp4", in: directory)
        for stored in ["../elsewhere.mp4", ".hidden.mp4", ""] {
            let info = RecordingInfo(title: "x", bundleID: nil, width: 2, height: 2, fps: 30, mergedFile: stored)
            #expect(RecordingMedia.merged(in: directory, info: info)?.lastPathComponent == "call.mp4")
        }
    }

    // MARK: recording.json

    @Test("recording.json round-trips the merged file's name")
    func roundTrip() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let info = RecordingInfo(title: "Standup", bundleID: "com.tinyspeck.slackmacgap", width: 4, height: 2,
                                 fps: 30, mergedFile: "Standup – Slack – 2026-11-03 10.08.mp4")
        try info.write(to: directory)
        #expect(RecordingInfo.read(directory) == info)
    }

    @Test("a recording.json without the name reads as never merged under one, and writes none")
    func withoutName() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let older = #"{"title":"Standup","bundleID":"com.tinyspeck.slackmacgap","width":800,"height":600,"fps":30}"#
        try Data(older.utf8).write(to: directory.appendingPathComponent(RecordingInfo.fileName))
        let info = try #require(RecordingInfo.read(directory))
        #expect(info.mergedFile == nil)

        try info.write(to: directory)
        let written = try String(contentsOf: directory.appendingPathComponent(RecordingInfo.fileName), encoding: .utf8)
        #expect(!written.contains("mergedFile"))
    }
}

@Suite("Merge verification")
struct MergeVerificationTests {
    private let original = MediaFacts.Video(
        codec: kCMVideoCodecType_H264, width: 3200, height: 2130, frames: 16_663, duration: 589.09, frameDuration: 1.0 / 30)

    private func video(codec: FourCharCode = kCMVideoCodecType_H264, width: Int = 3200, height: Int = 2130,
                       frames: Int? = 16_663, duration: TimeInterval = 589.01) -> MediaFacts.Video {
        MediaFacts.Video(codec: codec, width: width, height: height, frames: frames, duration: duration,
                         frameDuration: 1.0 / 30)
    }

    @Test("accepts the same frames under a slightly different duration, and the mix within tolerance")
    func accepts() {
        let result = MediaFacts(video: [video()], audio: [589.14])
        #expect(MergeVerification.problem(with: result, video: original, audio: 589.18) == nil)
    }

    @Test("rejects a result whose video stream is missing")
    func missingVideo() {
        let result = MediaFacts(video: [], audio: [589.14])
        #expect(MergeVerification.problem(with: result, video: original, audio: 589.18) != nil)
    }

    @Test("rejects a result with fewer frames than the original")
    func shorterVideo() {
        let result = MediaFacts(video: [video(frames: 16_000, duration: 565)], audio: [589.14])
        let problem = MergeVerification.problem(with: result, video: original, audio: 589.18)
        #expect(problem?.contains("16000 frames") == true)
    }

    @Test("without frame counts, rejects a video more than a frame shorter")
    func shorterByDuration() {
        let reference = MediaFacts.Video(codec: kCMVideoCodecType_H264, width: 3200, height: 2130, frames: nil,
                                         duration: 589.09, frameDuration: 1.0 / 30)
        let close = MediaFacts(video: [video(frames: nil, duration: 589.07)], audio: [589])
        let short = MediaFacts(video: [video(frames: nil, duration: 588.9)], audio: [589])
        #expect(MergeVerification.problem(with: close, video: reference, audio: 589) == nil)
        #expect(MergeVerification.problem(with: short, video: reference, audio: 589) != nil)
    }

    @Test("rejects another codec, another size, or two video streams")
    func otherVideo() {
        let reasons = [
            MediaFacts(video: [video(codec: kCMVideoCodecType_HEVC)], audio: [589.14]),
            MediaFacts(video: [video(width: 1600)], audio: [589.14]),
            MediaFacts(video: [video(), video()], audio: [589.14]),
        ].map { MergeVerification.problem(with: $0, video: original, audio: 589.18) }
        #expect(reasons.allSatisfy { $0 != nil })
    }

    @Test("rejects a missing, doubled or short mix")
    func audio() {
        let reasons = [
            MediaFacts(video: [video()], audio: []),
            MediaFacts(video: [video()], audio: [589.14, 589.14]),
            MediaFacts(video: [video()], audio: [300]),
        ].map { MergeVerification.problem(with: $0, video: original, audio: 589.18) }
        #expect(reasons.allSatisfy { $0 != nil })
    }

    @Test("an audio-only merge must have no picture, and a video-only one no audio")
    func absentStreams() {
        #expect(MergeVerification.problem(with: MediaFacts(video: [], audio: [10]), video: nil, audio: 10) == nil)
        #expect(MergeVerification.problem(with: MediaFacts(video: [video()], audio: [10]), video: nil, audio: 10) != nil)
        #expect(MergeVerification.problem(with: MediaFacts(video: [video()], audio: []), video: original, audio: nil) == nil)
        #expect(MergeVerification.problem(with: MediaFacts(video: [video()], audio: [1]), video: original, audio: nil) != nil)
    }
}
