import SwiftUI

/// One line worth reading before pressing anything — an advisory, or what went wrong. The
/// symbol carries the colour; the words stay in the standard label colour so they read.
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
        Label {
            Text(text).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: level == .error ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(level == .error ? .red : .yellow)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
}
