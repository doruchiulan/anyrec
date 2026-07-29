import Foundation

/// What stands between a fresh machine and a whisper transcript, and how to fetch it.
/// Everything here is optional: the tool records perfectly well without any of it.
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

    public enum Step: Sendable, Equatable {
        case install(formula: String, binary: String)
        case fetch(AssetDownload.Asset)

        public var title: String {
            switch self {
            case .install(let formula, _): "Install \(formula)"
            case .fetch(let asset): "Download \(asset.name)"
            }
        }

        public var detail: String {
            switch self {
            case .install(let formula, _): "brew install \(formula)"
            case .fetch(let asset): AssetDownload.describe(asset.bytes)
            }
        }

        /// Zero for the steps that install rather than download.
        public var bytes: Int64 {
            if case .fetch(let asset) = self { return asset.bytes }
            return 0
        }
    }

    public enum Failure: Error, LocalizedError, CustomStringConvertible {
        case homebrewMissing
        case installFailed(formula: String, log: String)

        public var description: String {
            switch self {
            case .homebrewMissing:
                "Homebrew is not installed. Get it from https://brew.sh, then try again."
            case .installFailed(let formula, let log):
                "brew install \(formula) failed:\n\(log)"
            }
        }

        public var errorDescription: String? { description }
    }

    /// Only what is actually absent, in the order it should be fetched. ffmpeg is in
    /// here because whisper is fed through it: without ffmpeg the model is dead weight.
    public static func pending() -> [Step] {
        var steps: [Step] = []
        if Muxer.ffmpegPath() == nil {
            steps.append(.install(formula: "ffmpeg", binary: "ffmpeg"))
        }
        if WhisperTranscriber.binaryPath() == nil {
            steps.append(.install(formula: "whisper-cpp", binary: "whisper-cli"))
        }
        if WhisperTranscriber.defaultModel() == nil { steps.append(.fetch(model)) }
        if WhisperTranscriber.voiceDetectionModel() == nil { steps.append(.fetch(voiceDetection)) }
        return steps
    }

    public static func brewPath() -> String? { Shell.path(of: "brew") }

    /// Homebrew does the installing, so its absence has to be said before the setup is
    /// offered rather than partway through it.
    public static var needsHomebrew: Bool {
        guard brewPath() == nil else { return false }
        return pending().contains {
            if case .install = $0 { return true }
            return false
        }
    }

    public static func downloadSize(of steps: [Step]) -> Int64 {
        steps.reduce(0) { $0 + $1.bytes }
    }

    /// `progress` is called with a line worth showing, often.
    public static func perform(
        _ step: Step, progress: @escaping @Sendable (String) -> Void
    ) async throws {
        switch step {
        case .install(let formula, let binary):
            try install(formula: formula, binary: binary, progress: progress)
        case .fetch(let asset):
            let total = AssetDownload.describe(asset.bytes)
            _ = try await AssetDownload.fetch(asset, into: WhisperTranscriber.modelDirectory) {
                progress("\(AssetDownload.describe($0)) of \(total)")
            }
        }
    }

    /// Auto-update is off because it fetches the whole of homebrew-core before
    /// installing anything, and both formulae here are older than the tool.
    private static func install(
        formula: String, binary: String, progress: @escaping (String) -> Void
    ) throws {
        guard let brew = brewPath() else { throw Failure.homebrewMissing }

        let result = try Shell.run(
            brew, ["install", formula],
            environment: [
                "HOMEBREW_NO_AUTO_UPDATE": "1",
                "HOMEBREW_NO_ENV_HINTS": "1",
                "HOMEBREW_NO_COLOR": "1",
            ],
            onOutput: { line in
                let text = plain(line)
                if !text.isEmpty { progress(text) }
            }
        )

        guard result.succeeded, Shell.path(of: binary) != nil else {
            throw Failure.installFailed(
                formula: formula, log: String(result.combined.suffix(600)))
        }
    }

    /// brew draws spinners and colour even when asked not to, and a stray escape
    /// sequence in a status line moves the cursor out of the layout.
    static func plain(_ line: String) -> String {
        var text = ""
        var escaping = false
        for character in line {
            if escaping {
                escaping = !character.isLetter
            } else if character == "\u{1B}" {
                escaping = true
            } else if !character.unicodeScalars.contains(where: { $0.value < 0x20 }) {
                text.append(character)
            }
        }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
