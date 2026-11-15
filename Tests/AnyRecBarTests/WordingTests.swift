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

    @Test("says how much of the call the window was readable for, and what was done with the owner's voice")
    func roster() {
        #expect(Wording.readable(106, of: 4_580) == "The call window could be read for 01:46 of 1:16:20 (2%).")
        var voices = RecordingVoices(voices: [])
        voices.ownerMerge = .init(evidence: [.microphone], toMe: 8, toOthers: 1)
        #expect(Wording.voiceFacts(voices).first?.contains("8 lines went back to Me; 1 line") == true)
        #expect(Wording.spokeAlone(0) == "Not shown speaking")
    }

    @Test("the Speakers panel says how many to check, how each was named, and why a name is offered")
    func speakers() {
        #expect(Wording.speakersTitle(toCheck: 0) == "Speakers")
        #expect(Wording.speakersTitle(toCheck: 2) == "Speakers · 2 to check")
        #expect(Wording.basis(.agreed) == "Call window and voice agree")
        #expect(Wording.basis(.namedByYou) == "Named by you")
        #expect(Wording.basis(.review) == "Chosen by review")
        #expect(Wording.talkTime(252, lines: 38) == "04:12 · 38 lines")
        #expect(Wording.talkTime(3, lines: 1) == "00:03 · 1 line")
        #expect(Wording.candidate(SpeakerCandidate(name: "Ana", reason: .soundsLike)) == "Ana?")
        #expect(Wording.candidate(.me([.shownSpeaking])) == "Me")
        #expect(Wording.candidateReason(.yourVoice([.shownSpeaking])) == "Your voice. Every line goes to Me")
        #expect(Wording.probablyYou([.savedAsYou, .shownSpeaking]) == "Probably you: saved as you; the call window showed you speaking")
        #expect(Wording.rememberOwner(OwnerToRemember(person: "Doru", shownName: "Doru", display: "Doru Chiulan")) == "Remember Doru is me")
        #expect(Wording.candidate(SpeakerCandidate(name: "Ana", reason: .inCall)) == "Ana")
        #expect(Wording.candidateReason(.introduced(quote: "I'm Ana")) == "Said “I'm Ana”")
        #expect(Wording.candidateReason(.onlyOneLeft) == "The only one in the call without a voice")
        #expect(Wording.completion(PersonSuggestion(savedName: "Andi", shownName: "Andrei Lungu", matched: "Andi", exact: true))
            == "Andrei Lungu — also Andi")
        #expect(Wording.completion(PersonSuggestion(savedName: "Andi", shownName: "Andrei Lungu", matched: "andrei  lungu", exact: false))
            == "Andrei Lungu")
        #expect(Wording.unclaimed(lines: 0, seconds: 0) == nil)
        #expect(Wording.unclaimed(lines: 1, seconds: 4) == "1 line (00:04) is still marked Call; no voice claims it.")
        #expect(Wording.unclaimed(lines: 12, seconds: 190) == "12 lines (03:10) are still marked Call; no voice claims them.")
        #expect(Wording.clip(SpeakerClip(line: 0, start: 42, end: 50)) == "Play 00:42–00:50")
        #expect(Wording.voiceScope == "All their lines")
        #expect(Wording.giveTo(voice: nil) == "Or give it to")
        #expect(Wording.giveTo(voice: "Speaker B") == "Or give every line of Speaker B to")
        #expect(Wording.giveHelp(voice: nil, to: .others, targetLabel: "Call") == "This line goes to Call.")
        #expect(Wording.giveHelp(voice: "Ana", to: .voice("A"), targetLabel: "Costi") == "Every line of Ana goes to Costi.")
        #expect(Wording.giveHelp(voice: "Ana", to: .me, targetLabel: "Me").hasPrefix("Every line of Ana goes to Me. Its voiceprint joins yours"))
        #expect(Wording.fused(["Ana", "Mihai"]).contains("Ana and Mihai"))
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

        #expect(Wording.live(video: false, width: 2, height: 2, fps: 30, droppedFrames: nil).contains("Audio only"))
        #expect(Wording.live(video: true, width: 1512, height: 982, fps: 30, droppedFrames: 4)
                == "1512×982 · 30 fps · 4 frames dropped")
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
}
