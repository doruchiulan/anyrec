import Foundation

/// Whether an engine can run right now, and what stands between it and running.
public enum EngineReadiness: Sendable, Equatable {
    case ready
    /// Installable from here — the steps are what `WhisperSetup.perform` takes.
    case needsSetup([WhisperSetup.Step])
    case needsKey
    /// Available on this Mac's terms, and those terms are not met.
    case unavailable(reason: String)

    public var isReady: Bool { self == .ready }
}

/// The one thing worth saying about a configuration before recording starts. Each
/// case carries the facts; the wording belongs to whatever is drawing it, because
/// "⏎ on Transcript" means nothing outside a terminal.
public enum Advisory: Sendable, Equatable {
    /// The on-device engine has no model yet; choosing it is what fetches one.
    case parakeetNotSetUp
    case whisperNotSetUp
    case openAIKeyMissing
    case appleUnavailable
    case ffmpegMissing
    case openAIUploadsAudio
    case appleCoversSomeLanguages(count: Int)
    case bothAudioTracksOff
    /// The far end will be one voice until the speaker models are fetched.
    case speakersNotSetUp
    /// Without the Accessibility grant, a mute pressed in Teams or Slack goes unseen
    /// and the microphone stays in the mix while it is on.
    case accessibilityMissing
}

/// What is installed and available on this machine, asked once so every interface
/// gets the same answer.
public struct Readiness: Sendable {
    /// What Apple's on-device engine can transcribe here. Empty means it cannot run at
    /// all. Held rather than looked up because it is the one answer that is an await
    /// away; everything else here is a file check.
    public let appleLanguages: [String]

    public init(appleLanguages: [String]) {
        self.appleLanguages = appleLanguages
    }

    public static func probe() async -> Readiness {
        Readiness(appleLanguages: await AppleSpeech.languages())
    }

    public static var ffmpegInstalled: Bool { Muxer.ffmpegPath() != nil }
    /// Whether the far end can be told apart on this machine. A file check, like ffmpeg.
    public static var speakersReady: Bool { SpeakerSetup.isReady }

    public func of(_ engine: TranscriptionEngine) -> EngineReadiness {
        switch engine {
        /// `auto` is Parakeet once its model is here, Apple's engine where that can
        /// run, whisper after that — so what stands in its way, when nothing local is
        /// ready, is Parakeet's download, the one with nothing to install.
        case .auto:
            if of(.parakeet).isReady || !appleLanguages.isEmpty || of(.whisper).isReady {
                return .ready
            }
            return of(.parakeet)
        case .parakeet:
            return ParakeetSetup.pending().isEmpty ? .ready : .needsSetup(ParakeetSetup.pending())
        case .apple:
            return appleLanguages.isEmpty
                ? .unavailable(reason: "Apple's on-device transcription needs macOS 26.")
                : .ready
        case .whisper:
            return WhisperSetup.pending().isEmpty ? .ready : .needsSetup(WhisperSetup.pending())
        case .openai:
            return OpenAIKey.current() == nil ? .needsKey : .ready
        }
    }

    /// Ordered by what is most worth fixing, and only ever one at a time. whisper comes
    /// before ffmpeg because setting whisper up installs ffmpeg too, and saying it
    /// twice helps nobody.
    public func advisory(for configuration: RecordingConfiguration) -> Advisory? {
        switch configuration.transcribe {
        case .parakeet where !of(.parakeet).isReady: return .parakeetNotSetUp
        case .auto where !of(.auto).isReady: return .parakeetNotSetUp
        case .whisper where !of(.whisper).isReady: return .whisperNotSetUp
        case .openai where !of(.openai).isReady: return .openAIKeyMissing
        case .apple where appleLanguages.isEmpty: return .appleUnavailable
        default: break
        }

        if configuration.mux, !Self.ffmpegInstalled { return .ffmpegMissing }
        if configuration.transcribe == .openai { return .openAIUploadsAudio }
        /// The one engine that can be picked, be ready, and still have no model for
        /// the call — so what it covers is said before the call rather than after.
        if configuration.transcribe == .apple {
            return .appleCoversSomeLanguages(count: appleLanguages.count)
        }
        if configuration.microphone == nil, !configuration.systemAudio {
            return .bothAudioTracksOff
        }
        if configuration.microphone != nil, !Permissions.accessibilityGranted() {
            return .accessibilityMissing
        }
        if configuration.transcribe != nil, !Self.speakersReady { return .speakersNotSetUp }
        return nil
    }
}
