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
        didSet {
            if phase != .idle { reminder?.withdraw() }
            /// However the recording ended — Stop, the window closing, the stop time — or
            /// a start that failed: an automatic recording is over, and so is its notice.
            if phase == .finished || (oldValue == .starting && phase == .idle) {
                autoRecording.recordingEnded()
                automaticStop?.cancel()
                reminder?.withdrawAnnouncement()
            }
        }
    }
    private(set) var readiness = Readiness(appleLanguages: [])
    private(set) var microphones: [AudioInputDevice] = []
    private(set) var saved: SavedRecording?
    let processing: RecordingJobs
    /// Preserved with the saved recording when capture ends.
    private(set) var note: String?
    private(set) var failure: String?
    /// What the last change of recordings folder did, or why it was refused. Shown in
    /// Settings › Recording › Storage.
    var storageNotice: String?
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
    /// The app's updater, set once by the app delegate, which owns it. Read by the panel for
    /// an update held back during a call, and by the menu and Settings.
    @ObservationIgnored var updates: Updates?
    /// The detected call's windows, ready to record without the picker. Followed while a
    /// call is on and nothing is recording.
    private(set) var ongoingCalls: [OngoingCall] = []
    @ObservationIgnored private let callFinder = OngoingCallFinder()
    @ObservationIgnored private var callSearch: Task<Void, Never>?
    /// Stored rather than read through to the defaults, so the toggle that binds to
    /// it is observed like everything else here.
    /// Settings › Recording: saved recordings' video compressed in the background.
    var compressesRecordings = Preferences.compressesRecordings {
        didSet {
            Preferences.compressesRecordings = compressesRecordings
            if !compressesRecordings { compressor.stop() }
        }
    }
    /// Owned here, like the jobs, so it outlives every window.
    @ObservationIgnored private(set) lazy var compressor = Compressor(controller: self)

    var offerToRecord = Preferences.offerToRecord {
        didSet {
            Preferences.offerToRecord = offerToRecord
            if offerToRecord { offerCallReminder() } else { reminder?.withdraw() }
        }
    }
    /// Settings › General: Slack and Teams calls recorded without asking, once their
    /// window is found. Turned off while a window is being looked for, the call is offered
    /// instead; a recording already running still stops at the call's end.
    var recordsCallsAutomatically = Preferences.recordsCallsAutomatically {
        didSet {
            Preferences.recordsCallsAutomatically = recordsCallsAutomatically
            if !recordsCallsAutomatically, autoRecording.disabled() != nil {
                reminder?.withdraw()
                offerCallReminder()
            }
        }
    }
    var automaticRecordingMode = Preferences.automaticRecordingMode {
        didSet { Preferences.automaticRecordingMode = automaticRecordingMode }
    }
    @ObservationIgnored private var autoRecording = CallAutoRecording()
    @ObservationIgnored private var automaticStop: Task<Void, Never>?

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
    let team = TeamLibrary()
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
    var isQuitting: Bool { quitting }
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
    /// Set by Recording › Show Speakers: the open recording's page scrolls its Speakers
    /// panel into view and clears it.
    var speakersRequest: URL?
    /// Opens the library window. SwiftUI only hands out `openWindow` to views and commands,
    /// and with the window not opened at launch none of its views exist yet, so the menu
    /// bar's commands — built at launch — leave it here for the Dock icon's reopen.
    @ObservationIgnored var openLibrary: (() -> Void)?
    /// Opens Settings, left here by the same commands for the same reason: the menu bar
    /// panel is an AppKit window outside any scene.
    @ObservationIgnored var openSettings: (() -> Void)?
    /// Closes the menu bar panel before macOS's picker comes up over the screen.
    @ObservationIgnored var willPresentPicker: (() -> Void)?

    /// The panel picks a microphone through here rather than writing the configuration
    /// directly. Only a choice is worth remembering: the two places that *resolve* a
    /// device — launch, and reopening the panel — would otherwise persist a nil for one
    /// that is merely unplugged today, and forget it for good.
    var microphone: AudioInputDevice? {
        get { configuration.microphone }
        set {
            configuration.microphone = newValue
            /// Picked by hand, so kept for the whole recording rather than following the default.
            configuration.followsDefaultMicrophone = false
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
            if case .written(_, _, _, let summary)? = result.transcript {
                /// A summary that failed is the Summary card's to retry, not the job's:
                /// retrying the job would transcribe again.
                if case .failed(let reason) = summary { summaryFailures[request.directory] = Wording.summaryFailure(reason) }
                else { summaryFailures[request.directory] = nil }
            }
            reloadPeople()
            await reloadLibrary()
        }
    }

    func completeSetup() {
        Preferences.welcomed = true
        completedSetup = true
        chooseSetupDefaultEngine()
        offerCallReminder()
    }

    /// Both of these are slow — the first device enumeration cold-starts AVFoundation —
    /// so they are asked for once at launch rather than when the panel is opened.
    func prepare() async {
        team.start()
        async let probe = Readiness.probe()
        let inputs = await Task.detached { AudioDevices.inputs() }.value

        microphones = inputs
        configuration.microphone = Preferences.microphone(among: inputs)
        if !Preferences.microphoneIsOff {
            configuration.pinDefaultMicrophone(from: inputs)
        }
        readiness = await probe
        reloadPeople()
        await migrateRecordings()
        await reloadLibrary()
        await refreshProviders()
        applyShortcut()
        watchForCalls()
        compressor.start()
    }

    private func applyShortcut() {
        hotKey?.unregister()
        hotKey = shortcut ? HotKey { [weak self] in self?.pickAndStart() } : nil
    }

    func reloadPeople() {
        let library = VoiceLibrary.load()
        people = library.people
        knownVoices = library.names
        libraryIssues = library.issues
    }

    /// What the library found worth one plain question: two records of one person, prints
    /// unlike the rest of their person's.
    private(set) var libraryIssues: [VoiceLibrary.Issue] = []

    /// One person under two records: the one with more prints keeps its name (the longer
    /// name when even), the other becomes a nickname.
    func mergePeople(_ a: String, _ b: String) {
        var library = VoiceLibrary.load()
        let count = { (name: String) in library.people.first { $0.name == name }?.prints.count ?? 0 }
        let (main, duplicate) = (count(a), a.count) >= (count(b), b.count) ? (a, b) : (b, a)
        library.mergePerson(duplicate, into: main)
        try? library.save()
        reloadPeople()
    }

    /// A voiceprint the library set aside to keep the person to a few good ones, back in use.
    func bringBack(retired index: Int, of name: String) {
        var library = VoiceLibrary.load()
        library.bringBack(retired: index, of: name)
        try? library.save()
        reloadPeople()
    }

    func markDifferent(_ a: String, _ b: String) {
        var library = VoiceLibrary.load()
        library.markDifferent(a, b)
        try? library.save()
        reloadPeople()
    }

    /// Who is recording: their voice heard on the far end goes back to "Me".
    func setOwner(_ name: String?) {
        var library = VoiceLibrary.load()
        library.setOwner(name)
        try? library.save()
        reloadPeople()
    }

    func forget(_ name: String) {
        var library = VoiceLibrary.load()
        library.forget(name)
        try? library.save()
        reloadPeople()
    }

    /// One voiceprint the owner says is wrong, out of one person; the person stays.
    func removePrint(at index: Int, from name: String) {
        var library = VoiceLibrary.load()
        library.removePrint(at: index, from: name)
        try? library.save()
        reloadPeople()
    }

    /// The title of the recording a voiceprint was named in, when it is still in the library.
    func recordingTitle(folder: String?) -> String? {
        guard let folder else { return nil }
        return library.first { $0.directory.lastPathComponent == folder || $0.recordingID == folder }?.info?.title
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

    /// The same step the Kit's pass runs after a transcript, started from the Summary
    /// card or a menu: written for the transcript as it reads now.
    private func summarize(_ entry: LibraryEntry, using provider: SummaryProvider, language: String?) {
        let folder = entry.directory
        guard !summarizing.contains(folder), !processing.working.contains(folder), entry.transcript != nil else { return }
        summarizing.insert(folder)
        summaryFailures[folder] = nil
        summaryTasks[folder] = Task {
            do {
                _ = try await SummaryPass.write(in: folder, request: SummaryRequest(provider: provider, language: language))
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

    /// The recordings folder in use.
    var recordingsFolder: URL { URL(fileURLWithPath: configuration.outputRoot.expandingTilde) }

    /// Folders something is recording or processing, which a migration leaves alone.
    private func busyFolders() -> Set<URL> {
        var busy = Set(working.map { RecordingLayout(directory: $0).directory })
        if let directory = session?.plan.directory { busy.insert(directory) }
        return busy
    }

    /// Once a launch, before the library is first read: recordings kept on the Desktop move
    /// into the app's folder (when the default folder is in use) and every folder is brought
    /// into the current layout. Off the main thread; nothing busy is touched.
    func migrateRecordings() async {
        let root = recordingsFolder
        let isDefault = configuration.outputRoot == Defaults.outputRoot
        let busy = busyFolders()
        _ = await Task.detached {
            RecordingMigration.run(root: root, movesLegacyRoot: isDefault) {
                busy.contains(RecordingLayout(directory: $0).directory)
            }
        }.value
    }

    /// Settings › Recording › Storage › Change…: points the library at `folder` and moves
    /// the recordings there. Refused, with the reason in `storageNotice`, while anything is
    /// recording or being processed, or when the folder cannot be used.
    func changeRecordingsFolder(to folder: URL) async {
        guard phase == .idle, session == nil, working.isEmpty else {
            storageNotice = "Finish the current recording and its processing before moving recordings."
            return
        }
        let old = recordingsFolder
        do { try RecordingMigration.validateMove(from: old, to: folder) } catch {
            storageNotice = error.localizedDescription
            return
        }
        let report = await Task.detached {
            let moved = RecordingMigration.moveRoot(from: old, to: folder)
            _ = RecordingMigration.migrateAll(in: folder)
            return moved
        }.value
        await team.relocate(report.moved)
        configuration.outputRoot = folder.path
        storageNotice = report.failures.isEmpty
            ? "Moved \(Wording.count(report.moved.count)) to \(folder.path)."
            : "Moved \(Wording.count(report.moved.count)); \(report.failures.count) could not be moved: \(report.failures.joined(separator: "; "))"
        selection = nil
        await reloadLibrary()
    }

    /// To the Trash rather than deleted, so Finder's Put Back is the undo.
    func trash(_ entry: LibraryEntry) {
        guard !working.contains(entry.directory) else { return }
        if team.publication(entry) != nil {
            let alert = NSAlert()
            alert.messageText = "Remove the shared meeting and move your original to Trash?"
            alert.informativeText = "Linked entries will disappear. Independent copies will stay."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Remove and Move to Trash")
            if alert.runModal() == .alertSecondButtonReturn {
                team.remove(entry) { self.trashLocal(entry) }
            }
            return
        }
        trashLocal(entry)
    }

    private func trashLocal(_ entry: LibraryEntry) {
        compressor.stop(entry.directory)
        do {
            try FileManager.default.trashItem(at: entry.directory, resultingItemURL: nil)
            if selection == entry.directory { selection = nil }
        } catch {
            failure = "It could not be moved to the Trash: \(error.localizedDescription)"
        }
        Task { await reloadLibrary() }
    }

    /// Set to a recording's folder to have its page's Share button open the share menu:
    /// how File › Share… and the list's Share… reach the one button that has a view to
    /// hang the menu from.
    var shareRequest: URL?

    func share(_ entry: LibraryEntry) {
        selection = entry.directory
        shareRequest = entry.directory
    }

    /// Sharing is started from the library window, where the panel's failure notice is
    /// not on screen, so it says so in an alert on that window.
    func shareFailed(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't share this recording"
        alert.informativeText = message
        if let window = NSApplication.shared.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    func reveal(_ entry: LibraryEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.media ?? entry.directory])
    }

    /// Free space on the volume the recordings are on, read with the library.
    private(set) var freeSpace: Int64 = 0

    /// Read off the disk on every panel open, so it is only assigned when something on
    /// disk changed: every assignment redraws the library window, and its search index
    /// is rebuilt from the transcripts each time `library` changes.
    func reloadLibrary() async {
        let read = UUID()
        libraryRead = read
        let root = recordingsFolder
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
        reminder = CallReminder(onRecord: { [weak self] choice, video in self?.recordCallWindow(choice, video: video) },
                                onChooseWindow: { [weak self] video in self?.pickAndStart(video: video) },
                                onFound: { [weak self] choice in self?.recordCallAutomatically(choice) },
                                onStop: { [weak self] in Task { await self?.stop() } })
        calls.start { [weak self] event in
            Task { @MainActor in self?.callChanged(event) }
        }
    }

    private func callChanged(_ event: CallWatch.Event) {
        switch event {
        case .started(let app):
            callApp = app
            followOngoingCall()
            switch autoRecording.callStarted(app, context: autoContext) {
            case .watch(let app): reminder?.watch(app, notifies: offerToRecord)
            case .offer: offerCallReminder()
            case .resume: automaticStop?.cancel()
            case .ignore: break
            }
        case .ended:
            callApp = nil
            followOngoingCall()
            reminder?.withdraw()
            if case .stopAt(let deadline) = autoRecording.callEnded(at: Date()) { stopAutomatically(at: deadline) }
        }
    }

    private var autoContext: CallAutoRecording.Context {
        CallAutoRecording.Context(
            enabled: recordsCallsAutomatically, mode: automaticRecordingMode,
            canStart: canStart && (automaticRecordingMode.video || audioOnlyRecordsAnything))
    }

    /// The watched call's window, found and checked: started the way the banner's buttons
    /// start it, in the mode Settings chose, and said so in a notification with Stop.
    private func recordCallAutomatically(_ choice: CaptureChoice) {
        guard let app = callApp, let video = autoRecording.windowFound(context: autoContext) else { return }
        configuration.capture = choice
        Task {
            await start(video: video)
            if phase == .recording, autoRecording.recording == app { reminder?.announce(app, video: video) }
        }
    }

    /// The call let go of the microphone. Its automatic recording stops once the grace has
    /// passed without the call taking it back; a recording still coming up is waited for.
    private func stopAutomatically(at deadline: Date) {
        automaticStop?.cancel()
        automaticStop = Task { [weak self] in
            /// A quarter second past it, so the sleep's clock and the wall clock agree it passed.
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow) + 0.25))
            guard !Task.isCancelled, let self else { return }
            while phase == .starting { try? await Task.sleep(for: .milliseconds(50)) }
            guard !Task.isCancelled, autoRecording.deadlinePassed(at: Date()) else { return }
            await stop()
        }
    }

    /// The call's window, looked for every two seconds for as long as the call lasts: it
    /// often opens after the app has taken the microphone, and it can move to another Space
    /// or close. Nothing is looked for while recording.
    private func followOngoingCall() {
        callSearch?.cancel()
        guard let app = callApp else {
            callSearch = nil
            if !ongoingCalls.isEmpty { ongoingCalls = [] }
            return
        }
        callSearch = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let found = canStart ? await callFinder.calls(for: app) : []
                guard !Task.isCancelled else { return }
                if found != ongoingCalls { ongoingCalls = found }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Records a listed call window straight away: it was found and matched moments ago,
    /// so there is nothing to pick. A window that has closed since fails to start and says so.
    func record(_ call: OngoingCall, video: Bool) {
        guard canStart, video || audioOnlyRecordsAnything else { return }
        configuration.capture = call.choice
        Task { await start(video: video) }
    }

    /// Not while the call's window is being looked for to record it automatically: Done,
    /// or the offer switch, would otherwise swap that search for the banner.
    private func offerCallReminder() {
        guard canStart, offerToRecord, let callApp, autoRecording.watching == nil else { return }
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
    /// `pinDefaultMicrophone` is re-run only for a microphone nobody picked: once someone
    /// has used the menu, nil means Off, and re-pinning would quietly undo them.
    func refresh() async {
        guard phase == .idle || phase == .finished else { return }
        await reloadLibrary()
        await refreshProviders()

        /// Before the Screen Recording gate: listing inputs needs no grant, so a denied
        /// screen must not hide the microphones too.
        microphones = await Task.detached { AudioDevices.inputs() }.value
        if configuration.followsDefaultMicrophone {
            /// Never picked: it is whatever the default is now, which the AirPods going in
            /// since launch may have moved.
            configuration.microphone = nil
            configuration.pinDefaultMicrophone(from: microphones)
        } else if let chosen = configuration.microphone {
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
        /// A download started in the welcome window picks the default engine when it
        /// finishes, even if Start Using AnyRec was pressed before then.
        let onboarding = !completedSetup

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
            /// Downloading an engine is asking to use it, so it is switched on.
            if let engine = target.engine, readiness.of(engine).isReady {
                transcriptionOptions.enabledEngines.insert(engine)
                if onboarding { chooseSetupDefaultEngine() }
            }
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
        panel.allowedContentTypes = VoiceLibrary.importTypes
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
    ///
    /// `video` is which of the two Record commands was pressed. Audio only still picks a
    /// window: its filter carries the sound, and its title, participants and mute button
    /// are read as usual. Only the picture is not kept.
    ///
    /// Picked from one of AnyRec's own windows, AnyRec steps aside while the picker is up.
    /// The picker leaves AnyRec's windows out, and so it dimmed the library and pulled
    /// forward whatever window was behind it (a utility's settings, in the report). AnyRec
    /// comes back if the picker is closed, and stays hidden once a recording starts, so the
    /// call stays in view.
    func pickAndStart(video: Bool = true) {
        guard canStart, video || audioOnlyRecordsAnything else { return }
        willPresentPicker?()
        let app = NSApplication.shared
        let stepAside = app.isActive && app.windows.contains { $0.isVisible && $0.canBecomeMain }
        if stepAside { app.hide(nil) }
        picker.present { [weak self] choice in
            guard let self else { return }
            guard let choice else {
                if stepAside {
                    app.unhide(nil)
                    app.activate(ignoringOtherApps: true)
                }
                return
            }
            configuration.capture = choice
            Task { await self.start(video: video) }
        }
    }

    /// Audio only with both audio tracks switched off in Settings would record nothing,
    /// so the command is dimmed rather than offered.
    var audioOnlyRecordsAnything: Bool { configuration.systemAudio || configuration.microphone != nil }

    var canStartAudioOnly: Bool { canStart && audioOnlyRecordsAnything }

    func recordCallWindow(_ choice: CaptureChoice?, video: Bool = true) {
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
        Task { await start(video: video) }
    }

    /// The one start path. Both Record commands, the banner, the notification and the
    /// shortcut end here, and only `video` differs between them.
    private func start(video: Bool) async {
        guard canStart, configuration.capture != nil else { return }
        configuration.video = video
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
            summary: summaryRequest))
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
        /// Stopped, never waited for: a compression can take twenty minutes, and the next
        /// launch picks it up again.
        compressor.stop()
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
