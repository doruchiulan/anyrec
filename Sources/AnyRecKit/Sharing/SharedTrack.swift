import Foundation

/// One of a recording's separate tracks as it is shared. The call's is the master as it is.
/// The microphone's is rendered from its master with every stretch the call was not
/// listening silenced, the same gate the mix uses: the master holds what was said to the
/// room while muted. Where the mute was not followed (`MicrophoneLive.followedMute`) nothing
/// can be silenced, so the microphone is not shared on its own.
struct SharedTrack {
    let name: String
    /// What it is made from, so it is made again only when that changes.
    let stamp: String
    let make: (URL) throws -> Void

    static func all(in source: URL, ffmpeg: String? = Muxer.ffmpegPath()) -> [SharedTrack] {
        let plan = OutputPlan(directory: source)
        let fm = FileManager.default
        var tracks: [SharedTrack] = []
        if fm.fileExists(atPath: plan.systemAudio.path), let stamp = try? SharedMeeting.stamp(plan.systemAudio) {
            let file = plan.systemAudio
            tracks.append(SharedTrack(name: SharedMeeting.callTrack, stamp: stamp) { try fm.copyItem(at: file, to: $0) })
        }
        /// A copy of someone else's recording has their microphone already silenced, and no
        /// record of the mute to silence it by: it is not shared on.
        if fm.fileExists(atPath: plan.microphone.path), let ffmpeg, let live = MicrophoneLive.read(plan.microphoneLive),
           live.followedMute, let stamp = try? SharedMeeting.stamp(plan.microphone),
           let mute = try? SharedMeeting.stamp(plan.microphoneLive) {
            let file = plan.microphone
            tracks.append(SharedTrack(name: SharedMeeting.microphoneTrack, stamp: stamp + "|" + mute) { output in
                let result = try Shell.run(ffmpeg, arguments(microphone: file, live: live, output: output))
                guard result.succeeded else { throw RecordingShare.Failure.failed("The microphone track could not be prepared.") }
            })
        }
        return tracks
    }

    static func arguments(microphone: URL, live: MicrophoneLive, output: URL) -> [String] {
        ["-nostdin", "-y", "-v", "error", "-i", microphone.path, "-af", MixPlan.gate(live), "-c:a", "aac", "-b:a", "96k", output.path]
    }
}
