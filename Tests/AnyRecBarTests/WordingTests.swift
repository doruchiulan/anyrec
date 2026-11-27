import Foundation
import Testing

@testable import AnyRecBar
@testable import AnyRecKit

@Suite("Menu bar wording")
struct WordingTests {
    /// A call runs for minutes, not hours, and an hours field that is almost always
    /// "00:" reads as noise — so it only appears once there is one.
    @Test("drops the hours field until there are hours")
    func clockGrowsWithTheRecording() {
        #expect(Wording.clock(0) == "00:00")
        #expect(Wording.clock(75) == "01:15")
        #expect(Wording.clock(3_600) == "1:00:00")
        #expect(Wording.clock(7_384) == "2:03:04")
    }

    @Test("names the app that took the microphone, and says the button opens the picker")
    func callOffer() {
        let offer = Wording.callOffer(CallApp(bundleID: "us.zoom.xos", name: "Zoom"))

        #expect(offer.title == "Zoom is on a call")
        #expect(offer.body.contains("picker"))
    }

    @Test("says an automatic recording started, what it keeps, and when it stops")
    func automaticRecordingStarted() {
        let slack = CallApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")
        let window = Wording.automaticRecordingStarted(slack, video: true)
        let audio = Wording.automaticRecordingStarted(slack, video: false)

        #expect(window.title == "Recording your Slack call")
        #expect(audio.title == "Recording the audio of your Slack call")
        #expect(window.body == "It stops when the call ends.")
    }

    @Test("the automatic recording footer says who is recorded, who is offered, and who is not told")
    func automaticRecordingFooter() {
        let footer = Wording.automaticRecordingFooter

        #expect(footer.contains("Slack or Teams"))
        #expect(footer.contains("\(Int(CallAutoRecording.endGrace)) seconds after the call ends"))
        #expect(footer.contains("other apps"))
        #expect(footer.contains("still get the offer"))
        #expect(footer.contains("doesn't tell the other people"))
        #expect(Wording.automaticRecordingModes.map(\.0) == AutomaticRecordingMode.allCases)
    }

    @Test("names the default microphone as the default")
    func namesTheDefault() {
        let device = AudioInputDevice(id: "1", name: "MacBook Pro Microphone", isDefault: true)

        #expect(Wording.microphone(device) == "MacBook Pro Microphone (default)")
        #expect(Wording.microphone(nil) == "Off")
    }

    /// Every engine is listed at once, so one that cannot run has to say so on its own
    /// row rather than leaving the advisory to explain a greyed-out word.
    @Test("says on the engine's own row when it cannot run")
    func engineSaysWhenItCannotRun() {
        let without = Readiness(appleLanguages: [])
        let with = Readiness(appleLanguages: ["en"])

        #expect(Wording.engine(.apple, with) == "Apple (on device, English only)")
        #expect(Wording.engine(.apple, without) == "Apple (needs macOS 26)")
        let whisper = with.of(.whisper).isReady ? "Whisper (on device)" : "Whisper (not installed)"
        #expect(Wording.engine(.whisper, with) == whisper)
        #expect(Wording.engine(nil, with) == "Off")
    }

    /// The terminal offers to install whisper on the row itself; the panel has no ⏎ and
    /// no row to press it on, so it names the window that does. Naming the terminal would
    /// be advice someone who installed only the app cannot take.
    @Test("sends setup to the window that can do it, not to a terminal")
    func advisoryPointsAtSettings() {
        #expect(Wording.advisory(.whisperNotSetUp).contains("Settings"))
        #expect(Wording.advisory(.openAIKeyMissing).contains("OPENAI_API_KEY"))
        #expect(!Wording.advisory(.whisperNotSetUp).contains("terminal"))
        #expect(!Wording.advisory(.whisperNotSetUp).contains("⏎"))
    }

    /// What a download will cost is on the button, never after it.
    @Test("says what pressing the button will fetch")
    func installNamesItsDownload() {
        #expect(Wording.install([.fetch(WhisperSetup.model)]) == "Download (574 MB)")
        #expect(Wording.install([.fetchFFmpeg, .fetchParakeet]).hasPrefix("Download ("))
    }

    @Test("separates a key OpenAI refused from one it merely could not check")
    func keyOutcomes() {
        #expect(Wording.wasRefused(.rejected("bad key")))
        #expect(Wording.wasRefused(.notSaved("disk full")))
        #expect(!Wording.wasRefused(.savedUnverified(reason: "offline")))
        #expect(!Wording.wasRefused(.savedButShadowed))
        #expect(Wording.keyOutcome(.savedButShadowed).contains("OPENAI_API_KEY"))
        #expect(Wording.keyOutcome(.rejected("bad key")).contains("bad key"))
    }

    @Test("distinguishes a merge nobody asked for from one that could not run")
    func mergeOutcomes() {
        #expect(Wording.merge(.notRequested).contains("as asked"))
        #expect(Wording.merge(.ffmpegMissing).contains("ffmpeg"))
        #expect(Wording.merge(.failed("boom")).contains("boom"))
        let named = URL(fileURLWithPath: "/tmp/rec/Standup – Slack – 2026-11-03 10.08.mp4")
        let merged = Wording.merge(.merged(MuxOutcome(output: named, notes: [])))
        #expect(merged.contains("Standup – Slack – 2026-11-03 10.08.mp4") && !merged.contains("call.mp4"))
    }

    @Test("carries the way out when the transcript failed for a fixable reason")
    func failedTranscriptCarriesItsRemedy() {
        let written = Wording.transcript(.failed(reason: "no model", remedy: .downloadModel(into: URL(fileURLWithPath: "/models"))))

        #expect(written.contains("no model"))
        #expect(written.contains("Settings"))
        #expect(Wording.transcript(.nothingHeard).contains("Nothing was heard"))
    }

    @Test("calls a recording by when it began")
    func titles() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_792_580_000)
        let earlier = now.addingTimeInterval(-3_600)
        let yesterday = now.addingTimeInterval(-86_400)

        #expect(Wording.title(started: earlier, now: now, calendar: calendar).hasPrefix("Today, "))
        #expect(Wording.title(started: yesterday, now: now, calendar: calendar).hasPrefix("Yesterday, "))
        #expect(Wording.group(yesterday, now: now, calendar: calendar) == "Yesterday")
        #expect(Wording.group(now.addingTimeInterval(-4 * 86_400), now: now, calendar: calendar) == "Previous 7 Days")
        #expect(Wording.group(now.addingTimeInterval(-20 * 86_400), now: now, calendar: calendar) == "Previous 30 Days")
    }

    @Test("a short line is its own caption")
    func shortCaption() {
        let line = Utterance(start: 0, end: 4, text: "Sunt bine, mulţumesc.", speaker: .voice("A"))
        #expect(Wording.caption(of: line, at: 2) == "Sunt bine, mulţumesc.")
    }

    @Test("a long line is cut at sentence ends and follows the time across its span")
    func longCaption() {
        let first = String(repeating: "a", count: 50) + "."
        let second = String(repeating: "b", count: 50) + "."
        let line = Utterance(start: 10, end: 20, text: "\(first) \(second)", speaker: .me)

        #expect(Wording.caption(of: line, at: 11) == first)
        #expect(Wording.caption(of: line, at: 19) == second)
    }

    @Test("joins short sentences up to the limit, and cuts a sentence with no breaks at spaces")
    func captionPieces() {
        #expect(Wording.captionPieces("Da. Nu. Poate.", limit: 10) == ["Da. Nu.", "Poate."])
        let words = Array(repeating: "word", count: 30).joined(separator: " ")
        let pieces = Wording.captionPieces(words, limit: 20)
        #expect(pieces.allSatisfy { $0.count <= 20 })
        #expect(pieces.joined(separator: " ") == words)
    }

    @Test("describes observed speaking time in the participant roster")
    func roster() {
        #expect(Wording.spokeAlone(65) == "Shown speaking for 01:05")
        #expect(Wording.spokeAlone(0) == "Not shown speaking")
    }

    @Test("the Speakers panel says how many to check, how each was named, and why a name is offered")
    func speakers() {
        #expect(Wording.clip(SpeakerClip(line: 0, start: 42, end: 50)) == "Play 00:42–00:50")
        #expect(Wording.personState(.newFromCallWindow, app: "Microsoft Teams") == "New · name from Teams")
        #expect(Wording.personState(.rememberedNextTime, app: nil) == "Will be recognised next time")
        #expect(Wording.talk(17) == "17 sec" && Wording.talk(1572) == "26 min")
        #expect(Wording.firstName("Barbura, Claudiu (Contractor)") == "Claudiu" && Wording.firstName("Madalin Marc") == "Madalin")
        #expect(Wording.list(["Ana", "Radu", "Ioana"]) == "Ana, Radu and Ioana")
        #expect(Wording.questions(0) == "Nothing to check" && Wording.questions(3) == "3 questions")
        #expect(Wording.nothingToAsk(unclaimed: 0) == "Everyone has a name. Nothing to check.")
        #expect(Wording.nothingToAsk(unclaimed: 26).hasPrefix("26 short bits have no name"))
        #expect(Wording.syncedTo(URL(fileURLWithPath: "/Volumes/Share/AnyRec Team")) == "Synced to AnyRec Team (on this Mac)")
        #expect(Wording.syncedTo(nil) == "Not synced")
        #expect(Wording.syncStatus(failure: nil, restored: nil, uploaded: true) == "Up to date")
        #expect(Wording.syncStatus(failure: nil, restored: nil, uploaded: false) == "Uploading…")
        #expect(Wording.syncStatus(failure: "Folder offline", restored: nil, uploaded: true) == "Needs attention: Folder offline")
        let now = Date()
        #expect(Wording.syncStatus(failure: nil, restored: now.addingTimeInterval(-60), uploaded: true, now: now).hasPrefix("Restored at "))
        #expect(Wording.syncStatus(failure: nil, restored: now.addingTimeInterval(-90_000), uploaded: true, now: now) == "Up to date")
        #expect(Wording.kept(.soundsLike("Vladimir Tikhonov")) == "Named for this call only: the voice sounds like Vladimir Tikhonov.")
        #expect(Wording.kept(.tooShort) == "Named for this call only: too little speech to remember the voice.")
        #expect(Wording.kept(.filed) == nil && Wording.kept(nil) == nil)
        #expect(Wording.samePerson("Vova", "Vladimir Tikhonov") == "Are Vova and Vladimir Tikhonov the same person?")
        #expect(Wording.unlikeVoices("Doru", isOwner: true) == "One of your voice recordings doesn't sound like the others.")
    }

    @Test("summaries say why they are stale, and comparison says where audio goes")
    func summaryAndComparison() {
        #expect(Wording.summaryStale(.current) == nil)
        #expect(Wording.summaryStale(.nameChanged)?.contains("name") == true)
        var options = TranscriptionOptions()
        #expect(Wording.comparison(options).contains("Turn on transcript review"))
        options.review = true
        options.compareEngines = true
        options.enabledEngines.insert(.openai)
        options.comparisonEngines.insert(.openai)
        #expect(Wording.comparison(options).contains("OpenAI receives the audio"))
    }

    @Test("names both ways to start, and says an audio-only recording kept no picture")
    func audioOnly() {
        #expect(Wording.record(video: true) == "Record Window…")
        #expect(Wording.record(video: false) == "Record Audio Only…")
        #expect(Wording.newRecording(video: false) == "New Audio-Only Recording…")
        #expect(Wording.bannerRecord(video: false) == "Audio Only")
        #expect(Wording.recordHelp(video: false).contains("without the picture"))

        let audio = RecordingInfo(title: "Weekly", bundleID: "com.microsoft.teams2", width: 1512,
                                  height: 982, fps: 30, audioOnly: true)
        let video = RecordingInfo(title: "Weekly", bundleID: nil, width: 1512, height: 982, fps: 30)
        #expect(Wording.picture(audio) == "Audio only")
        #expect(Wording.picture(video) == "1512×982, 30 fps")

        #expect(Wording.recordingLine(title: "Extended LHO EU", app: "Teams", audioOnly: true, remaining: nil)
                == "Extended LHO EU · Teams · audio only")
        #expect(Wording.recordingLine(title: "Design review - Slack", app: "Slack", audioOnly: false, remaining: 720)
                == "Design review - Slack · 12m left", "the app is not repeated when the title names it")
        #expect(Wording.recordingLine(title: "Display 1", app: nil, audioOnly: false, remaining: nil) == "Display 1")
        #expect(Wording.mutedInCall(app: "Teams") == "Muted in Teams — your microphone is left out of the mix")
        #expect(Wording.mutedInCall(app: nil).hasPrefix("Muted in the call"))
        #expect(Wording.audioSurface(app: "Microsoft Teams", display: false) == "Audio only · Microsoft Teams")
        #expect(Wording.audioSurface(app: nil, display: true) == "Audio only · Display")
        #expect(Wording.audioSurface(app: nil, display: false) == "Audio only")
    }

    @Test("a remembered voiceprint says which recording it was named in, or that it came earlier or by import")
    func printOrigins() {
        let filed = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(Wording.printOrigin(nil, number: 2) == "Voiceprint 2 · earlier")
        #expect(Wording.printOrigin(.init(recording: nil, filed: filed), number: 1)
            == "Imported \(filed.formatted(date: .abbreviated, time: .omitted))")
        let origin = VoiceLibrary.PrintOrigin(recording: "rec-2026-11-03-100800", filed: filed)
        let when = try! #require(origin.recordingStarted).formatted(date: .abbreviated, time: .shortened)
        #expect(Wording.printOrigin(origin, number: 1) == "Recording of \(when)")
        #expect(Wording.printOrigin(origin, number: 1, title: "Design review") == "Design review · \(when)")
        #expect(Wording.printOrigin(.init(recording: "renamed", filed: filed), number: 1) == "renamed")
    }

    @Test("AI apps: each state says what to do next, paths under home with a tilde")
    func agents() {
        let home = "/Users/me"
        #expect(Wording.agentName(.codex) == "ChatGPT and Codex")
        #expect(Wording.agentDetail(.claudeCode, .notInstalled, home: home) == "The claude command wasn't found.")
        #expect(Wording.agentDetail(.claudeDesktop, .notConnected, home: home) == "Claude reads it when it opens.")
        #expect(Wording.agentDetail(.claudeDesktop, .connected, stale: true, home: home) == "Connected. Restart Claude to load it.")
        #expect(Wording.agentDetail(.codex, .connected, home: home) == "Connected.")
        let elsewhere = MCPLaunch(command: "/Users/me/Projects/anyrec/.build/debug/anyrec", arguments: ["mcp"])
        #expect(Wording.agentDetail(.codex, .connectedElsewhere(elsewhere), home: home)
            == "Set up for another anyrec: ~/Projects/anyrec/.build/debug/anyrec")
        #expect(Wording.agentDetail(.claudeDesktop, .unreadable(URL(fileURLWithPath: "/Users/me/x.json")), home: home)
            == "Couldn't read ~/x.json, so it was left alone.")
    }

    @Test("Compression status: what runs now, what waits, what it saved")
    func compression() {
        #expect(Wording.compression(current: nil, waiting: 0, saved: 0) == nil)
        #expect(Wording.compression(current: "Design review", waiting: 3, saved: 0) == "Compressing “Design review”…")
        #expect(Wording.compression(current: nil, waiting: 1, saved: 0) == "1 recording waiting")
        #expect(Wording.compression(current: nil, waiting: 0, saved: 1_300_000_000)?.hasSuffix("saved") == true)
    }
}
