import SwiftUI

/// One line worth reading before pressing anything — an advisory, or what went wrong.
struct Notice: View {
    enum Level {
        case advisory
        case error
    }

    let text: String
    let level: Level

    init(_ text: String, level: Level = .advisory) {
        self.text = text
        self.level = level
    }

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(level == .error ? Color.red : .secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var symbol: String {
        level == .error ? "exclamationmark.octagon" : "exclamationmark.triangle"
    }
}
