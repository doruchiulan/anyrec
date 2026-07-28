import AVFoundation
import Foundation

enum WriterError: Error, LocalizedError, CustomStringConvertible {
    case cannotAddInput(URL)
    case cannotStartWriting(URL, Error?)

    var description: String {
        switch self {
        case .cannotAddInput(let url):
            "AVAssetWriter rejected the input for \(url.lastPathComponent)."
        case .cannotStartWriting(let url, let error):
            "Could not start writing \(url.lastPathComponent): \(error?.localizedDescription ?? "unknown error")."
        }
    }

    /// Without this, anything that reports the error through `localizedDescription`
    /// prints "the operation couldn't be completed" and a case number instead.
    var errorDescription: String? { description }
}

/// One AVAssetWriter and its single input. Audio inputs are built from the first
/// sample buffer's format description so the encoder matches the source exactly —
/// the microphone arrives in its device's native format, not the stream config's.
final class TrackWriter {
    enum Kind {
        case video(codec: AVVideoCodecType, width: Int, height: Int)
        case audio
    }

    let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var sessionStarted = false
    private(set) var samplesWritten = 0
    private(set) var samplesDropped = 0

    init(url: URL, kind: Kind, formatHint: CMFormatDescription?) throws {
        self.url = url
        let fileType: AVFileType = if case .video = kind { .mov } else { .m4a }
        writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        input = Self.makeInput(kind: kind, formatHint: formatHint)
        input.expectsMediaDataInRealTime = true

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

    static func encodableRate(_ rate: Double) -> Double {
        rate >= lowestEncodableRate ? rate : 48_000
    }

    private static func makeInput(
        kind: Kind, formatHint: CMFormatDescription?
    ) -> AVAssetWriterInput {
        switch kind {
        case let .video(codec, width, height):
            let settings: [String: Any] = [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
            return AVAssetWriterInput(mediaType: .video, outputSettings: settings)

        case .audio:
            let asbd = formatHint.flatMap {
                CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee
            }
            let channels = min(Int(asbd?.mChannelsPerFrame ?? 2), 2)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: encodableRate(asbd?.mSampleRate ?? 48_000),
                AVNumberOfChannelsKey: max(channels, 1),
                AVEncoderBitRateKey: 128_000,
            ]
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
