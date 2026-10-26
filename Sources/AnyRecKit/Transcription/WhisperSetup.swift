import Foundation

/// What stands between a fresh machine and a whisper transcript, and how to fetch it:
/// whisper itself is built in, so it is the model, voice detection, and ffmpeg for the
/// mix. Everything here is optional: the tool records perfectly well without any of it.
public enum WhisperSetup {
    /// Turbo is the model `doctor` has always pointed at — multilingual, quantised
    /// to a size worth downloading, and good enough at Romanian to be the only one offered.
    public static let model = AssetDownload.Asset(
        name: "ggml-large-v3-turbo-q5_0.bin",
        url: URL(
            string:
                "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin"
        )!,
        sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
        bytes: 574_041_195
    )

    /// A rounding error next to the model, and it is what keeps whisper's first segment
    /// from swallowing the leading silence.
    public static let voiceDetection = AssetDownload.Asset(
        name: "ggml-silero-v5.1.2.bin",
        url: URL(
            string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin"
        )!,
        sha256: "29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf",
        bytes: 885_098
    )

    /// One thing to fetch or install, for any engine: whisper's are here because they
    /// came first, and Parakeet's and ffmpeg's use the same list.
    public enum Step: Sendable, Equatable {
        /// A whisper model, into the models folder.
        case fetch(AssetDownload.Asset)
        /// ffmpeg, into the tools folder, made executable.
        case fetchFFmpeg
        /// Parakeet's model, several files through FluidAudio.
        case fetchParakeet

        public var title: String {
            switch self {
            case .fetch(let asset): "Download \(asset.name)"
            case .fetchFFmpeg: "Download ffmpeg"
            case .fetchParakeet: "Download Parakeet"
            }
        }

        public var detail: String {
            switch self {
            case .fetch(let asset): AssetDownload.describe(asset.bytes)
            case .fetchFFmpeg: FFmpegSetup.downloadSize
            case .fetchParakeet: ParakeetSetup.downloadSize
            }
        }

        public var bytes: Int64 {
            switch self {
            case .fetch(let asset): asset.bytes
            case .fetchFFmpeg: FFmpegSetup.asset.bytes
            case .fetchParakeet: ParakeetSetup.bytes
            }
        }
    }

    /// Only what is actually absent, in the order it should be fetched. ffmpeg is in
    /// here because whisper is fed through it: without ffmpeg the model is dead weight.
    public static func pending() -> [Step] {
        var steps: [Step] = []
        if !FFmpegSetup.isReady { steps.append(.fetchFFmpeg) }
        if WhisperTranscriber.defaultModel() == nil { steps.append(.fetch(model)) }
        if WhisperTranscriber.voiceDetectionModel() == nil { steps.append(.fetch(voiceDetection)) }
        return steps
    }

    public static func downloadSize(of steps: [Step]) -> Int64 {
        steps.reduce(0) { $0 + $1.bytes }
    }

    /// `progress` is called with a line worth showing, often.
    public static func perform(
        _ step: Step, progress: @escaping @Sendable (String) -> Void
    ) async throws {
        switch step {
        case .fetchFFmpeg:
            try await FFmpegSetup.fetch(progress: progress)
        case .fetchParakeet:
            try await ParakeetSetup.fetch(progress: progress)
        case .fetch(let asset):
            let total = AssetDownload.describe(asset.bytes)
            _ = try await AssetDownload.fetch(asset, into: WhisperTranscriber.modelDirectory) {
                progress("\(AssetDownload.describe($0)) of \(total)")
            }
        }
    }


}
