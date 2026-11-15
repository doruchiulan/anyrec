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
    /// The boundary observer that pauses the player at a clip's end.
    private var clipEnd: Any?

    init(_ entry: LibraryEntry) {
        self.entry = entry
        duration = entry.duration
        let plan = OutputPlan(directory: entry.directory)
        let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
        available = Track.allCases.filter {
            switch $0 {
            case .callAudio: exists(plan.systemAudio)
            case .microphone: exists(plan.microphone)
            case .video: entry.video != nil
            }
        }
        if let media = entry.media {
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

    /// Decoded once per recording and cached beside it; the first open of a long call
    /// takes seconds, which is why it runs off the main thread and the bar fills in late.
    func loadWaveform() async {
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
        player.rate = rate
        isPlaying = true
    }

    /// Plays exactly a clip's span and stops. Pressed again while it plays, it stops. The
    /// line it came from is highlighted through `currentLine`, as any playing line is.
    func play(_ clip: SpeakerClip) {
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
        Task { await rebuild() }
    }

    func stop() {
        endClip()
        player.pause()
        isPlaying = false
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        if let finish { NotificationCenter.default.removeObserver(finish) }
        status?.invalidate()
    }

    private func rebuild() async {
        let resume = position, wasPlaying = isPlaying
        let plan = OutputPlan(directory: entry.directory)
        let everything = enabled.count == Track.allCases.count
        let item: AVPlayerItem
        if everything, let media = entry.media {
            item = AVPlayerItem(url: media)
        } else {
            let composition = AVMutableComposition()
            var mixes: [AVAudioMixInputParameters] = []
            let parts: [(Track, URL?, AVMediaType)] = [
                (.video, RecordingMedia.video(in: entry.directory, info: entry.info), .video),
                (.callAudio, plan.systemAudio, .audio), (.microphone, plan.microphone, .audio),
            ]
            for case let (track, url?, kind) in parts where FileManager.default.fileExists(atPath: url.path) {
                let asset = AVURLAsset(url: url)
                guard let source = try? await asset.loadTracks(withMediaType: kind).first,
                    let range = try? await source.load(.timeRange),
                    let slot = composition.addMutableTrack(withMediaType: kind, preferredTrackID: kCMPersistentTrackID_Invalid)
                else { continue }
                /// The call's track is moved into line with the microphone and the picture,
                /// as the merged file has it, by the offset the mix measured from the echo.
                let advance = track == .callAudio ? (MixDecision.read(in: entry.directory)?.alignment.systemAudio ?? 0) : 0
                let shift = CMTime(seconds: abs(advance), preferredTimescale: 48_000)
                if advance > 0, range.duration > shift {
                    try? slot.insertTimeRange(CMTimeRange(start: range.start + shift, duration: range.duration - shift),
                                              of: source, at: .zero)
                } else {
                    try? slot.insertTimeRange(range, of: source, at: advance < 0 ? shift : .zero)
                }
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
}
