import AnyRecKit

enum SetupTarget: Equatable, Sendable {
    case ffmpeg
    case parakeet
    case whisper

    /// The engine this download sets up, if it sets one up.
    var engine: TranscriptionEngine? {
        switch self {
        case .ffmpeg: nil
        case .parakeet: .parakeet
        case .whisper: .whisper
        }
    }
}
