import Foundation
import Testing

@testable import AnyRecKit

@Suite("Speakers panel")
struct RecordingSpeakersTests {
    // MARK: Clips

    @Test("clips come from the start, middle and end of the call")
    func clipsSpread() {
        let lines = (0..<9).map { Utterance(start: Double($0) * 100, end: Double($0) * 100 + 5, text: "Line \($0)", speaker: .voice("A")) }
        let clips = SpeakerClip.clips(of: .voice("A"), in: lines)
        #expect(clips.count == 3)
        #expect(clips[0].start < 300)
        #expect(clips[1].start >= 300 && clips[1].start < 600)
        #expect(clips[2].start >= 600)
    }

    @Test("a clip is at most eight seconds, centred in its line")
    func clipCap() {
        let lines = [Utterance(start: 10, end: 30, text: "A long stretch", speaker: .voice("A"))]
        let clip = try! #require(SpeakerClip.clips(of: .voice("A"), in: lines).first)
        #expect(clip.start == 16 && clip.end == 24)
        #expect(clip.line == 0)
    }

    @Test("lines overlapped by another speaker, short lines and lines with a pending correction are never clipped")
    func clipExclusions() {
        let lines = [
            Utterance(start: 0, end: 5, text: "Overlapped", speaker: .voice("A")),
            Utterance(start: 4, end: 6, text: "Interrupting", speaker: .me),
            Utterance(start: 10, end: 11.5, text: "Short", speaker: .voice("A")),
            Utterance(start: 20, end: 25, text: "Pending", speaker: .voice("A")),
            Utterance(start: 30, end: 35, text: "Clean", speaker: .voice("A")),
        ]
        let clips = SpeakerClip.clips(of: .voice("A"), in: lines, excluding: [3])
        #expect(clips.map(\.line) == [4])
    }

    @Test("fewer clips when fewer lines qualify, and none when none do")
    func tooFew() {
        let lines = [
            Utterance(start: 0, end: 4, text: "One", speaker: .voice("A")),
            Utterance(start: 5, end: 9, text: "Two", speaker: .voice("A")),
            Utterance(start: 500, end: 501, text: "Short", speaker: .voice("A")),
        ]
        #expect(SpeakerClip.clips(of: .voice("A"), in: lines).map(\.line) == [0, 1])
        #expect(SpeakerClip.clips(of: .voice("B"), in: lines).isEmpty)
    }

    // MARK: Candidates

    private func observation(_ at: Double, _ participants: [String], speaking: [String] = [], me: String? = nil) -> CallParticipants.Observation {
        .init(at: at, source: "com.tinyspeck.slackmacgap:1", participants: participants, speaking: speaking, me: me)
    }

    private func roster(_ names: [String], me: String? = nil) -> CallParticipants {
        CallParticipants(observations: [observation(0, names, me: me), observation(1, names, me: me)])
    }

    private func speakers(
        _ voices: [RecordingVoices.Voice], lines: [Utterance]? = nil, participants: CallParticipants? = nil,
        info: RecordingInfo? = nil, library: VoiceLibrary = VoiceLibrary(), suggestions: [SpeakerSuggestion] = [],
        corrections: [SpeakerCorrection] = []
    ) -> RecordingSpeakers {
        let lines = lines ?? voices.enumerated().map {
            Utterance(start: Double($0.offset) * 10, end: Double($0.offset) * 10 + 5, text: "Hello", speaker: .voice($0.element.letter))
        }
        return RecordingSpeakers.build(lines: lines, voices: RecordingVoices(voices: voices), suggestions: suggestions,
                                       corrections: corrections, participants: participants, info: info, library: library)
    }

    private func voice(_ letter: String, _ name: String? = nil, print: Voiceprint = []) -> RecordingVoices.Voice {
        .init(letter: letter, print: print, sample: "Hello", start: 0, end: 5, name: name)
    }

    // MARK: People in this call

    private func evidence(call: String?, print: String? = nil) -> SpeakerIdentityEvidence {
        var e = SpeakerIdentityEvidence(callNames: call.map { [$0] } ?? [], voiceprintName: print, conflict: false)
        e.callName = call
        return e
    }

    @Test("an unnamed voice asks who it is, offering the people in the call with nothing under their name")
    func whoQuestion() {
        let lines = [Utterance(start: 0, end: 30, text: "Can you share the screen?", speaker: .voice("A")),
                     Utterance(start: 30, end: 40, text: "Hi", speaker: .me)]
        let result = speakers([voice("A")], lines: lines, participants: roster(["Zaid Eliyas", "Doru"], me: "Doru"))
        #expect(result.questions.map(\.kind) == [.who(.voice("A"), candidates: ["Zaid Eliyas"])])
        #expect(result.state(of: result.row(for: .voice("A"))!) == .unnamed)
    }

    @Test("a name only the call window gave asks for a yes; one a saved voice backs does not")
    func confirmQuestion() {
        var madalin = voice("A", "Madalin Marc"); madalin.identityEvidence = evidence(call: "Madalin Marc")
        var vladimir = voice("B", "Vladimir Tikhonov"); vladimir.identityEvidence = evidence(call: "Vladimir Tikhonov", print: "Vladimir Tikhonov")
        let lines = [Utterance(start: 0, end: 30, text: "Hello", speaker: .voice("A")), Utterance(start: 30, end: 60, text: "Hi", speaker: .voice("B"))]
        let result = speakers([madalin, vladimir], lines: lines)
        #expect(result.questions.map(\.kind) == [.confirm(.voice("A"), name: "Madalin Marc")])
        #expect(result.state(of: result.row(for: .voice("A"))!) == .newFromCallWindow)
        #expect(result.state(of: result.row(for: .voice("B"))!) == .recognised)
    }

    @Test("a voice the call window saw as two people is sorted line by line, guessed from who it showed")
    func sortQuestion() {
        var mixed = voice("A"); mixed.identityEvidence = { var e = evidence(call: nil); e.fusedNames = ["Mihai", "Tudor"]; return e }()
        let lines = [Utterance(start: 0, end: 4, text: "Can everyone see my screen?", speaker: .voice("A")),
                     Utterance(start: 5, end: 8, text: "Yes, we can.", speaker: .voice("A"))]
        let window = CallParticipants(observations: (0...8).map {
            observation(Double($0), ["Mihai", "Tudor"], speaking: [$0 < 5 ? "Mihai" : "Tudor"])
        })
        let result = speakers([mixed], lines: lines, participants: window)
        guard case .sort(_, let names, let sorted, let guesses)? = result.questions.first?.kind else { Issue.record("no sort question"); return }
        #expect(names == ["Mihai", "Tudor"] && sorted == [0, 1])
        #expect(guesses == [0: "Mihai", 1: "Tudor"])
    }

    @Test("an unnamed voice the call window showed as different people is asked about line by line")
    func eachLineQuestion() {
        let lines = [Utterance(start: 0, end: 4, text: "What's the Gen 740?", speaker: .voice("A")),
                     Utterance(start: 10, end: 14, text: "On the other views", speaker: .voice("A")),
                     Utterance(start: 20, end: 24, text: "So basically", speaker: .voice("A")),
                     Utterance(start: 30, end: 34, text: "Don't recall.", speaker: .voice("A"))]
        let window = CallParticipants(observations: (0...34).map { second in
            let who = second < 5 ? ["Maria"] : second < 25 ? ["Tom"] : []
            return observation(Double(second), ["Maria", "Tom"], speaking: who)
        })
        let result = speakers([voice("A")], lines: lines, participants: window)
        #expect(result.questions.map(\.kind) == [.eachLine(.voice("A"), lines: [0, 1, 2, 3], guesses: [0: "Maria", 1: "Tom", 2: "Tom"], severalPeople: true)])
    }

    @Test("a voice the call window showed as one person, with the odd stray line, is still asked about whole")
    func oneMainPersonIsNotSplit() {
        let lines = (0..<20).map { Utterance(start: Double($0) * 10, end: Double($0) * 10 + 4, text: "Line", speaker: .voice("A")) }
        let window = CallParticipants(observations: (0...200).map { second in
            observation(Double(second), ["Lena", "Tom"], speaking: [second < 10 ? "Tom" : "Lena"])
        })
        let result = speakers([voice("A")], lines: lines, participants: window)
        #expect(result.severalPeople(.voice("A")) == nil)
        guard case .who? = result.questions.first?.kind else { Issue.record("expected who"); return }
    }

    @Test("too little speech to remember, or nothing clean to play, is asked about a line at a time; people never shown talking are not offered")
    func fewLinesOneAtATime() {
        let lines = [Utterance(start: 0, end: 1.2, text: "um", speaker: .voice("A")),
                     Utterance(start: 10, end: 13, text: "It's last seven days.", speaker: .voice("A"))]
        let result = speakers([voice("A")], lines: lines, participants: roster(["Ivo", "Tom"]))
        #expect(result.questions.map(\.kind) == [.eachLine(.voice("A"), lines: [0, 1], guesses: [:], severalPeople: false)])
        #expect(result.whoCandidates(result.row(for: .voice("A"))!).isEmpty)
    }

    @Test("the spans near a stretch are exactly the ones a full scan finds overlapping it")
    func spansNear() {
        let window = CallParticipants(observations: stride(from: 0.0, to: 300, by: 0.7).map { at in
            observation(at, ["A", "B"], speaking: Int(at) % 3 == 0 ? ["A"] : ["B"])
        })
        let spans = window.spans
        for start in stride(from: -2.0, to: 302, by: 3.3) {
            let end = start + Double(Int(start * 10) % 7)
            let near = spans.near(start, end).filter { min(end, $0.end) - max(start, $0.start) > 0 }.map(\.start)
            let all = spans.filter { min(end, $0.end) - max(start, $0.start) > 0 }.map(\.start)
            #expect(near == all)
        }
    }

    @Test("the overlap sweep finds the same lines as comparing every pair")
    func overlapSweep() {
        let speakers: [Speaker] = [.me, .voice("A"), .voice("B")]
        let lines = (0..<60).map { i in
            Utterance(start: Double((i * 37) % 200), end: Double((i * 37) % 200) + Double(i % 9), text: "", speaker: speakers[i % 3])
        }
        let pairs = Set(lines.indices.filter { i in
            lines.indices.contains { j in j != i && lines[j].speaker != lines[i].speaker && lines[j].start < lines[i].end && lines[j].end > lines[i].start }
        })
        #expect(SpeakerClip.overlapped(lines) == pairs)
    }

    @Test("unclaimed bits in a call with one other person can all be theirs; the review's fixes come last")
    func bitsAndFixes() {
        var bea = voice("A", "Beatrice Cuca"); bea.identityEvidence = evidence(call: "Beatrice Cuca", print: "Beatrice Cuca")
        let lines = [Utterance(start: 0, end: 30, text: "Am terminat", speaker: .voice("A")),
                     Utterance(start: 30, end: 31, text: "Asa.", speaker: .others),
                     Utterance(start: 31, end: 40, text: "Bine", speaker: .me)]
        let fix = SpeakerCorrection(line: 2, from: .me, to: .voice("A"), reason: "It answers you.", quote: "Bine", evidenceLine: 0)
        let result = speakers([bea], lines: lines, participants: roster(["Beatrice Cuca", "Doru"], me: "Doru"), corrections: [fix])
        #expect(result.questions.map(\.kind) == [.unnamedBits(lines: [1], seconds: 1, onlyOther: .voice("A")), .fixes([fix])])
    }

    @Test("two names the library knows as one person ask whether they are the same person")
    func samePersonByName() {
        var vladimir = voice("A", "Vladimir Tikhonov"); vladimir.identityEvidence = evidence(call: "Vladimir Tikhonov", print: "Vladimir Tikhonov")
        let lines = [Utterance(start: 0, end: 60, text: "Okay, hold on.", speaker: .voice("A")),
                     Utterance(start: 60, end: 64, text: "November 18 baseline", speaker: .named("Vova"))]
        let library = VoiceLibrary(people: [.init(name: "Vladimir Tikhonov", prints: [[1, 0]], aliases: ["Vova"])])
        let result = speakers([vladimir], lines: lines, library: library)
        #expect(result.questions.contains { $0.kind == .samePerson(.voice("A"), .named("Vova")) })
    }

    @Test("people the call window listed who never spoke are listed as such, never the person recording")
    func silentPeople() {
        let result = speakers([voice("A", "Ana")], participants: roster(["Ana", "Radu Stan", "Doru"], me: "Doru"))
        #expect(result.silentPeople == ["Radu Stan"])
    }

    @Test("a line goes to you, the speakers, the rest of the call, then the library A to Z, each person once")
    func lineChoices() {
        let library = VoiceLibrary(people: [
            .init(name: "Doru", prints: [], aliases: ["Doru Chiulan"], isOwner: true),
            .init(name: "Bogdan", prints: [], aliases: ["Bogdan Pop"]),
            .init(name: "Zaid", prints: [], displayName: "Zaid Eliyas"),
            .init(name: "Cosmina", prints: []),
            .init(name: "Ana", prints: [], displayName: "Ana Ionescu"),
        ])
        let lines = [Utterance(start: 0, end: 5, text: "Hello", speaker: .voice("A")),
                     Utterance(start: 6, end: 8, text: "Hm", speaker: .others)]
        let result = speakers([voice("A", "Bogdan Pop")], lines: lines,
                              participants: roster(["Bogdan Pop", "Ana Ionescu", "Doru Chiulan"], me: "Doru Chiulan"),
                              library: library)
        let choices = result.lineChoices
        #expect(choices.speakers == [.me, .voice("A")])
        #expect(choices.callNames == ["Ana Ionescu"])
        #expect(choices.library.map(\.shownName) == ["Cosmina", "Zaid Eliyas"])
    }

    @Test("the one roster name nobody has yet is offered first, and the owner's tile never")
    func onlyOneLeft() {
        let result = speakers([voice("A", "Bogdan Pop"), voice("B")],
                              participants: roster(["Bogdan Pop", "Ana Ionescu", "Doru"], me: "Doru"))
        let candidates = result.candidates(for: .voice("B"))
        #expect(candidates.first == SpeakerCandidate(name: "Ana Ionescu", reason: .onlyOneLeft))
        #expect(!candidates.contains { $0.name == "Doru" || $0.name == "Bogdan Pop" })
    }

    @Test("with several left, the roster is offered as others in the call, after the call window's own name")
    func order() {
        var b = voice("B")
        var evidence = SpeakerIdentityEvidence(callNames: ["Ana Ionescu", "Mihai Rusu"], voiceprintName: "Andi", conflict: true)
        evidence.callName = nil
        b.identityEvidence = evidence
        let library = VoiceLibrary(people: [.init(name: "Andi", prints: [[1, 0]], displayName: "Andrei Lungu")])
        let result = speakers([b], participants: roster(["Ana Ionescu", "Mihai Rusu", "Elena"]),
                              library: library,
                              suggestions: [.init(letter: "B", name: "Radu", quote: "I'm Radu", line: 0)])
        #expect(result.candidates(for: .voice("B")) == [
            .init(name: "Ana Ionescu", reason: .callWindow), .init(name: "Mihai Rusu", reason: .callWindow),
            .init(name: "Andrei Lungu", reason: .voiceMatch), .init(name: "Radu", reason: .introduced(quote: "I'm Radu")),
            .init(name: "Elena", reason: .inCall),
        ])
        #expect(result.row(for: .voice("B"))?.basis == .uncertain)
        #expect(result.needsChecking == 1)
    }

    @Test("names other voices carry, by any of a person's names, and the library owner's names are never offered")
    func exclusions() {
        let library = VoiceLibrary(people: [
            .init(name: "Andi", prints: [], aliases: ["Andrei Lungu"]),
            .init(name: "Doru", prints: [], aliases: ["Doru Chiulan"], isOwner: true),
        ])
        let result = speakers([voice("A", "Andi"), voice("B")],
                              participants: roster(["Andrei Lungu", "Doru Chiulan", "Ana", "Mihai"]), library: library)
        #expect(result.candidates(for: .voice("B")).map(\.name) == ["Ana", "Mihai"])
    }

    @Test("Slack titles give their first segment's names; other apps' titles give none")
    func slackTitle() {
        let slack = RecordingInfo(title: "Ana-Maria Pop, Mihai Rusu, Doru - Acme - 2 new items - Slack",
                                  bundleID: "com.tinyspeck.slackmacgap", width: 1, height: 1, fps: 1)
        #expect(CandidateContext.titleNames(slack) == ["Ana-Maria Pop", "Mihai Rusu", "Doru"])
        let teams = RecordingInfo(title: "Ana Pop, Mihai Rusu | Microsoft Teams", bundleID: "com.microsoft.teams2",
                                  width: 1, height: 1, fps: 1)
        #expect(CandidateContext.titleNames(teams).isEmpty)
        let library = VoiceLibrary(people: [.init(name: "Doru", prints: [], isOwner: true)])
        let result = speakers([voice("A")], info: slack, library: library)
        #expect(result.candidates(for: .voice("A")) == [
            .init(name: "Ana-Maria Pop", reason: .windowTitle), .init(name: "Mihai Rusu", reason: .windowTitle),
        ])
    }

    @Test("saved voices below the threshold but above 0.3 are offered as sounds-like, two at most, closest first")
    func soundsLike() {
        let library = VoiceLibrary(people: [
            .init(name: "Far", prints: [[0, 1]]),            // 0.0
            .init(name: "Close", prints: [[0.8, 0.6]]),      // 0.8: a match, not a sounds-like
            .init(name: "Near", prints: [[0.45, 0.893]]),    // ~0.45
            .init(name: "Nearer", prints: [[0.49, 0.872]]),  // ~0.49
            .init(name: "Edge", prints: [[0.35, 0.937]]),    // ~0.35
        ])
        let result = speakers([voice("A", print: [1, 0])], library: library)
        let candidates = result.candidates(for: .voice("A"))
        #expect(candidates.first == .init(name: "Close", reason: .voiceMatch))
        #expect(candidates.filter { $0.reason == .soundsLike }.map(\.name) == ["Nearer", "Near"])
        #expect(!candidates.contains { $0.name == "Far" || $0.name == "Edge" })
    }

    @Test("the basis says how each speaker was named, and an owner-given name reads as named by you")
    func basis() {
        var agreed = voice("A", "Ana")
        agreed.identityEvidence = { var e = SpeakerIdentityEvidence(callNames: ["Ana"], voiceprintName: "Ana", conflict: false); e.callName = "Ana"; return e }()
        var call = voice("B", "Mihai")
        call.identityEvidence = { var e = SpeakerIdentityEvidence(callNames: ["Mihai"], voiceprintName: nil, conflict: false); e.callName = "Mihai"; return e }()
        var mine = RecordingVoices(voices: [voice("C")])
        mine.name("C", "Radu")
        let old = voice("D", "Elena")
        let library = VoiceLibrary()
        let rows = speakers([agreed, call, mine.voices[0], old], library: library)
        #expect(rows.row(for: .voice("A"))?.basis == .agreed)
        #expect(rows.row(for: .voice("B"))?.basis == .callWindow)
        #expect(rows.row(for: .voice("C"))?.basis == .namedByYou)
        #expect(rows.row(for: .voice("D"))?.basis == .named)
        #expect(rows.needsChecking == 0)
    }

    @Test("Call lines no voice claims are a row to resolve, Me asks who you are, and corrections mark a speaker to check")
    func rows() throws {
        let lines = [
            Utterance(start: 0, end: 4, text: "Hi", speaker: .me),
            Utterance(start: 5, end: 9, text: "Hello", speaker: .voice("A")),
            Utterance(start: 10, end: 13, text: "Someone", speaker: .others),
            Utterance(start: 14, end: 20, text: "Yes", speaker: .voice("A")),
        ]
        let correction = SpeakerCorrection(line: 3, from: .voice("A"), to: .me, reason: "Answers his own question",
                                           quote: "Hi", evidenceLine: 0)
        let result = speakers([voice("A", "Ana")], lines: lines, corrections: [correction])
        #expect(result.rows.map(\.speaker) == [.voice("A"), .me, .others], "every row wants a look, longest first")
        #expect(result.row(for: .me)?.needsAttention == true && result.row(for: .me)?.name == nil)
        let call = try #require(result.row(for: .others))
        #expect(call.choosable && !call.nameable, "the panel offers a choice; the terminal does not ask")
        #expect(call.lineCount == 1 && call.needsAttention)
        #expect(result.row(for: .voice("A"))?.corrections == [correction])
        #expect(result.row(for: .voice("A"))?.clips.map(\.line) == [1])
        #expect(result.row(for: .voice("A"))?.talkTime == 10)
        #expect(result.unclaimedLines == 1 && result.unclaimedTime == 3)
    }

    // MARK: Probably you

    /// A Slack 1:1 recorded on speakerphone: Me, the far end (A, shown as Ana) and the owner's
    /// own voice heard again as B, which the window showed as "Doru Chiulan".
    private func oneToOne(library: VoiceLibrary, b: RecordingVoices.Voice? = nil, me: String? = nil) -> RecordingSpeakers {
        let lines = [
            Utterance(start: 0, end: 6, text: "Mine", speaker: .me),
            Utterance(start: 7, end: 13, text: "Mine again", speaker: .me),
            Utterance(start: 14, end: 20, text: "Ana", speaker: .voice("A")),
            Utterance(start: 21, end: 27, text: "Ana again", speaker: .voice("A")),
            Utterance(start: 28, end: 32, text: "Me over the duck", speaker: .voice("B")),
            Utterance(start: 33, end: 37, text: "Me again", speaker: .voice("B")),
        ]
        let speaking: (Int) -> [String] = { second in
            switch second {
            case 0...13, 28...37: ["Doru Chiulan"]
            case 14...27: ["Ana"]
            default: []
            }
        }
        let participants = CallParticipants(observations: (0...38).map {
            observation(Double($0), ["Doru Chiulan", "Ana"], speaking: speaking($0), me: me)
        })
        return speakers([voice("A", "Ana", print: [0, 1]), b ?? voice("B", "Doru", print: [1, 0])], lines: lines,
                        participants: participants, library: library)
    }

    @Test("a voice the call window showed as you, whose saved person the library does not know as you, is probably you: Me first, no sounds-like, and an offer to remember")
    func probablyYouShown() throws {
        let library = VoiceLibrary(people: [
            .init(name: "Doru", prints: [[1, 0]]), .init(name: "Ana", prints: [[0, 1]]),
            .init(name: "Stranger", prints: [[0.45, 0.893]]),
        ])
        let result = oneToOne(library: library)
        let row = try #require(result.row(for: .voice("B")))
        #expect(row.yourVoice == [.shownSpeaking])
        #expect(row.candidates.first == .me([.shownSpeaking]))
        #expect(row.candidates.first?.isMe == true)
        #expect(!row.candidates.contains { $0.reason == .soundsLike })
        #expect(row.needsAttention)
        #expect(row.rememberOwner == OwnerToRemember(person: "Doru", shownName: "Doru", display: "Doru Chiulan"))
        #expect(result.row(for: .voice("A"))?.probablyYou == false)
        #expect(result.needsChecking == 2, "this voice, and Me until you say who you are")
    }

    @Test("a voice whose saved person is the library's owner is probably you, and there is nothing to remember")
    func probablyYouSaved() throws {
        var library = VoiceLibrary(people: [.init(name: "Doru", prints: [[1, 0]], isOwner: true), .init(name: "Ana", prints: [[0, 1]])])
        let lines = [Utterance(start: 0, end: 5, text: "Hi", speaker: .voice("A")), Utterance(start: 6, end: 9, text: "Yo", speaker: .voice("B"))]
        /// No roster, so only being you keeps a stranger who sounds close off the row.
        library.enroll("Stranger", [0.45, 0.893])
        let result = speakers([voice("A", "Ana", print: [0, 1]), voice("B", "Doru", print: [1, 0])], lines: lines, library: library)
        let row = try #require(result.row(for: .voice("B")))
        #expect(row.yourVoice == [.savedAsYou])
        #expect(row.candidates.first?.isMe == true)
        #expect(!row.candidates.contains { $0.reason == .soundsLike })
        let notYou = speakers([voice("B", "Bogdan", print: [1, 0])], lines: [lines[1]], library: VoiceLibrary(people: [library.people[2]]))
        #expect(notYou.candidates(for: .voice("B")).contains(.init(name: "Stranger", reason: .soundsLike)))
        #expect(row.rememberOwner == nil)
        #expect(result.row(for: .voice("A"))?.probablyYou == false)
    }

    @Test("a voice whose saved person answers to your own tile's name is probably you")
    func probablyYourCallName() throws {
        let library = VoiceLibrary(people: [.init(name: "Doru", prints: [[1, 0]], aliases: ["Doru Chiulan"])])
        let lines = [Utterance(start: 0, end: 5, text: "Hi", speaker: .voice("B"))]
        let result = speakers([voice("B", "Doru", print: [1, 0])], lines: lines,
                              participants: roster(["Doru Chiulan", "Ana"], me: "Doru Chiulan"), library: library)
        let row = try #require(result.row(for: .voice("B")))
        #expect(row.yourVoice == [.yourCallName])
        /// Already its alias: only the owner flag is left to remember.
        #expect(row.rememberOwner == OwnerToRemember(person: "Doru", shownName: "Doru", display: nil))
    }

    @Test("nothing is offered to remember when the owner named the voice themselves, or the library already has an owner")
    func noRememberOffer() throws {
        var named = RecordingVoices(voices: [voice("B", print: [1, 0])])
        named.name("B", "Costi")
        let costi = VoiceLibrary(people: [.init(name: "Costi", prints: [[1, 0]]), .init(name: "Ana", prints: [[0, 1]])])
        let byYou = try #require(oneToOne(library: costi, b: named.voices[0]).row(for: .voice("B")))
        #expect(byYou.yourVoice == [.shownSpeaking])
        #expect(byYou.rememberOwner == nil)

        let owned = VoiceLibrary(people: [.init(name: "Doru", prints: [[1, 0]]), .init(name: "Me Elsewhere", prints: [[0.6, 0.8]], isOwner: true)])
        #expect(oneToOne(library: owned).row(for: .voice("B"))?.rememberOwner == nil)
    }

    @Test("out-of-roster sounds-likes are dropped when the call window was readable for half the call, and kept otherwise")
    func soundsLikeRoster() {
        let library = VoiceLibrary(people: [.init(name: "Near", prints: [[0.45, 0.893]])])
        let lines = [Utterance(start: 0, end: 10, text: "Hello", speaker: .voice("A"))]
        let a = voice("A", print: [1, 0])
        let soundsLike = { (result: RecordingSpeakers) in result.candidates(for: .voice("A")).filter { $0.reason == .soundsLike }.map(\.name) }

        let readable = CallParticipants(observations: (0...10).map { observation(Double($0), ["Ana", "Mihai"]) })
        #expect(soundsLike(speakers([a], lines: lines, participants: readable, library: library)).isEmpty)

        let glimpse = CallParticipants(observations: [observation(0, ["Ana", "Mihai"]), observation(1, ["Ana", "Mihai"]),
                                                      observation(2, ["Ana", "Mihai"])])
        #expect(soundsLike(speakers([a], lines: [Utterance(start: 0, end: 100, text: "Long", speaker: .voice("A"))],
                                    participants: glimpse, library: library)) == ["Near"])
        #expect(soundsLike(speakers([a], lines: lines, library: library)) == ["Near"])
    }

    @Test("Me gives every line of the voice to Me; the owner is remembered only when ticked")
    func giveToMe() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = folder.appendingPathComponent("library")
        try VoiceLibrary(people: [.init(name: "Doru", prints: [[1, 0]])]).save(to: library)
        let lines = [
            Utterance(start: 0, end: 4, text: "Hi", speaker: .me),
            Utterance(start: 5, end: 9, text: "Over the duck", speaker: .voice("B")),
            Utterance(start: 10, end: 14, text: "Again", speaker: .voice("B")),
        ]
        try TranscriptStore.publish(Transcript(utterances: lines, language: "en", engine: "parakeet"),
                                    voices: RecordingVoices(voices: [voice("B", "Doru", print: [1, 0])]), in: folder)

        try SpeakerEditing.giveToMe(.voice("B"), in: folder, library: library)
        #expect(RecordingTranscript.read(in: folder)?.transcript.utterances.map(\.speaker) == [.me, .me, .me])
        #expect(VoiceLibrary.load(from: library).owner == nil)
        #expect(VoiceLibrary.load(from: library).people[0].aliases.isEmpty)

        try SpeakerEditing.reassign([1, 2], to: .voice("B"), in: folder)
        try SpeakerEditing.giveToMe(.voice("B"), in: folder,
                                    remember: OwnerToRemember(person: "Doru", shownName: "Doru", display: "Doru Chiulan"), library: library)
        let saved = VoiceLibrary.load(from: library)
        #expect(saved.owner?.name == "Doru")
        #expect(saved.owner?.aliases == ["Doru Chiulan"])
        #expect(RecordingTranscript.read(in: folder)?.transcript.utterances.allSatisfy { $0.speaker == .me } == true)
    }

    // MARK: Applying

    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("anyrec-speakers-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return OutputPlan(directory: folder).directory
    }

    @Test("giving one line to another speaker changes the speakers layer only, and the summary says it is stale")
    func reassignOneLine() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let lines = [
            Utterance(start: 0, end: 4, text: "Hi", speaker: .voice("A")),
            Utterance(start: 5, end: 9, text: "Hello", speaker: .voice("A")),
        ]
        let voices = RecordingVoices(voices: [voice("A", "Ana"), voice("B", "Mihai")])
        let source = Transcript(utterances: lines, language: "en", engine: "parakeet")
        let files = try TranscriptStore.publish(source, voices: voices, in: folder)
        let summary = try TranscriptStore.publishSummary(
            Summary(overview: "Ana said hi.", decisions: [], actions: [], provider: "t",
                    basis: .init(transcript: source, names: voices.names)), for: files[1], names: voices.names)
        let sourceData = try Data(contentsOf: files[1]), summaryData = try Data(contentsOf: summary)
        let before = try #require(TranscriptStore.selection(in: folder))

        try SpeakerEditing.reassign([1], to: SpeakerEditing.speaker(named: "mihai", in: voices), in: folder)

        let current = try #require(RecordingTranscript.read(in: folder))
        #expect(current.transcript.utterances.map(\.speaker) == [.voice("A"), .voice("B")])
        #expect(try Data(contentsOf: files[1]) == sourceData)
        #expect(try Data(contentsOf: summary) == summaryData)
        let after = try #require(TranscriptStore.selection(in: folder))
        #expect(after.transcript == before.transcript && after.wording == before.wording && after.summary == before.summary)
        #expect(Summary.read(summary)?.staleness(of: current.transcript, names: current.voices?.names ?? [:]) == .transcriptChanged)

        try SpeakerEditing.reassign([0], to: SpeakerEditing.speaker(named: "Radu", in: voices), in: folder)
        #expect(RecordingTranscript.read(in: folder)?.transcript.utterances.first?.speaker == .named("Radu"))
    }

    @Test("naming a voice from the panel records that the owner named it, and a picked name does not teach the call name")
    func namedByYou() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = folder.appendingPathComponent("library")
        var a = voice("A", print: [1, 0])
        a.identityEvidence = { var e = SpeakerIdentityEvidence(callNames: ["Ana"], voiceprintName: "Bogdan", conflict: true); e.callName = "Ana"; return e }()
        let lines = [Utterance(start: 0, end: 30, text: "Hi", speaker: .voice("A"))]
        try TranscriptStore.publish(Transcript(utterances: lines, language: "en", engine: "parakeet"),
                                    voices: RecordingVoices(voices: [a]), in: folder)

        try SpeakerEditing.name(.voice("A"), "Bogdan", in: folder, learnCallName: false, library: library)

        let voices = try #require(RecordingVoices.read(in: folder))
        #expect(voices.voices[0].namedByOwner == true)
        #expect(voices.voices[0].identityEvidence?.callNames == ["Ana"])
        let loaded = VoiceLibrary.load(from: library)
        #expect(loaded.people.map(\.name) == ["Bogdan"])
        #expect(loaded.people[0].aliases.isEmpty)
        #expect(RecordingSpeakers.read(in: folder, library: loaded)?.row(for: .voice("A"))?.basis == .namedByYou)
        #expect(RecordingSpeakers.read(in: folder, library: loaded)?.candidates(for: .voice("A")).first?.name == "Ana")
    }

    @Test("voices written before the owner flag existed read as they did")
    func oldVoices() throws {
        let json = #"{"voices":[{"letter":"A","print":[],"sample":"Hi","start":0,"end":1,"name":"Ana"}]}"#
        let voices = try JSONDecoder().decode(RecordingVoices.self, from: Data(json.utf8))
        #expect(voices.voices[0].namedByOwner == nil)
        #expect(RecordingSpeakers.basis(of: .voice("A"), voice: voices.voices[0], library: VoiceLibrary()) == .named)
    }

    // MARK: Who Me is

    @Test("Me is offered the library's owner and the call window's name for you, and carries the name it was given")
    func meCandidates() throws {
        let library = VoiceLibrary(people: [.init(name: "Doru", prints: [[1, 0]], aliases: ["Doru Chiulan"], isOwner: true)])
        /// B is left unnamed here: a name another speaker carries is never offered for Me.
        let unnamed = oneToOne(library: library, b: voice("B", print: [1, 0]), me: "Doru Chiulan")
        let me = try #require(unnamed.row(for: .me))
        #expect(me.candidates.map(\.name) == ["Doru"], "the owner and their call-window name are one person, offered once")
        #expect(me.candidates.first?.reason == .savedAsYou)
        #expect(me.needsAttention)

        let lines = [Utterance(start: 0, end: 4, text: "Hi", speaker: .me)]
        var voices = RecordingVoices(voices: [])
        voices.meName = "Doru Chiulan"
        let named = RecordingSpeakers.build(lines: lines, voices: voices, suggestions: [], corrections: [],
                                            participants: nil, info: nil, library: library)
        #expect(named.row(for: .me)?.name == "Doru Chiulan" && named.row(for: .me)?.needsAttention == false)
        #expect(named.label(.me) == "Doru Chiulan")
    }

    @Test("naming Me marks the owner, makes a person when nobody has the name, and names Me in this recording")
    func nameMe() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let libraryFolder = folder.appendingPathComponent("voices")
        defer { try? FileManager.default.removeItem(at: folder) }
        let recording = folder.appendingPathComponent("rec-2026-11-16-095833")
        try FileManager.default.createDirectory(at: recording, withIntermediateDirectories: true)
        try VoiceLibrary(people: [.init(name: "Costin", prints: [[0, 1]])]).save(to: libraryFolder)
        let transcript = Transcript(utterances: [
            Utterance(start: 0, end: 2, text: "Salut", speaker: .me),
            Utterance(start: 2, end: 4, text: "Hei", speaker: .others),
        ], language: "ro", engine: "parakeet")
        _ = try TranscriptStore.publish(transcript, voices: nil, in: recording)

        try SpeakerEditing.nameMe("Doru Chiulan", in: recording, library: libraryFolder)

        let saved = VoiceLibrary.load(from: libraryFolder)
        #expect(saved.owner?.name == "Doru Chiulan" && saved.owner?.prints.isEmpty == true)
        #expect(saved.people.first { $0.name == "Costin" }?.isOwner == false)
        let current = try #require(RecordingTranscript.read(in: recording))
        #expect(current.voices?.meName == "Doru Chiulan")
        #expect(current.named.utterances.first?.speaker == .named("Doru Chiulan"), "exports call you by name")
        #expect(current.named.utterances.last?.speaker == .others)
    }

    @Test("a summary written with \"Me\" reads with the owner's name")
    func summaryMe() {
        var voices = RecordingVoices(voices: [])
        voices.meName = "Doru"
        #expect(Summary.fill("Me asked Speaker A. Meeting at noon.", voices.names) == "Doru asked Speaker A. Meeting at noon.")
    }
}
