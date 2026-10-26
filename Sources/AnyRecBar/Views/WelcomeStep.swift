import SwiftUI

enum WelcomeStep: String, CaseIterable, Identifiable {
    case permissions = "Permissions"
    case transcription = "Transcription"

    var id: Self { self }
    var number: Int { self == .permissions ? 1 : 2 }
    var symbol: String { self == .permissions ? "record.circle" : "text.bubble" }
    var title: String {
        self == .permissions ? "Your next call, captured." : "Turn conversations into text."
    }
    var lead: String {
        self == .permissions
            ? "Allow these four permissions so AnyRec is ready for your first call."
            : "Download an on-device engine. Your audio stays on this Mac."
    }
}
