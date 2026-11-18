import AVFoundation
import Foundation

enum WriterError: Error, LocalizedError, CustomStringConvertible {
    case cannotAddInput(URL)
    case cannotStartWriting(URL, Error?)
    /// AVAssetWriter would refuse these settings by raising an Objective-C exception,
    /// which Swift cannot catch: it is asked first, and this is the answer.
    case unsupportedSettings(URL, String)

    var description: String {
        switch self {
        case .cannotAddInput(let url):
            "AVAssetWriter rejected the input for \(url.lastPathComponent)."
        case .cannotStartWriting(let url, let error):
            "Could not start writing \(url.lastPathComponent): \(error?.localizedDescription ?? "unknown error")."
        case .unsupportedSettings(let url, let what):
            "\(url.lastPathComponent) cannot be encoded as \(what)."
        }
    }

    /// Without this, anything that reports the error through `localizedDescription`
    /// prints "the operation couldn't be completed" and a case number instead.
    var errorDescription: String? { description }
}

/// One AVAssetWriter and its single input. Audio inputs are built from the first
/// sample buffer's format description so the encoder matches the source exactly —
/// the microphone arrives in its device's native format, not the stream config's.
///
/// An audio track keeps its time across a gap and its format across a device change.
/// AVAssetWriter packs audio samples back to back whatever their timestamps say —
/// measured: five seconds, a two-second gap in the stamps, five more, and the file ran ten
/// seconds with no silence in it — so a microphone that stopped for two seconds while it
/// switched devices would have pulled everything after it two seconds early, against the
/// other tracks and the picture. A gap longer than `gapTolerance` between one buffer's end
/// and the next one's stamp is written as that much silence, and a buffer in another
/// format is converted to the first one's (`AudioConformer`).
final class TrackWriter {
    enum Kind {
        case video(codec: AVVideoCodecType, width: Int, height: Int)
        case audio
    }

    /// A stretch written as silence because nothing arrived for it.
    struct Gap: Equatable {
        /// Seconds into the track.
        let at: Double
        let seconds: Double
    }

    /// Buffers follow each other to within a fraction of a millisecond; a device switch
    /// leaves hundreds of them. Anything over this between one buffer's end and the next
    /// one's stamp is time that passed with nothing recorded.
    static let gapTolerance = 0.05
    /// The longest single silent buffer, so a long gap is written in pieces of a size the
    /// encoder takes in its stride.
    static let longestSilence = 2.0

    let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let isAudio: Bool
    private var conformer: AudioConformer?
    private var sessionStarted = false
    /// Where the last buffer written ends, on its own clock.
    private var end: CMTime?
    private(set) var samplesWritten = 0
    private(set) var samplesDropped = 0
    private(set) var gaps: [Gap] = []

    init(url: URL, kind: Kind, formatHint: CMFormatDescription?) throws {
        self.url = url
        let fileType: AVFileType = if case .video = kind { .mov } else { .m4a }
        writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        input = try Self.makeInput(kind: kind, formatHint: formatHint, writer: writer, url: url)
        input.expectsMediaDataInRealTime = true
        if case .audio = kind {
            isAudio = true
            conformer = formatHint.flatMap { AVAudioFormat(cmAudioFormatDescription: $0) }.map(AudioConformer.init)
        } else {
            isAudio = false
        }

        do {
            guard writer.canAdd(input) else { throw WriterError.cannotAddInput(url) }
            writer.add(input)
            guard writer.startWriting() else {
                throw WriterError.cannotStartWriting(url, writer.error)
            }
        } catch {
            /// AVAssetWriter creates the file before it will encode anything, so a
            /// failure here leaves an empty track behind that looks like a real one.
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// AAC here refuses to encode below 44.1 kHz outright rather than resampling —
    /// `startWriting` fails when a source format hint is set, `append` when it is not.
    /// Bluetooth is what hits this: as an input, a pair of AirPods runs at 16 kHz.
    static let lowestEncodableRate = 44_100.0

    /// And above 48 kHz it refuses too — "96000 Hz is not a valid sample rate for Format ID
    /// 'aac '" — by raising from `AVAssetWriterInput`'s initialiser, which killed the app
    /// the moment a microphone running at 96 kHz (USB interfaces, some webcams) delivered
    /// its first buffer. A rate above is encoded at 44.1 kHz when it is a multiple of it,
    /// else at 48 kHz; the input resamples.
    static let highestEncodableRate = 48_000.0

    static func encodableRate(_ rate: Double) -> Double {
        if rate >= lowestEncodableRate && rate <= highestEncodableRate { return rate }
        if rate > highestEncodableRate, rate.truncatingRemainder(dividingBy: lowestEncodableRate) == 0 {
            return lowestEncodableRate
        }
        return 48_000
    }

    /// The AAC settings for a source format, before they are checked.
    static func audioSettings(for asbd: AudioStreamBasicDescription?) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: encodableRate(asbd?.mSampleRate ?? 48_000),
            AVNumberOfChannelsKey: max(min(Int(asbd?.mChannelsPerFrame ?? 2), 2), 1),
            AVEncoderBitRateKey: 128_000,
        ]
    }

    /// Every input's settings are put to `canApply` before the input is made: the
    /// initialiser raises an Objective-C exception for settings it refuses, which no Swift
    /// code can catch. Audio the encoder will not take as asked falls back to plain 48 kHz
    /// AAC at the encoder's own bitrate; anything still refused is a thrown error.
    private static func makeInput(
        kind: Kind, formatHint: CMFormatDescription?, writer: AVAssetWriter, url: URL
    ) throws -> AVAssetWriterInput {
        switch kind {
        case let .video(codec, width, height):
            let settings: [String: Any] = [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
            guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
                throw WriterError.unsupportedSettings(url, "\(codec.rawValue) at \(width)×\(height)")
            }
            return AVAssetWriterInput(mediaType: .video, outputSettings: settings)

        case .audio:
            let asbd = formatHint.flatMap {
                CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee
            }
            var settings = audioSettings(for: asbd)
            if !writer.canApply(outputSettings: settings, forMediaType: .audio) {
                settings[AVSampleRateKey] = 48_000.0
                settings[AVEncoderBitRateKey] = nil
            }
            guard writer.canApply(outputSettings: settings, forMediaType: .audio) else {
                throw WriterError.unsupportedSettings(
                    url, "AAC from \(Int(asbd?.mSampleRate ?? 0)) Hz, \(asbd?.mChannelsPerFrame ?? 0) channels")
            }
            return AVAssetWriterInput(
                mediaType: .audio, outputSettings: settings, sourceFormatHint: formatHint
            )
        }
    }

    /// All tracks share one session start so their relative offsets survive into the files.
    func append(_ buffer: CMSampleBuffer, sessionStart: CMTime) {
        if !sessionStarted {
            writer.startSession(atSourceTime: sessionStart)
            sessionStarted = true
        }
        guard isAudio else { return write(buffer) }
        guard let sample = conformed(buffer) else {
            samplesDropped += 1
            return
        }
        let start = CMSampleBufferGetPresentationTimeStamp(sample)
        let length = CMTime(seconds: AudioBuffers.length(of: sample), preferredTimescale: start.timescale)
        if let end, start.isNumeric {
            /// Wholly inside what is already written: a device's first buffers stamped
            /// before the last one's end. Written, they would push the track late.
            guard CMTimeCompare(start + length, end) > 0 else { return }
            let gap = (start - end).seconds
            if gap > Self.gapTolerance { fill(from: end, seconds: gap, sessionStart: sessionStart) }
        }
        write(sample)
        if start.isNumeric { end = start + length }
    }

    private func write(_ buffer: CMSampleBuffer) {
        guard writer.status == .writing, input.isReadyForMoreMediaData else {
            samplesDropped += 1
            return
        }
        if input.append(buffer) {
            samplesWritten += 1
        } else {
            samplesDropped += 1
        }
    }

    /// The buffer in this track's format: the first buffer's, or the hint's.
    private func conformed(_ buffer: CMSampleBuffer) -> CMSampleBuffer? {
        if conformer == nil {
            guard let format = AudioBuffers.format(of: buffer) else { return buffer }
            conformer = AudioConformer(format: format)
        }
        return conformer?.conform(buffer)
    }

    /// `seconds` of silence from `start`, in the track's format, so what follows lands at
    /// its own time. A silent buffer the writer is not ready for is waited for briefly:
    /// dropped, it would be the very jump this is here to prevent.
    private func fill(from start: CMTime, seconds: Double, sessionStart: CMTime) {
        guard let format = conformer?.format, format.sampleRate > 0 else { return }
        gaps.append(Gap(at: (start - sessionStart).seconds, seconds: seconds))
        var remaining = AVAudioFrameCount((seconds * format.sampleRate).rounded())
        var at = start
        while remaining > 0 {
            let frames = min(remaining, AVAudioFrameCount(Self.longestSilence * format.sampleRate))
            guard let silence = AudioBuffers.silence(format, frames: frames),
                  let sample = AudioBuffers.sample(silence, at: at) else { return }
            var waited = 0
            while writer.status == .writing, !input.isReadyForMoreMediaData, waited < 200 {
                usleep(1_000)
                waited += 1
            }
            guard writer.status == .writing, input.isReadyForMoreMediaData, input.append(sample) else {
                samplesDropped += 1
                return
            }
            remaining -= frames
            at = at + CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(format.sampleRate))
        }
    }

    /// Finalises the file, or removes it if nothing was ever written to it.
    @discardableResult
    func finish() async -> Int {
        guard sessionStarted, samplesWritten > 0 else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            return 0
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        return samplesWritten
    }
}
