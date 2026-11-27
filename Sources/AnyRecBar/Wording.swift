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
        audioSurface(app: entry.info?.appName, display: entry.shared == nil && entry.info.map { $0.bundleID == nil } ?? false)
    }

    static func audioSurface(app: String?, display: Bool) -> String {
        [audioOnly, app ?? (display ? "Display" : nil)].compactMap { $0 }.joined(separator: " · ")
    }

    /// The two ways to start, wherever starting is offered: the panel's buttons, the
    /// call banner, the notification. The window is picked either way.
    static func record(video: Bool) -> String { video ? "Record Window…" : "Record Audio Only…" }

    /// With a call listed above them, the picker commands are for anything else.
    static func otherWindow(video: Bool) -> String { video ? "Other Window…" : "Other Window, Audio Only…" }

    /// A listed call's own buttons. The row above them names the call.
    static func recordCall(video: Bool) -> String { video ? "Record Call" : "Audio Only" }

    static func ongoingCalls(_ count: Int) -> String { count == 1 ? "Ongoing Call" : "Ongoing Calls" }

    /// The File menu's copy of a listed call's buttons, which has no row to name the call.
    static func recordCall(_ call: OngoingCall, video: Bool) -> String {
        video ? "Record \(call.app.name) Call" : "Record \(call.app.name) Call, Audio Only"
    }

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
    /// The line under the recording panel's clock: "Extended LHO EU · Teams · audio only",
    /// with "· 12m left" when a stop time is set.
    static func recordingLine(title: String, app: String?, audioOnly: Bool, remaining: TimeInterval?) -> String {
        var parts = [title]
        if let app, !title.localizedCaseInsensitiveContains(app) { parts.append(app) }
        if audioOnly { parts.append("audio only") }
        if let remaining { parts.append(Self.remaining(remaining)) }
        return parts.joined(separator: " · ")
    }

    /// Said while the call cannot hear the microphone. The microphone's own track keeps
    /// recording; only the mix and the transcript leave it out.
    static func mutedInCall(app: String?) -> String {
        "Muted in \(app ?? "the call") — your microphone is left out of the mix"
    }

    static func droppedFrames(_ count: Int) -> String {
        "\(count) frames dropped — the Mac is busy"
    }

    /// A level bar as VoiceOver reads it.
    static func level(_ tint: LevelBars.Tint) -> String {
        switch tint {
        case .healthy: "good"
        case .hot: "too loud"
        case .quiet: "quiet"
        case .muted: "muted"
        }
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

    /// What a library row says still needs the owner: people not named yet, else lines
    /// nobody claimed. Nil when there is nothing to do.
    static func toName(voices: Int, unclaimed: Bool) -> String? {
        if voices > 0 { return voices == 1 ? "1 person to name" : "\(voices) people to name" }
        return unclaimed ? "Lines to check" : nil
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
        if !person.waiting.isEmpty { parts.append("\(person.waiting.count) waiting for another call") }
        if !person.retired.isEmpty { parts.append("\(person.retired.count) set aside") }
        if !person.aliases.isEmpty { parts.append("also “" + person.aliases.joined(separator: "”, “") + "”") }
        if person.isOwner { parts.insert("You", at: 0) }
        return parts.joined(separator: " · ")
    }

    /// One observed participant's detail: how long they were shown as the only one speaking.
    static func spokeAlone(_ seconds: TimeInterval) -> String {
        seconds < 1 ? "Not shown speaking" : "Shown speaking for \(clock(seconds))"
    }

    // MARK: People in this call

    /// Under a person's name in the list.
    static func personState(_ state: RecordingSpeakers.PersonState, app: String?) -> String {
        switch state {
        case .you: "Your microphone"
        case .recognised: "Recognised by voice"
        case .rememberedNextTime: "Will be recognised next time"
        case .rememberedAfterAnotherCall: "Will be recognised after one more call"
        case .newFromCallWindow: "New · name from \(shortApp(app))"
        case .unnamed: "Not named yet"
        case .namedForThisCall: "Named for this call"
        }
    }

    /// "Microsoft Teams" reads as Teams in a sentence; anything else as it is, or "the call".
    static func shortApp(_ app: String?) -> String {
        guard let app, !app.isEmpty else { return "the call window" }
        return app == "Microsoft Teams" ? "Teams" : app
    }

    /// Talk time as people feel it: "45 sec", "26 min".
    static func talk(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "\(max(1, Int(seconds.rounded()))) sec" : "\(Int((seconds / 60).rounded())) min"
    }

    static func questions(_ count: Int) -> String {
        count == 0 ? "Nothing to check" : count == 1 ? "1 question" : "\(count) questions"
    }

    /// The People panel with no question left. Lines nobody claimed may remain, which the
    /// transcript shows as "Not sure who": saying everyone has a name beside them read as wrong.
    static func nothingToAsk(unclaimed: Int) -> String {
        switch unclaimed {
        case 0: "Everyone has a name. Nothing to check."
        case 1: "1 short bit has no name, and AnyRec can't tell who said it. Give it to someone under Not sure who, or leave it."
        default: "\(unclaimed) short bits have no name, and AnyRec can't tell who said them. Give them to someone under Not sure who, or leave them."
        }
    }

    /// The first name, for buttons ("Yes, that's Madalin"). "Barbura, Claudiu (Contractor)"
    /// is Claudiu.
    static func firstName(_ name: String) -> String {
        var core = name
        if let open = core.lastIndex(of: "("), core.hasSuffix(")") { core = String(core[..<open]).trimmingCharacters(in: .whitespaces) }
        let parts = core.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2, !parts[1].isEmpty { core = parts[1] }
        return core.split(separator: " ").first.map(String.init) ?? name
    }

    /// "Ana", "Ana and Radu", "Ana, Radu and Ioana".
    static func list(_ names: [String]) -> String {
        names.count < 2 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    static func nextCall(recognised: [String]) -> String? {
        recognised.isEmpty ? nil : "Next call, AnyRec will recognise \(list(recognised)) by voice."
    }

    static func notYet(_ names: [String]) -> String? {
        names.isEmpty ? nil : "Not yet: \(list(names)). AnyRec remembers someone once you've said who they are and it has heard them clearly."
    }

    // MARK: Library health    // MARK: Library health

    /// Under a speaker the owner named, when the library did not simply keep its voice.
    static func kept(_ admission: VoiceLibrary.Admission?) -> String? {
        switch admission {
        case .waiting?: "Their voice will be remembered after one more call: it sounds unlike their earlier ones."
        case .tooShort?: "Named for this call only: too little speech to remember the voice."
        case .mixed?: "Named for this call only: this may be more than one person."
        case .soundsLike(let other)?: "Named for this call only: the voice sounds like \(other)."
        case .filed?, .confirmed?, nil: nil
        }
    }

    static func samePerson(_ a: String, _ b: String) -> String { "Are \(a) and \(b) the same person?" }

    static func unlikeVoices(_ person: String, isOwner: Bool) -> String {
        isOwner ? "One of your voice recordings doesn't sound like the others."
            : "One of \(person)'s voice recordings doesn't sound like the others."
    }

    // MARK: Speakers

    /// A checklist step's state, for VoiceOver.
    static func stepState(_ state: ProcessingSteps.State) -> String {
        switch state {
        case .waiting: "Waiting"
        case .running: "In progress"
        case .done: "Done"
        case .failed: "Failed"
        }
    }

    /// The panel's row for an update a background check held back during a call.
    static func updateAvailable(_ version: String) -> String { "AnyRec \(version) is available" }

    static let updatesFooter = "Checks github.com/doruchiulan/anyrec once a day for a newer version. Updates install when AnyRec quits, never while a recording is running or being saved."

    // MARK: Sharing

    /// A sync folder with the cloud that keeps it: "AnyRec (iCloud Drive)", "Team (OneDrive –
    /// Blueprint)", "Meetings (on this Mac)".
    static func syncFolder(_ folder: URL) -> String {
        "\(folder.lastPathComponent) (\(CloudFolder.provider(of: folder) ?? "on this Mac"))"
    }

    /// The sync menu's first line: where a recording is shared, or that it is not.
    static func syncedTo(_ folder: URL?) -> String { folder.map { "Synced to \(syncFolder($0))" } ?? "Not synced" }

    static func syncedTo(places: Int) -> String { "Synced to \(places) places" }

    static func stopSyncing(_ place: String) -> String { "Stop syncing to \(place)?" }

    /// Deleting a synced recording: what happens to its shared copies either way.
    /// The copy in the sync location is the one that shows under Shared with You afterwards.
    static func trashSynced(places: [String], inLocation: Bool) -> String {
        let there = places.count == 1 ? "It is synced to \(places[0])." : "It is synced to \(places.joined(separator: " and "))."
        let kept = inLocation ? "colleagues can still watch it, and so can you, under Shared with You." : "colleagues can still watch it."
        return there + " Keep the shared copies and " + kept + " Remove them and it is gone for everyone. Copies colleagues made stay either way."
    }

    static let syncFolderFooter = "Recordings you sync go to this folder, and meetings your colleagues sync to it are listed under Shared with you. Share it with your team as view-only so nobody can change your meetings; AnyRec puts back anything that is changed. Your recordings themselves stay in the recordings folder. Disconnecting leaves recordings already synced there as they are."

    static let chooseSyncLocation = "Choose Sync Location…"

    static let noSyncLocation = "Choose a sync location from a recording's Sync button. Meetings your colleagues sync there appear here."

    static let syncLocationTip = "Recordings you sync go here, and meetings your colleagues sync here are listed under Shared with you. Share this folder with your team as view-only, so nobody can change your meetings."

    /// The sync menu's second line, for a synced recording: what state the shared copy is in.
    static func syncStatus(failure: String?, restored: Date?, preparing: Bool = false, upload: SharedUpload?,
                           now: Date = Date()) -> String {
        if let failure { return "Needs attention: \(failure)" }
        if preparing { return "Preparing the shared copy…" }
        if case .failed(let reason)? = upload { return "Couldn't upload: \(reason)" }
        if case .uploading? = upload { return "Uploading…" }
        if let restored, now.timeIntervalSince(restored) < 86_400 {
            return "Restored at \(restored.formatted(date: .omitted, time: .shortened)): a shared file had been changed"
        }
        return upload == .notCloud ? "Up to date. This folder isn't in a cloud drive." : "Up to date"
    }

    static func uploading(done: Int64, total: Int64) -> String {
        done > 0 ? "Uploading \(size(done)) of \(size(total))" : "Waiting to upload \(size(total))"
    }

    /// What of the recording's separate tracks colleagues get, when not both.
    static func sharedTracks(call: Bool, microphone: Bool) -> String? {
        if call && !microphone { return "Your microphone isn't shared separately: mute couldn't be followed in this call" }
        return nil
    }

    // Someone else's recording.

    static func sharedBy(_ name: String?) -> String { name.map { "Shared by \($0)" } ?? "Shared with you" }

    static func downloadsOnPlay(bytes: Int64?, cloud: String) -> String {
        [bytes.map(size), "in \(cloud). Downloads when you play it."].compactMap { $0 }.joined(separator: " ")
    }

    static func downloading(done: Int64, total: Int64, cloud: String) -> String {
        done > 0 ? "Downloading \(size(done)) of \(size(total))…" : "Getting \(size(total)) from \(cloud)…"
    }

    static func downloadStalled(cloud: String) -> String { "Waiting for \(cloud). Check that it's running and you're online." }

    static func waitingForOwner(_ name: String?) -> String {
        "Not uploaded yet. It plays as soon as \(name.map { "\($0)'s Mac" } ?? "its owner's Mac") finishes uploading."
    }

    /// The shared list's note while meetings' notes are on their way.
    static func arriving(_ count: Int) -> String { count == 1 ? "1 meeting is on its way…" : "\(count) meetings are on their way…" }

    /// Shown in the folder picker when choosing where to sync.
    static let viewOnlyTip = "Share this folder with your team as view-only, so nobody can change your meetings. AnyRec puts back anything that is changed."

    // MARK: Compression

    static let compressionFooter = "Once a recording is saved, its video is re-encoded about 15 times smaller at the same resolution, with text in shared screens as sharp as before. It runs only while nothing is being recorded or processed and the Mac is plugged in, and stops the moment a recording starts. The audio tracks are never changed."

    /// "Compressing “Design review”…", "3 recordings waiting · 1.2 GB saved", or nil when
    /// there is nothing to say.
    static func compression(current: String?, waiting: Int, saved: Int64) -> String? {
        var parts: [String] = []
        if let current {
            parts.append("Compressing “\(current)”…")
        } else if waiting > 0 {
            parts.append(waiting == 1 ? "1 recording waiting" : "\(waiting) recordings waiting")
        }
        if saved > 0 { parts.append("\(size(saved)) saved") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: AI apps

    static func agentName(_ app: AgentApp) -> String {
        switch app {
        case .claudeCode: "Claude Code"
        case .claudeDesktop: "Claude Desktop"
        case .codex: "ChatGPT and Codex"
        }
    }

    /// The line under an app's name: where it stands, and what to do after connecting.
    static func agentDetail(
        _ app: AgentApp, _ state: AgentConnection, stale: Bool = false, home: String = NSHomeDirectory()
    ) -> String {
        if stale, state == .connected {
            return app == .claudeDesktop ? "Connected. Restart Claude to load it." : "Connected. Restart ChatGPT to load it."
        }
        switch state {
        case .notInstalled:
            return app == .claudeCode ? "The claude command wasn't found." : "Not installed."
        case .notConnected:
            switch app {
            case .claudeCode: return "Adds AnyRec to every project, through claude mcp."
            case .claudeDesktop: return "Claude reads it when it opens."
            case .codex: return "Both apps read one setting, when they open."
            }
        case .connected:
            switch app {
            case .claudeCode: return "Connected in every project. New sessions can use it."
            case .claudeDesktop: return "Connected."
            case .codex: return "Connected."
            }
        case .connectedElsewhere(let launch):
            guard let launch else { return "Has an anyrec entry that isn't a command." }
            return "Set up for another anyrec: \(tilde(launch.command, home: home))"
        case .unreadable(let file):
            return "Couldn't read \(tilde(file.path, home: home)), so it was left alone."
        }
    }

    static func agentRestart(_ app: AgentApp) -> String {
        app == .claudeDesktop ? "Restart Claude" : "Restart ChatGPT"
    }

    static let agentsFooter = "AI apps can list, search and read your recordings' transcripts, summaries and names through AnyRec's read-only server. They can't record, change or delete anything, and never get audio, video or voiceprints. What they read may be sent to that app's provider."
    static let agentsTranslocated = "Move AnyRec to Applications first: AI apps start it from where it is, and macOS runs it from a temporary copy until then."

    private static func tilde(_ path: String, home: String) -> String {
        path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// A transcript line's speaker as shown: Me by the owner's name once it is known.
    /// What asking the review's model about the lines nobody claimed came to.
    static func unclaimedPlaced(asked: Int, sure: Int, likely: Int, provider: String) -> String {
        guard asked > 0 else { return "There's nothing left to ask about." }
        guard sure + likely > 0 else { return "\(provider) couldn't tell who said any of them." }
        let lines = { (count: Int) in count == 1 ? "1 line" : "\(count) lines" }
        var parts: [String] = []
        if sure > 0 { parts.append("is sure who said \(lines(sure))") }
        if likely > 0 { parts.append("has a likely name for \(lines(likely))") }
        let left = asked - sure - likely
        return "\(provider) " + parts.joined(separator: " and ") + (left > 0 ? ". \(left) it couldn't tell." : ".")
    }

    static func label(_ speaker: Speaker, me: String?) -> String {
        speaker == .me ? (me ?? speaker.label) : speaker.label
    }

    /// One remembered voiceprint in People: the recording it was named in and when that
    /// was, an imported one, or one filed before anyrec kept where prints came from.
    static func printOrigin(_ origin: VoiceLibrary.PrintOrigin?, number: Int, title: String? = nil) -> String {
        guard let origin else { return "Voiceprint \(number) · earlier" }
        guard let recording = origin.recording else {
            return "Imported \(origin.filed.formatted(date: .abbreviated, time: .omitted))"
        }
        guard let started = origin.recordingStarted else { return title ?? recording }
        let when = started.formatted(date: .abbreviated, time: .shortened)
        guard let title, !title.isEmpty else { return "Recording of \(when)" }
        return "\(title) · \(when)"
    }

    static let removePrintHelp =
        "Remove this voiceprint from this person. Use it when a voice was named wrongly and this person now matches someone else."

    /// A clip button's tooltip and spoken label.
    static func clip(_ clip: SpeakerClip) -> String { "Play \(Self.clock(clip.start))–\(Self.clock(clip.end))" }

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

    /// The notification when a call was recorded without asking: what is being kept, and
    /// when it stops.
    static func automaticRecordingStarted(_ app: CallApp, video: Bool) -> (title: String, body: String) {
        (video ? "Recording your \(app.name) call" : "Recording the audio of your \(app.name) call",
         "It stops when the call ends.")
    }

    static let automaticRecordingModes: [(AutomaticRecordingMode, String)] = [
        (.window, "Window"), (.audioOnly, "Audio only"),
    ]

    /// Under "Record Slack and Teams calls automatically".
    static var automaticRecordingFooter: String {
        let grace = Int(CallAutoRecording.endGrace)
        return "When a Slack or Teams call starts and AnyRec finds its call window, it starts recording "
            + "that window straight away, with a notification to stop it, and stops \(grace) seconds after "
            + "the call ends. Calls in other apps, and calls whose window can't be found, still get the offer. "
            + "AnyRec doesn't tell the other people in the call that they are being recorded."
    }

    static func reviewTitle(_ current: RecordingTranscript) -> String {
        reviewTitle(provider: current.reviewProvider, failed: !current.reviewFailures.isEmpty)
    }

    static func reviewTitle(provider: SummaryProvider?, failed: Bool) -> String {
        if let provider { return "Reviewed with \(provider.name)" }
        return failed ? "Original transcript kept" : "Transcript versions"
    }

    static func versions(_ sources: [TranscriptStore.SourceVersion]) -> String { versions(sources.count) }

    static func versions(_ count: Int) -> String {
        count == 1 ? "1 source transcript" : "\(count) source transcripts"
    }

    static func version(_ source: SharedSource) -> String {
        version(engine: source.engine, role: source.compared ? .compared : .selected, written: source.written)
    }

    /// A version's row in View Sources: the engine, when it was written, and its part.
    static func version(_ source: TranscriptStore.SourceVersion) -> String {
        version(engine: source.engine, role: source.role, written: source.written)
    }

    private static func version(engine: String, role: TranscriptStore.SourceVersion.Role, written: Date) -> String {
        let when = written.formatted(date: .abbreviated, time: .shortened)
        let part: String
        switch role {
        case .selected: part = "Current · timing reference"
        case .compared: part = "Compared"
        case .earlier: part = "Earlier version"
        }
        let name = TranscriptionEngine(rawValue: engine).map(engineName) ?? engine.capitalized
        return "\(name) · \(part) · \(when)"
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
