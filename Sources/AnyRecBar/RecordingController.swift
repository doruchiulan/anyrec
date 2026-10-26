import AppKit
import Foundation
import Observation
import AnyRecKit

/// Everything the menu bar shows, and the one recording it drives. Owned by the app
/// delegate rather than by a view: the panel closes the moment you click away, and a
/// recording has to outlive that.
@MainActor
@Observable
final class RecordingController {
    enum Phase: Equatable {
        case idle
        case starting
        case recording
        case stopping
        case finished
    }

    /// Opens on what the last launch left, and on Automatic the first time: someone who
    /// put a recorder in their menu bar wants the transcript too, and `auto` is the
    /// setting that never leaves the machine.
    var configuration: RecordingConfiguration = {
        var configuration = RecordingConfiguration()
        Preferences.loaded(into: &configuration)
        return configuration
    }() {
        didSet {
            Preferences.save(configuration)
            /// Choosing the on-device engine is asking for its model: the size was on
            /// the choice, and there is nothing else to press.
            if configuration.transcribe == .parakeet, oldValue.transcribe != .parakeet {
                installParakeet()
            }
        }
    }

    private(set) var phase = Phase.idle {
        didSet { if phase != .idle { reminder?.withdraw() } }
    }
    private(set) var readiness = Readiness(appleLanguages: [])
    private(set) var microphones: [AudioInputDevice] = []
    private(set) var saved: SavedRecording?
    let processing: RecordingJobs
    /// Preserved with the saved recording when capture ends.
    private(set) var note: String?
    private(set) var failure: String?
    private(set) var canSeeScreen = Permissions.screenRecordingGranted()

    private(set) var setupProgress: String?
    private(set) var setupTarget: SetupTarget?
    private(set) var setupFailure: String?
    private(set) var keyOutcome: OpenAIKey.StoreOutcome?

    /// Telling the far end apart: whether the models are here, how the download is
    /// going, and who the library knows. Held rather than read live so the window
    /// redraws when they change.
    private(set) var speakersReady = Readiness.speakersReady
    /// Held like `speakersReady`: a file check, re-read after a download.
    private(set) var ffmpegReady = FFmpegSetup.isReady
    /// Whether Screen Recording was on when the app started. Granted since, the grant
    /// only takes effect for a newly launched process, which the welcome window says.
    let screenGrantedAtLaunch = Permissions.screenRecordingGranted()
    /// What the last voices import or export did, for the sheet or list that did it.
    private(set) var voicesMessage: String?
    private(set) var speakerSetupProgress: String?
    private(set) var speakerSetupFailure: String?
    private(set) var knownVoices: [String] = []

    /// The call app holding the microphone right now, for the menu bar to show and
    /// the notification to name. Nil between calls.
    private(set) var callApp: CallApp?
    /// Stored rather than read through to the defaults, so the toggle that binds to
    /// it is observed like everything else here.
    var offerToRecord = Preferences.offerToRecord {
        didSet {
            Preferences.offerToRecord = offerToRecord
            if offerToRecord { offerCallReminder() } else { reminder?.withdraw() }
        }
    }

    /// Bumped by the ticker so the meters redraw; the levels themselves are read
    /// straight off the buffers on their way to disk.
    private(set) var tick = Date()

    /// Held as text rather than derived from `tick`, so the menu bar item redraws once
    /// a second instead of ten times.
    private(set) var clock = ""

    private(set) var session: RecordingSession?

    /// Summaries: whether one follows every transcript, who writes it, in what language.
    /// Stored here so the toggles bound to them are observed like everything else.
    var transcriptionOptions = Preferences.transcriptionOptions {
        didSet {
            Preferences.transcriptionOptions = transcriptionOptions
            if engine != .auto && !transcriptionOptions.enabledEngines.contains(engine) { engine = .auto }
        }
    }
    var summarizes = Preferences.summarize {
        didSet { Preferences.summarize = summarizes }
    }
    var summaryProvider = Preferences.summaryProvider {
        didSet { Preferences.summaryProvider = summaryProvider }
    }
    var summaryLanguage = Preferences.summaryLanguage {
        didSet { Preferences.summaryLanguage = summaryLanguage }
    }
    /// The Settings pop-up and switch both edit `configuration.transcribe`, which is one
    /// optional: nil is "don't transcribe". Remembering the engine across the switch is
    /// what lets turning it off and on again not forget Whisper.
    private var lastEngine = TranscriptionEngine.auto
    var engine: TranscriptionEngine {
        get { configuration.transcribe ?? lastEngine }
        set {
            lastEngine = newValue
            if configuration.transcribe != nil { configuration.transcribe = newValue }
        }
    }
    var transcribesOnStop: Bool {
        get { configuration.transcribe != nil }
        set {
            if let current = configuration.transcribe { lastEngine = current }
            configuration.transcribe = newValue ? lastEngine : nil
        }
    }
    /// Folders a summary is being written for right now, and the last thing that went
    /// wrong with one. Held here, not in the detail view: a summary outlives the window.
    private(set) var summarizing: Set<URL> = []
    private(set) var summaryFailures: [URL: String] = [:]
    private var summaryTasks: [URL: Task<Void, Never>] = [:]
    /// The people anyrec has been told the names of, for the library's People list.
    private(set) var people: [VoiceLibrary.Person] = []

    /// Everything under the output folder, newest first, for the library window and the
    /// panel's Recent rows. Read off the disk whenever it may have changed.
    private(set) var library: [LibraryEntry] = []
    /// What the library window has open. Set by the panel's "Open in AnyRec" too.
    var selection: URL?
    private var ticker: Task<Void, Never>?
    private var setup: Task<Void, Never>?
    private var askedForScreen = false
    private var askedForAccessibility = false
    private let picker = SystemPicker()
    private let calls = CallWatch()
    private var reminder: CallReminder?
    private var hotKey: HotKey?
    private var quitting = false
    private var libraryRead = UUID()
    var showsMenuBarExtra = Preferences.menuBarExtra {
        didSet { Preferences.menuBarExtra = showsMenuBarExtra }
    }
    /// Whether the library's player shows the transcript over the video.
    var showsCaptions = Preferences.captions {
        didSet { Preferences.captions = showsCaptions }
    }
    /// Whether ⌘⇧R starts a recording from anywhere.
    var shortcut = Preferences.shortcut {
        didSet {
            Preferences.shortcut = shortcut
            applyShortcut()
        }
    }

    var isSettingUp: Bool { setupTarget != nil }
    var acceptsProcessing: Bool { !quitting }
    var transcriptRequest: LibraryEntry?

    /// The panel picks a microphone through here rather than writing the configuration
    /// directly. Only a choice is worth remembering: the two places that *resolve* a
    /// device — launch, and reopening the panel — would otherwise persist a nil for one
    /// that is merely unplugged today, and forget it for good.
    var microphone: AudioInputDevice? {
        get { configuration.microphone }
        set {
            configuration.microphone = newValue
            Preferences.saveMicrophone(newValue)
        }
    }

    var isRecording: Bool { phase == .recording || phase == .stopping }
    var advisory: Advisory? { readiness.advisory(for: configuration) }

    private(set) var completedSetup = Preferences.welcomed
    var canStart: Bool { (phase == .idle || phase == .finished) && completedSetup && !quitting }

    init(processing: RecordingJobs? = nil, completedSetup: Bool? = nil) {
        self.processing = processing ?? RecordingJobs()
        if let completedSetup { self.completedSetup = completedSetup }
        self.processing.onCompletion = { [weak self] request, result in
            guard let self else { return }
            if case .written? = result.transcript { summaryFailures[request.directory] = nil }
            reloadPeople()
            await reloadLibrary()
            if case .written? = result.transcript, let provider = request.summaryProvider,
                let entry = library.first(where: { $0.directory == request.directory })
            {
                summarize(entry, using: provider, language: request.summaryLanguage)
            }
        }
    }

    func completeSetup() {
        Preferences.welcomed = true
        completedSetup = true
        offerCallReminder()
    }

    /// Both of these are slow — the first device enumeration cold-starts AVFoundation —
    /// so they are asked for once at launch rather than when the panel is opened.
    func prepare() async {
        async let probe = Readiness.probe()
        let inputs = await Task.detached { AudioDevices.inputs() }.value

        microphones = inputs
        configuration.microphone = Preferences.microphone(among: inputs)
        if !Preferences.microphoneIsOff {
            configuration.pinDefaultMicrophone(from: inputs)
        }
        readiness = await probe
        reloadPeople()
        await reloadLibrary()
        await refreshProviders()
        applyShortcut()
        watchForCalls()
    }

    private func applyShortcut() {
        hotKey?.unregister()
        hotKey = shortcut ? HotKey { [weak self] in self?.pickAndStart() } : nil
    }

    func reloadPeople() {
        let library = VoiceLibrary.load()
        people = library.people
        knownVoices = library.names
    }

    func forget(_ name: String) {
        var library = VoiceLibrary.load()
        library.forget(name)
        try? library.save()
        reloadPeople()
    }

    /// What each summary provider can do on this machine. Finding one is a search of
    /// every directory on `PATH`, and views asked for it on every redraw, so it is read
    /// here — at launch, when the panel or Settings opens, after a key is saved — and
    /// held, like `readiness`.
    struct ProviderState: Equatable {
        let available: Bool
        let detail: String
    }

    private(set) var providers: [SummaryProvider: ProviderState] = [:]

    func refreshProviders() async {
        let found = await Task.detached {
            Dictionary(uniqueKeysWithValues: SummaryProvider.allCases.map {
                ($0, ProviderState(available: $0.isAvailable, detail: $0.detail))
            })
        }.value
        if found != providers { providers = found }
    }

    func canSummarize(with provider: SummaryProvider) -> Bool {
        providers[provider]?.available ?? false
    }

    /// The provider that will be used: the one chosen if it can run, else the first that can.
    var activeSummaryProvider: SummaryProvider? {
        if let chosen = summaryProvider, canSummarize(with: chosen) { return chosen }
        return SummaryProvider.allCases.first(where: canSummarize)
    }

    /// Writes the summary for a recording that has a transcript. Safe to call twice: a
    /// second call while one runs does nothing.
    func summarize(_ entry: LibraryEntry) {
        guard let provider = activeSummaryProvider else { return }
        summarize(entry, using: provider, language: summaryLanguage)
    }

    private func summarize(_ entry: LibraryEntry, using provider: SummaryProvider, language: String?) {
        let folder = entry.directory
        guard !summarizing.contains(folder), !processing.working.contains(folder),
            let url = entry.transcript else { return }
        summarizing.insert(folder)
        summaryFailures[folder] = nil
        summaryTasks[folder] = Task {
            do {
                if let transcript = Transcript.read(url) {
                    let names = RecordingVoices.read(in: folder)?.names ?? [:]
                    let summary = try await Summarizer.summary(
                        of: transcript.named(names), using: provider, language: language)
                    let destination = TranscriptStore.summaryDestination(for: url)
                    try summary.write(to: destination)
                    try TranscriptStore.selectSummary(destination, for: url)
                } else { summaryFailures[folder] = "The transcript could not be read." }
            } catch {
                summaryFailures[folder] = "\(error)"
            }
            summarizing.remove(folder)
            summaryTasks[folder] = nil
            await reloadLibrary()
        }
    }

    /// Transcribing, or summarising, right now: what the library's In progress lists.
    var working: Set<URL> {
        summarizing.union(processing.working)
    }

    func processingMessage(for directory: URL) -> String? {
        if summarizing.contains(directory) { return "Writing summary…" }
        if let item = processing.items[directory] {
            if item.isWorking { return item.message }
            if let issue = item.result?.issue { return issue }
        }
        if TranscriptStore.noSpeechDetected(in: directory) { return "No speech detected." }
        return summaryFailures[directory]
    }

    /// The recording the library has open, for the menu bar's commands.
    var selectedEntry: LibraryEntry? {
        library.first { $0.directory == selection }
    }

    /// To the Trash rather than deleted, so Finder's Put Back is the undo.
    func trash(_ entry: LibraryEntry) {
        guard !working.contains(entry.directory) else { return }
        do {
            try FileManager.default.trashItem(at: entry.directory, resultingItemURL: nil)
            if selection == entry.directory { selection = nil }
        } catch {
            failure = "It could not be moved to the Trash: \(error.localizedDescription)"
        }
        Task { await reloadLibrary() }
    }

    func reveal(_ entry: LibraryEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.video ?? entry.directory])
    }

    /// Free space on the volume the recordings are on, read with the library.
    private(set) var freeSpace: Int64 = 0

    /// Read off the disk on every panel open, so it is only assigned when something on
    /// disk changed: every assignment redraws the library window, and its search index
    /// is rebuilt from the transcripts each time `library` changes.
    func reloadLibrary() async {
        let read = UUID()
        libraryRead = read
        let root = URL(fileURLWithPath: configuration.outputRoot.expandingTilde)
        let (entries, free) = await Task.detached {
            (RecordingLibrary.entries(in: root), Wording.freeSpace(for: root.path))
        }.value
        guard libraryRead == read else { return }
        let finished = entries.filter { $0.directory != session?.plan.directory }
        if finished != library { library = finished }
        if free != freeSpace { freeSpace = free }
    }

    /// A call app taking the microphone while nothing is being recorded is worth one
    /// offer. The watch runs for the life of the app; what it finds mid-recording only
    /// keeps the icon honest.
    private func watchForCalls() {
        reminder = CallReminder(onRecord: { [weak self] choice in self?.recordCallWindow(choice) },
                                onChooseWindow: { [weak self] in self?.pickAndStart() })
        calls.start { [weak self] event in
            Task { @MainActor in self?.callChanged(event) }
        }
    }

    private func callChanged(_ event: CallWatch.Event) {
        switch event {
        case .started(let app):
            callApp = app
            offerCallReminder()
        case .ended:
            callApp = nil
            reminder?.withdraw()
        }
    }

    private func offerCallReminder() {
        guard canStart, offerToRecord, let callApp else { return }
        reminder?.offer(callApp)
    }

    /// Input devices come and go while the panel is shut — this app runs for days and
    /// the AirPods go in halfway through one — so the list is asked for again every
    /// time it is shown.
    ///
    /// The selection is re-read from that list rather than merely checked against it:
    /// a device whose `isDefault` has moved is the same device, but it is not the same
    /// *value*, and a menu matching on the whole value would draw itself empty. A
    /// device that has gone falls out to nil, which is Off.
    ///
    /// `pinDefaultMicrophone` is deliberately not re-run here: once someone has used
    /// the menu, nil means Off, and re-pinning would quietly undo them.
    func refresh() async {
        guard phase == .idle || phase == .finished else { return }
        await reloadLibrary()
        await refreshProviders()

        /// Before the Screen Recording gate: listing inputs needs no grant, so a denied
        /// screen must not hide the microphones too.
        microphones = await Task.detached { AudioDevices.inputs() }.value
        if let chosen = configuration.microphone {
            configuration.microphone = microphones.first { $0.id == chosen.id }
        }

        canSeeScreen = Permissions.screenRecordingGranted()
        /// Asked once a launch, after the screen is granted so a fresh install meets
        /// one dialog at a time. Only asking lists the app under Accessibility; the
        /// advisory then says what is missing until it is switched on.
        if canSeeScreen, !askedForAccessibility {
            askedForAccessibility = true
            Permissions.requestAccessibility()
        }
    }

    /// Setting an engine up outlives the window it was started from — a settings window
    /// closes the moment you click away from it, and `brew install` does not — so the
    /// task belongs here, with everything else the app delegate owns.
    func installWhisper() { install(WhisperSetup.pending(), for: .whisper) }
    func installParakeet() { install(ParakeetSetup.pending(), for: .parakeet) }
    func installFFmpeg() { install(FFmpegSetup.isReady ? [] : [.fetchFFmpeg], for: .ffmpeg) }

    private func install(_ steps: [WhisperSetup.Step], for target: SetupTarget) {
        guard setup == nil, !steps.isEmpty else { return }
        setupFailure = nil
        setupTarget = target

        setup = Task {
            for step in steps {
                setupProgress = step.title
                do {
                    try await WhisperSetup.perform(step) { line in
                        Task { @MainActor in
                            guard self.setupTarget == target else { return }
                            self.setupProgress = "\(step.title) — \(line)"
                        }
                    }
                } catch {
                    setupFailure = "\(error)"
                    break
                }
            }
            /// An engine can be set up from here mid-session, so what the panel says
            /// about the engines has to be asked again rather than left at launch.
            readiness = await Readiness.probe()
            ffmpegReady = FFmpegSetup.isReady
            setupProgress = nil
            setupTarget = nil
            setup = nil
        }
    }

    /// The speaker models, same ownership as whisper's install: the download outlives
    /// the window it was started from.
    func installSpeakers() {
        guard speakerSetupProgress == nil, !speakersReady else { return }
        speakerSetupFailure = nil
        speakerSetupProgress = "Downloading…"
        Task {
            do {
                try await SpeakerSetup.fetch { line in
                    Task { @MainActor in self.speakerSetupProgress = "Downloading — \(line)" }
                }
            } catch {
                speakerSetupFailure = "\(error)"
            }
            speakersReady = Readiness.speakersReady
            speakerSetupProgress = nil
        }
    }

    func importVoicesPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [VoiceLibrary.contentType]
        panel.message = "Choose a voices file a colleague exported from AnyRec."
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            voicesMessage = importVoices(from: url)
        }
    }

    func exportVoicesPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [VoiceLibrary.contentType]
        panel.nameFieldStringValue = "AnyRec Voices.\(VoiceLibrary.fileExtension)"
        panel.message = "Everyone the library knows, as one file to share. No audio is in it."
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try VoiceLibrary.load().exported().write(to: url, options: .atomic)
                self?.voicesMessage = "Exported \(Wording.people(VoiceLibrary.load().people.count))."
            } catch {
                self?.voicesMessage = "The voices could not be exported: \(error.localizedDescription)"
            }
        }
    }

    /// A colleague's voices, into the library. Returns the sentence for it.
    func importVoices(from url: URL) -> String {
        do {
            var library = VoiceLibrary.load()
            let added = try library.merge(try Data(contentsOf: url))
            try library.save()
            reloadPeople()
            return Wording.imported(people: added.people, prints: added.prints)
        } catch {
            return "The voices could not be imported: \(error.localizedDescription)"
        }
    }

    /// The key is handed straight to the Kit, which checks it against the API before
    /// writing it and never gives it back. Nothing here keeps a copy.
    func saveOpenAIKey(_ key: String) async {
        keyOutcome = nil
        let outcome = await OpenAIKey.validateAndStore(key)
        readiness = await Readiness.probe()
        await refreshProviders()
        keyOutcome = outcome
    }

    /// Asked once a launch, the first time the panel has to say the screen is off. Only
    /// asking registers the app with TCC, and until it has there is no AnyRec row in
    /// Privacy & Security to switch on — which left the panel pointing at a list the app
    /// was not in, and the only way through it the `+` button.
    func requestScreenRecording() async {
        guard !canSeeScreen, !askedForScreen else { return }
        askedForScreen = true
        canSeeScreen = await Permissions.requestScreenRecording()
    }

    /// Pointing at a window *is* starting the recording. Picking on its own row meant
    /// two decisions to reach one recording, and left a pick to go stale between them;
    /// this way what is recorded is whatever was pointed at a moment ago. Closing the
    /// picker without choosing records nothing, which is what closing it means.
    func pickAndStart() {
        guard canStart else { return }
        picker.present { [weak self] choice in
            guard let self, let choice else { return }
            configuration.capture = choice
            Task { await self.start() }
        }
    }

    func recordCallWindow(_ choice: CaptureChoice?) {
        guard canStart else { return }
        guard let choice else {
            configuration.capture = nil
            saved = nil
            phase = .idle
            failure = "That call window is no longer available. Try again from the call window."
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }
        configuration.capture = choice
        Task { await start() }
    }

    func start() async {
        guard canStart, configuration.capture != nil else { return }
        phase = .starting
        failure = nil
        saved = nil
        note = nil
        clock = Wording.clock(0)

        if configuration.microphone != nil, await !Permissions.requestMicrophone() {
            configuration.microphone = nil
            note = "Microphone access was denied, so this was recorded without it."
        }

        do {
            session = try await RecordingSession.start(configuration)
            phase = .recording
            startTicking()
        } catch {
            failure = "\(error)"
            phase = .idle
        }
    }

    func stop() async {
        guard let session, phase == .recording else { return }
        phase = .stopping
        stopTicking()

        do {
            let capture = try await session.finishCapture()
            recordingSaved(SavedRecording(capture: capture, title: session.target.describing,
                                          duration: session.elapsed, note: note),
                           configuration: session.configuration)
            await reloadLibrary()
        } catch {
            failure = "\(error)"
            self.session = nil
            phase = .finished
        }
    }

    func recordingSaved(_ recording: SavedRecording, configuration: RecordingConfiguration) {
        saved = recording
        session = nil
        phase = .finished
        processing.enqueue(RecordingJobs.Request(
            capture: recording.capture, merge: configuration.mux, engine: configuration.transcribe, options: transcriptionOptions,
            summaryProvider: summarizes ? activeSummaryProvider : nil, summaryLanguage: summaryLanguage))
    }

    /// Back to the setup panel, keeping the settings that produced the last recording.
    func dismiss() {
        guard phase == .finished else { return }
        saved = nil
        failure = nil
        note = nil
        phase = .idle
        offerCallReminder()
    }

    /// A quit mid-recording would leave three files with no moov atom, which nothing
    /// can open. Terminating waits for the writers to finalise, exactly as the
    /// terminal's signal handling does.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitting { return .terminateLater }
        guard isRecording || phase == .starting || !working.isEmpty else { return .terminateNow }
        quitting = true
        Task {
            /// Quitting while the stream is still coming up would reply before there
            /// is anything to stop, and the recording would start into a dying app.
            while phase == .starting || phase == .stopping {
                try? await Task.sleep(for: .milliseconds(50))
            }
            await stop()
            await processing.waitUntilIdle()
            for task in summaryTasks.values { await task.value }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func startTicking() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let session else { return }
                tick = Date()
                if clock != Wording.clock(session.elapsed) {
                    clock = Wording.clock(session.elapsed)
                }
                if session.captureEnded || session.reachedDeadline { await stop() }
            }
        }
    }

    private func stopTicking() {
        ticker?.cancel()
        ticker = nil
    }
}
