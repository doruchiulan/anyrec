import AVFoundation
import AVKit
import AnyRecKit
import Observation

/// One recording being played. Plays the merged file as it is until a track is switched
/// off; then it plays the masters — the picture, call audio, microphone — as one
/// composition with that track silenced, picking up where it was. The picture comes from
/// `screen.mov` while it exists and from the merged file once that has replaced it; only
/// its video stream is used, never the mix beside it. Nothing is rewritten. An audio-only
/// recording plays the same way without a picture; with no merged file yet, it starts on
/// the composition of its two tracks.
///
/// Someone else's recording, read from a team folder, plays the same way from files that may
/// not be on this Mac yet. Pressing play (or a line, a clip, a seek) fetches the recording
/// and then does it; switching a track off fetches the tracks. No file is opened before it
/// has arrived.
@MainActor
@Observable
final class Playback {
    enum Track: CaseIterable { case callAudio, microphone, video }

    let entry: LibraryEntry
    let player = AVPlayer()
    private(set) var isPlaying = false
    private(set) var position: TimeInterval = 0
    private(set) var peaks: [Float] = []
    private(set) var enabled: Set<Track> = Set(Track.allCases)
    /// The transcript line being played, held apart from `position` so that only the two
    /// rows it moves between redraw — `position` changes ten times a second, and a view
    /// reading it re-runs on every one.
    private(set) var currentLine: Int?
    /// The speaker clip being played, which stops at its end. Changes once per clip, so the
    /// clip buttons can read it; nil once it ends or anything else moves the player.
    private(set) var playingClip: SpeakerClip?
    /// The tracks this recording actually has, so a chip is not offered for a file that
    /// was never written. Read from disk once, not on every redraw.
    let available: [Track]
    var rate: Float = 1 {
        didSet { if isPlaying { player.rate = rate } }
    }
    let duration: TimeInterval

    private var observer: Any?
    private var finish: NSObjectProtocol?
    /// The player's own controls can pause it, so whether it is playing is read from the
    /// player rather than kept beside it.
    private var status: NSKeyValueObservation?
    /// Where each transcript line starts and ends, for `currentLine`.
    private var lines: [(start: TimeInterval, end: TimeInterval)] = []
    /// Fetches a shared recording's files. Nil for a recording of this Mac's own.
    let download: SharedDownload?
    /// The recording itself is here and in the player. Always true for a recording of this
    /// Mac's own.
    private(set) var isReady = true
    /// The boundary observer that pauses the player at a clip's end.
    private var clipEnd: Any?

    init(_ entry: LibraryEntry) {
        self.entry = entry
        duration = entry.duration
        download = entry.shared == nil ? nil : SharedDownload()
        let files = Self.files(of: entry)
        /// A shared track is offered from the manifest, whether or not it is here.
        let exists = { (url: URL?) in url.map { entry.shared != nil || FileManager.default.fileExists(atPath: $0.path) } ?? false }
        available = Track.allCases.filter {
            switch $0 {
            /// A shared call whose microphone stayed with its owner: the call's track alone
            /// would be the meeting without them, so it is not offered as a switch.
            case .callAudio: exists(files.callAudio) && (entry.shared == nil || files.microphone != nil)
            case .microphone: exists(files.microphone)
            case .video: entry.video != nil
            }
        }
        if let shared = entry.shared {
            isReady = SharedDownload.isLocal([shared.media])
            if isReady { player.replaceCurrentItem(with: AVPlayerItem(url: shared.media)) }
        } else if let media = entry.media {
            player.replaceCurrentItem(with: AVPlayerItem(url: media))
        } else if available.contains(where: { $0 != .video }) {
            Task { await rebuild() }
        }
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.moved(to: time.seconds) }
        }
        status = player.observe(\.timeControlStatus) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if self?.isPlaying != playing { self?.isPlaying = playing }
                }
            }
        }
        finish = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.endClip()
                self?.isPlaying = false
            }
        }
    }

    /// Where a recording's separate tracks are, its own or a shared one's.
    static func files(of entry: LibraryEntry) -> (video: URL?, callAudio: URL?, microphone: URL?) {
        if let shared = entry.shared { return (entry.audioOnly ? nil : shared.media, shared.callAudio, shared.microphone) }
        let plan = OutputPlan(directory: entry.directory)
        return (RecordingMedia.video(in: entry.directory, info: entry.info), plan.systemAudio, plan.microphone)
    }

    /// True when the recording can be played now. Otherwise it is fetched, and `then` runs
    /// once it is here.
    private func ready(_ then: @escaping @MainActor () -> Void) -> Bool {
        guard !isReady, let shared = entry.shared, let download else { return true }
        download.fetch([shared.media]) { [weak self] in
            guard let self, self.observer != nil else { return }
            self.load(shared.media)
            then()
        }
        return false
    }

    /// Fetches the recording without playing it.
    func fetch() { _ = ready {} }

    private func load(_ media: URL) {
        guard !isReady else { return }
        isReady = true
        if peaks.isEmpty { Task { await loadWaveform() } }
        player.replaceCurrentItem(with: AVPlayerItem(url: media))
        player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Decoded once per recording and cached beside it; the first open of a long call
    /// takes seconds, which is why it runs off the main thread and the bar fills in late.
    func loadWaveform(shared: [Float]? = nil) async {
        if let origin = entry.shared {
            peaks = shared ?? []
            /// Published before meetings carried one: read from the recording once it is here.
            guard shared == nil, isReady else { return }
            let media = origin.media, length = duration
            peaks = await Task.detached(priority: .utility) {
                Waveform.peaks(of: [media], buckets: Waveform.columns, duration: length)
            }.value
            return
        }
        let directory = entry.directory, length = duration
        peaks = await Task.detached(priority: .utility) {
            Waveform.of(directory, duration: length)
        }.value
    }

    func follow(_ transcript: Transcript?) {
        lines = transcript?.utterances.map { ($0.start, $0.end) } ?? []
        moved(to: position)
    }

    private func moved(to seconds: TimeInterval) {
        position = seconds
        let line = lines.lastIndex { $0.start <= seconds }.flatMap { seconds < lines[$0].end ? $0 : nil }
        if line != currentLine { currentLine = line }
    }

    func toggle() {
        guard ready({ [weak self] in self?.toggle() }) else { return }
        endClip()
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.rate = rate
            isPlaying = true
        }
    }

    func play(from seconds: TimeInterval) {
        seek(to: seconds)
        guard ready({ [weak self] in self?.play(from: seconds) }) else { return }
        player.rate = rate
        isPlaying = true
    }

    /// Plays exactly a clip's span and stops. Pressed again while it plays, it stops. The
    /// line it came from is highlighted through `currentLine`, as any playing line is.
    func play(_ clip: SpeakerClip) {
        guard ready({ [weak self] in self?.play(clip) }) else { return }
        if playingClip == clip {
            endClip()
            player.pause()
            isPlaying = false
            return
        }
        seek(to: clip.start)
        playingClip = clip
        clipEnd = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: min(clip.end, duration), preferredTimescale: 600))], queue: .main
        ) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.playingClip == clip else { return }
                self.endClip()
                self.player.pause()
                self.isPlaying = false
            }
        }
        player.rate = rate
        isPlaying = true
    }

    private func endClip() {
        if let clipEnd { player.removeTimeObserver(clipEnd) }
        clipEnd = nil
        if playingClip != nil { playingClip = nil }
    }

    func skip(_ seconds: TimeInterval) {
        seek(to: position + seconds)
    }

    func seek(to seconds: TimeInterval) {
        endClip()
        let target = max(0, min(seconds, duration))
        moved(to: target)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func set(_ track: Track, on: Bool) {
        if on { enabled.insert(track) } else { enabled.remove(track) }
        guard let shared = entry.shared, let download else {
            Task { await rebuild() }
            return
        }
        /// The merged recording is all there is to play while nothing is switched off; the
        /// tracks are fetched only once something is.
        let needed = hearsEverything ? [shared.media] : [shared.media] + shared.tracks
        let apply: @MainActor () -> Void = { [weak self] in
            guard let self, self.observer != nil else { return }
            self.load(shared.media)
            Task { await self.rebuild() }
        }
        if SharedDownload.isLocal(needed) { apply() } else { download.fetch(needed, then: apply) }
    }

    func stop() {
        download?.cancel()
        endClip()
        player.pause()
        isPlaying = false
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        if let finish { NotificationCenter.default.removeObserver(finish) }
        status?.invalidate()
    }

    /// Neither audio track is switched off, so the merged file is what to play: hiding the
    /// picture is the page's business and needs no other file.
    private var hearsEverything: Bool { enabled.isSuperset(of: [.callAudio, .microphone]) }

    private func rebuild() async {
        let resume = position, wasPlaying = isPlaying
        let files = Self.files(of: entry)
        let item: AVPlayerItem
        if hearsEverything, let media = entry.media {
            item = AVPlayerItem(url: media)
        } else {
            let composition = AVMutableComposition()
            var mixes: [AVAudioMixInputParameters] = []
            let parts: [(Track, URL?, AVMediaType)] = [
                (.video, files.video, .video), (.callAudio, files.callAudio, .audio), (.microphone, files.microphone, .audio),
            ]
            for case let (track, url?, kind) in parts where FileManager.default.fileExists(atPath: url.path) {
                let asset = AVURLAsset(url: url)
                guard let source = try? await asset.loadTracks(withMediaType: kind).first,
                    let range = try? await source.load(.timeRange),
                    let slot = composition.addMutableTrack(withMediaType: kind, preferredTrackID: kCMPersistentTrackID_Invalid)
                else { continue }
                /// The call's track is moved into line with the microphone and the picture,
                /// as the merged file has it, by the offset the mix measured from the echo:
                /// a stretch at a time when the offset changed over the call.
                let offset = entry.shared?.callShift ?? MixDecision.read(in: entry.directory)?.alignment.systemAudio
                let advance = track == .callAudio ? (offset ?? .zero) : .zero
                Self.place(source, range: range, shifted: advance, into: slot)
                if kind == .audio {
                    let parameters = AVMutableAudioMixInputParameters(track: slot)
                    parameters.setVolume(enabled.contains(track) ? 1 : 0, at: .zero)
                    mixes.append(parameters)
                }
            }
            item = AVPlayerItem(asset: composition)
            let mix = AVMutableAudioMix()
            mix.inputParameters = mixes
            item.audioMix = mix
        }
        player.replaceCurrentItem(with: item)
        await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if wasPlaying { player.rate = rate }
    }

    /// The track laid into `slot` on the microphone's timeline: each held stretch of
    /// `shift` read from where it lies in the file, with silence where it would start
    /// before the file does. One stretch for a constant offset.
    private static func place(_ source: AVAssetTrack, range: CMTimeRange, shifted shift: TrackShift,
                              into slot: AVMutableCompositionTrack) {
        guard !shift.isZero else {
            try? slot.insertTimeRange(range, of: source, at: .zero)
            return
        }
        let length = range.duration.seconds
        let time = { (seconds: Double) in CMTime(seconds: seconds, preferredTimescale: 48_000) }
        for stretch in shift.stretches(until: shift.referenceTime(of: length)) {
            let from = stretch.start + stretch.seconds, to = min(length, stretch.end + stretch.seconds)
            let start = max(0, from)
            guard to > start else { continue }
            try? slot.insertTimeRange(CMTimeRange(start: range.start + time(start), duration: time(to - start)),
                                      of: source, at: time(stretch.start + (start - from)))
        }
    }
}
