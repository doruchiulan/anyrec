import Foundation
import AnyRecKit

/// The Kit's facts in the menu bar's words. The terminal says "⏎ on Transcript"; a
/// panel has no ⏎ and no row to press it on, so the same advisory says where to go
/// instead. Nothing here draws anything, which is what makes it the tested part.
enum Wording {
    static func clock(_ elapsed: TimeInterval) -> String {
        let total = Int(elapsed)
        return total < 3_600
            ? String(format: "%02d:%02d", total / 60, total % 60)
            : String(format: "%d:%02d:%02d", total / 3_600, (total / 60) % 60, total % 60)
    }

    static func remaining(_ left: TimeInterval) -> String {
        let total = Int(left)
        return total >= 60 ? "\(total / 60)m left" : "\(total)s left"
    }

    static func microphone(_ device: AudioInputDevice?) -> String {
        guard let device else { return "Off" }
        return device.isDefault ? "\(device.name) (default)" : device.name
    }

    static func stopAfter(_ interval: TimeInterval?) -> String {
        guard let interval else { return "No time limit" }
        let minutes = Int(interval) / 60
        return minutes % 60 == 0 ? "After \(minutes / 60)h" : "After \(minutes)m"
    }

    /// Engines are picked from a menu that shows every option at once, so each one says
    /// what it is and, when it cannot run, that it cannot.
    static func engine(_ engine: TranscriptionEngine?, _ readiness: Readiness) -> String {
        guard let engine else { return "Off" }
        let ready = readiness.of(engine).isReady
        switch engine {
        case .auto: return "Automatic"
        case .parakeet: return ready ? "Parakeet (on device)" : "Parakeet (downloads \(ParakeetSetup.downloadSize))"
        case .apple: return ready ? "Apple (on device, English only)" : "Apple (needs macOS 26)"
        case .whisper: return ready ? "Whisper (on device)" : "Whisper (not installed)"
        case .openai: return ready ? "OpenAI (uploads audio)" : "OpenAI (no API key)"
        }
    }

    /// The panel's Transcript row reads as a sentence, with the engine as its object.
    static func transcribeRow(_ engine: TranscriptionEngine?, _ readiness: Readiness) -> String {
        guard let engine else { return "Don't transcribe" }
        return "Transcribe with \(engineName(engine))"
    }

    /// Recordings carry no title of their own, so one is called by when it began.
    static func title(started: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = started.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(started, inSameDayAs: now) { return "Today, \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(started, inSameDayAs: yesterday)
        {
            return "Yesterday, \(time)"
        }
        return "\(started.formatted(.dateTime.day().month(.abbreviated))), \(time)"
    }

    /// The window's title when it was kept, else when the recording began.
    static func title(of entry: LibraryEntry) -> String {
        entry.info.map(\.title).flatMap { $0.isEmpty ? nil : $0 } ?? title(started: entry.started)
    }

    /// "Today at 10:02 · 38:12 · Microsoft Teams · 1512×982, 30 fps"
    static func meta(of entry: LibraryEntry) -> String {
        var parts = [
            entry.started.formatted(date: .abbreviated, time: .shortened), duration(entry.duration),
        ]
        if let app = entry.info?.appName { parts.append(app) }
        if let picture = entry.info.flatMap(picture) { parts.append(picture) }
        parts.append(size(entry.bytes))
        return parts.joined(separator: " · ")
    }

    /// What was kept of the picture: its size and rate, or that there was none. The window
    /// an audio-only recording was pointed at still has a size, which is not worth saying.
    static func picture(_ info: RecordingInfo) -> String? {
        if info.audioOnly { return audioOnly }
        return info.width > 0 ? "\(info.width)×\(info.height), \(info.fps) fps" : nil
    }

    static let audioOnly = "Audio only"

    /// The line under the title where an audio-only recording's picture would be:
    /// "Audio only · Microsoft Teams", or "Audio only · Display" for a whole screen.
    static func audioSurface(of entry: LibraryEntry) -> String {
        audioSurface(app: entry.info?.appName, display: entry.info.map { $0.bundleID == nil } ?? false)
    }

    static func audioSurface(app: String?, display: Bool) -> String {
        [audioOnly, app ?? (display ? "Display" : nil)].compactMap { $0 }.joined(separator: " · ")
    }

    /// The two ways to start, wherever starting is offered: the panel's buttons, the
    /// call banner, the notification. The window is picked either way.
    static func record(video: Bool) -> String { video ? "Record Window…" : "Record Audio Only…" }

    /// The same two in the File and Dock menus, which name what they make.
    static func newRecording(video: Bool) -> String {
        video ? "New Recording…" : "New Audio-Only Recording…"
    }

    static func recordHelp(video: Bool) -> String {
        video
            ? "Choose a window or display and start recording"
            : "Choose a window or display and record its sound, without the picture"
    }

    /// The banner's buttons are short; the banner's question names the call.
    static func bannerRecord(video: Bool) -> String { video ? "Record" : "Audio Only" }

    /// The live panel's line under the window's title.
    static func live(video: Bool, width: Int, height: Int, fps: Int, droppedFrames: Int?) -> String {
        guard video else { return "Audio only — no video is being saved" }
        return "\(width)×\(height) · \(fps) fps" + (droppedFrames.map { " · \($0) frames dropped" } ?? "")
    }

    /// The line under a list row's title.
    /// A list row's bold first line. The second line carries the time, so a recording
    /// with no window title is simply a recording, as an untitled note is a New Note.
    static func rowTitle(of entry: LibraryEntry) -> String {
        if let title = entry.info?.title, !title.isEmpty { return title }
        return "Recording"
    }

    /// The line under a list row's title: the time and app when the title is the window's,
    /// the size when the title is already the time.
    static func subtitle(of entry: LibraryEntry) -> String {
        guard entry.info?.title.isEmpty == false else { return size(entry.bytes) }
        return [entry.started.formatted(date: .omitted, time: .shortened), entry.info?.appName]
            .compactMap { $0 }.joined(separator: " · ")
    }

    static func people(_ count: Int) -> String {
        count == 1 ? "1 person" : "\(count) people"
    }

    static func imported(people: Int, prints: Int) -> String {
        switch (people, prints) {
        case (0, 0): return "Nothing new: every voice in the file was already here."
        case (0, let n): return "Added \(n == 1 ? "a voiceprint" : "\(n) voiceprints") to people already here."
        case (let p, _): return "Added \(p == 1 ? "one person" : "\(p) people") to the library."
        }
    }

    static func count(_ recordings: Int) -> String {
        recordings == 1 ? "1 recording" : "\(recordings) recordings"
    }

    static func unnamed(_ voices: Int) -> String {
        voices == 1 ? "1 unnamed voice" : "\(voices) unnamed voices"
    }

    static func voiceprints(_ count: Int) -> String {
        count == 1 ? "1 voiceprint" : "\(count) voiceprints"
    }

    /// A People row's second line: prints, the display names learned from call windows,
    /// and whether this is the person recording.
    static func person(_ person: VoiceLibrary.Person) -> String {
        var parts = [voiceprints(person.prints.count)]
        if !person.aliases.isEmpty { parts.append("also “" + person.aliases.joined(separator: "”, “") + "”") }
        if person.isOwner { parts.insert("You", at: 0) }
        return parts.joined(separator: " · ")
    }

    /// How much of the call the call window could be read for.
    static func readable(_ readable: TimeInterval, of duration: TimeInterval) -> String {
        guard duration > 0 else { return "Readable for \(clock(readable))." }
        let share = Int((min(1, readable / duration) * 100).rounded())
        return "The call window could be read for \(clock(readable)) of \(clock(duration)) (\(share)%)."
    }

    /// One observed participant's detail: how long they were shown as the only one speaking.
    static func spokeAlone(_ seconds: TimeInterval) -> String {
        seconds < 1 ? "Not shown speaking" : "Shown speaking for \(clock(seconds))"
    }

    /// Facts about this recording's voices worth a line under the roster.
    static func voiceFacts(_ voices: RecordingVoices?) -> [String] {
        guard let voices else { return [] }
        var lines: [String] = []
        if let merge = voices.ownerMerge {
            let back = merge.toMe == 1 ? "1 line" : "\(merge.toMe) lines"
            let away = merge.toOthers == 1 ? "1 line" : "\(merge.toOthers) lines"
            lines.append("Your voice was also heard as a far-end voice. \(back) went back to Me; \(away) the microphone wasn’t carrying went to the call.")
        }
        for voice in voices.voices {
            if let fused = voice.identityEvidence?.fusedNames, fused.count > 1 {
                let label = voice.name ?? "Speaker \(voice.letter)"
                lines.append("\(label) may be more than one person: the call window showed " + fused.joined(separator: " and ") + " while this voice spoke.")
            }
        }
        if let named = voices.callLinesNamed, named > 0 {
            lines.append(named == 1 ? "1 line no voice covered was named from the call window."
                         : "\(named) lines no voice covered were named from the call window.")
        }
        return lines
    }

    static let rates: [Float] = [0.75, 1, 1.25, 1.5, 2]

    static func rate(_ rate: Float) -> String { "\(rate.formatted())×" }

    static func trackName(_ track: Playback.Track) -> String {
        switch track {
        case .callAudio: "Call audio"
        case .microphone: "Microphone"
        case .video: "Video"
        }
    }

    /// Free bytes on the volume holding the recordings folder, for the sidebar's bar.
    static func freeSpace(for path: String) -> Int64 {
        let url = URL(fileURLWithPath: path.expandingTilde)
        let free = try? url.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        return free ?? 0
    }

    /// The part of a transcript line being said at `time`. Engines return a paragraph per
    /// line and no word times, so the line is cut at sentence ends (then commas, then
    /// spaces) into pieces of at most `limit` characters, and its span is shared out by
    /// length — the same estimate the Kit uses to split a line between two speakers.
    static func caption(of line: Utterance, at time: TimeInterval, limit: Int = 90) -> String {
        let pieces = captionPieces(line.text, limit: limit)
        guard pieces.count > 1, line.end > line.start else { return pieces.first ?? line.text }
        let total = Double(pieces.reduce(0) { $0 + $1.count })
        var reached = line.start
        for piece in pieces {
            reached += (line.end - line.start) * Double(piece.count) / total
            if time < reached { return piece }
        }
        return pieces[pieces.count - 1]
    }

    static func captionPieces(
        _ text: String, limit: Int, levels: ArraySlice<String> = [".!?…", ",;:", " "][...]
    ) -> [String] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit, let separators = levels.first else { return [text] }

        var pieces: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if separators.contains(character) {
                pieces.append(current)
                current = ""
            }
        }
        pieces.append(current)

        /// A piece still too long here is cut again at the next level down.
        let cut = pieces
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .flatMap { $0.count > limit ? captionPieces($0, limit: limit, levels: levels.dropFirst()) : [$0] }

        /// Neighbours are joined back up to the limit, so a run of short sentences reads as
        /// one caption rather than flickering past.
        var joined: [String] = []
        for piece in cut {
            if let last = joined.last, last.count + 1 + piece.count <= limit {
                joined[joined.count - 1] = last + " " + piece
            } else {
                joined.append(piece)
            }
        }
        return joined
    }

    static func bytes(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// How long it ran, for the trailing edge of a row.
    static func when(_ entry: LibraryEntry) -> String { duration(entry.duration) }

    /// The heading a recording sits under, the way Notes groups its list: Today,
    /// Yesterday, the previous week, the previous month, then each month of this year,
    /// then each year before it.
    static func group(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if calendar.isDateInYesterday(date, relativeTo: now) { return "Yesterday" }
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
        ).day ?? 0
        if days <= 7 { return "Previous 7 Days" }
        if days <= 30 { return "Previous 30 Days" }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.wide))
        }
        return date.formatted(.dateTime.year())
    }

    /// The date at the start of a row's second line: the time for today and yesterday,
    /// whose headings already say the day, and the date for anything older.
    static func rowDate(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) || calendar.isDateInYesterday(date, relativeTo: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(date: .numeric, time: .omitted)
    }

    /// A row's third line, where Notes puts the folder: the app it was recorded in, when
    /// that is known, and how long it ran.
    static func rowSource(of entry: LibraryEntry) -> String {
        [entry.info?.appName, duration(entry.duration)].compactMap { $0 }.joined(separator: " · ")
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        clock(seconds)
    }

    /// The settings window lists the engines by name, with what stands between each one
    /// and running. The panel's row says both at once because it is a menu; here there
    /// are two columns to put them in.
    static func engineName(_ engine: TranscriptionEngine) -> String {
        switch engine {
        case .auto: "Automatic"
        case .parakeet: "Parakeet"
        case .apple: "Apple"
        case .whisper: "Whisper"
        case .openai: "OpenAI"
        }
    }

    /// The default-engine pop-up, where `nil` is the off position.
    static func engineChoice(_ engine: TranscriptionEngine?) -> String {
        engine.map(engineName) ?? "Off"
    }

    static func engineBlurb(_ engine: TranscriptionEngine) -> String {
        switch engine {
        case .openai: "Sends audio to OpenAI"
        case .parakeet: "On this Mac, 25 languages"
        case .auto, .apple, .whisper: "On this Mac"
        }
    }

    static func engineStatus(_ engine: TranscriptionEngine, _ readiness: Readiness) -> String {
        guard !readiness.of(engine).isReady else {
            return "Ready"
        }
        switch engine {
        case .auto: return "Nothing installed to run it"
        case .parakeet: return "Not downloaded"
        case .apple: return "Needs macOS 26"
        case .whisper: return "Not installed"
        case .openai: return "No API key"
        }
    }

    /// What pressing it will fetch, on the button rather than after it.
    static func install(_ steps: [WhisperSetup.Step]) -> String {
        "Download (\(AssetDownload.describe(WhisperSetup.downloadSize(of: steps))))"
    }

    static func keyOutcome(_ outcome: OpenAIKey.StoreOutcome) -> String {
        switch outcome {
        case .saved: "Saved. OpenAI accepted it."
        case .savedUnverified(let reason): "Saved without checking it: \(reason)"
        case .savedButShadowed: "Saved, but OPENAI_API_KEY in your environment wins over it."
        case .rejected(let complaint): "Not saved — \(complaint)"
        case .notSaved(let reason): "Not saved — \(reason)"
        }
    }

    static func wasRefused(_ outcome: OpenAIKey.StoreOutcome) -> Bool {
        switch outcome {
        case .rejected, .notSaved: true
        case .saved, .savedUnverified, .savedButShadowed: false
        }
    }

    /// Both of the advisories that name a way out now have a window to name instead of
    /// a command: the app is installable on its own, so "run anyrec in a terminal" was
    /// advice a cask user could not take.
    static func advisory(_ advisory: Advisory) -> String {
        switch advisory {
        case .parakeetNotSetUp:
            "No engine is set up yet. Choose Parakeet to download it (\(ParakeetSetup.downloadSize))."
        case .whisperNotSetUp:
            "whisper is not set up yet. Install it in Settings › Transcription."
        case .openAIKeyMissing:
            "No OpenAI key. Set OPENAI_API_KEY, or paste one in Settings › Transcription."
        case .appleUnavailable:
            "Apple's engine needs macOS 26. Pick whisper or OpenAI instead."
        case .ffmpegMissing:
            "ffmpeg is missing, so the tracks will not be merged into one playable file. Install it in Settings › Transcription."
        case .openAIUploadsAudio:
            "OpenAI transcribes off your machine — both audio tracks are uploaded."
        case .appleCoversSomeLanguages(let count):
            "Apple has models for \(count) languages; whisper covers the rest."
        case .bothAudioTracksOff:
            "Both audio tracks are off — this will be a silent video."
        case .speakersNotSetUp:
            "The far end will be one voice. Fetch the speaker model in Settings › Transcription."
        case .accessibilityMissing:
            "Mute in Teams and Slack is not seen, so the microphone stays in while you are muted. "
                + "Allow AnyRec under Privacy & Security › Accessibility."
        }
    }

    /// The Speakers section's one line: whether the far end can be told apart here,
    /// and how many voices have names.
    static func speakers(ready: Bool, known: [String]) -> String {
        guard ready else {
            return "Not downloaded. Every far-end voice is one \"Call\" until it is."
        }
        guard !known.isEmpty else {
            return "Told apart on this machine. Name a voice after a transcript to remember it."
        }
        return "Told apart on this machine. Known by name: \(known.joined(separator: ", "))."
    }

    /// The notification when a call app takes the microphone. The button says what
    /// pressing it does, because the picker is a second step.
    static func callOffer(_ app: CallApp) -> (title: String, body: String) {
        ("\(app.name) is on a call", "Record it? Either button opens the window picker.")
    }

    static func reviewTitle(_ current: RecordingTranscript) -> String {
        if let provider = current.reviewProvider { return "Reviewed with \(provider.name)" }
        return current.reviewFailures.isEmpty ? "Transcript versions" : "Original transcript kept"
    }

    static func versions(_ sources: [TranscriptStore.SourceVersion]) -> String {
        sources.count == 1 ? "1 source transcript" : "\(sources.count) source transcripts"
    }

    /// A version's row in View Sources: the engine, when it was written, and its part.
    static func version(_ source: TranscriptStore.SourceVersion) -> String {
        let when = source.written.formatted(date: .abbreviated, time: .shortened)
        let role: String
        switch source.role {
        case .selected: role = "Current · timing reference"
        case .compared: role = "Compared"
        case .earlier: role = "Earlier version"
        }
        let engine = TranscriptionEngine(rawValue: source.engine).map(engineName) ?? source.engine.capitalized
        return "\(engine) · \(role) · \(when)"
    }

    /// Nil when the summary still describes the transcript.
    static func summaryStale(_ staleness: Summary.Staleness) -> String? {
        switch staleness {
        case .current: nil
        case .transcriptChanged: "The transcript has changed since this summary was written."
        case .nameChanged: "A speaker’s name has changed since this summary was written."
        }
    }

    static func summaryFailure(_ reason: String) -> String { "The transcript was written; the summary failed: \(reason)" }

    /// The footer under "Review with a second engine".
    static func comparison(_ options: TranscriptionOptions) -> String {
        guard options.review else { return "Turn on transcript review to compare engines. Other engines run only for a review." }
        guard options.compareEngines else {
            return "Review reads the chosen engine’s transcript. Turn this on to also run the engines checked here and let the reviewer compare their wording."
        }
        let remote = options.comparisonEngines.contains(.openai) && options.enabledEngines.contains(.openai)
            ? " OpenAI receives the audio when it is checked." : " Audio stays on this Mac."
        return "The chosen engine writes the transcript; the checked engines also run, and the reviewer compares every version line by line." + remote
    }

    static func merge(_ outcome: MergeOutcome) -> String {
        switch outcome {
        case .merged(let mux): "Merged into “\(mux.output.lastPathComponent)”"
        case .notRequested: "The tracks were left separate, as asked"
        case .ffmpegMissing: "Not merged into one file: ffmpeg is not installed"
        case .failed(let reason): "The merge failed: \(reason)"
        }
    }

    static func transcript(_ outcome: TranscriptOutcome) -> String {
        switch outcome {
        case .written(let files, _, _, _):
            "Wrote \(files.count == 1 ? "a transcript" : "\(files.count) transcript files")"
        case .nothingHeard:
            "Nothing was heard, so there is no transcript"
        case .failed(let reason, let remedy):
            ["No transcript: \(reason)", remedy.map(self.remedy)]
                .compactMap { $0 }.joined(separator: " ")
        }
    }

    static func remedy(_ remedy: TranscriptionError.Remedy) -> String {
        switch remedy {
        case .downloadModel, .installFFmpeg, .downloadParakeet:
            "Set it up in Settings › Transcription."
        case .provideOpenAIKey:
            "Set OPENAI_API_KEY, or paste a key in Settings › Transcription."
        }
    }
}

private extension Calendar {
    func isDateInYesterday(_ date: Date, relativeTo now: Date) -> Bool {
        guard let yesterday = self.date(byAdding: .day, value: -1, to: now) else { return false }
        return isDate(date, inSameDayAs: yesterday)
    }
}
