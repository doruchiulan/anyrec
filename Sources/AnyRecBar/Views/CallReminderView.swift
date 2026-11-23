import SwiftUI

struct CallReminderView: View {
    /// Wide enough for the question and both buttons beside it.
    static let size = CGSize(width: 470, height: 54)

    let appName: String
    /// True records the window's picture too; false is Audio Only.
    let record: (Bool) -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            Text("Record \(appName) call?").font(.callout.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 0)
            Button(Wording.bannerRecord(video: false)) { record(false) }
                .buttonStyle(.bordered)
                .help("Record the call's sound, names and mute, without the picture")
            Button(Wording.bannerRecord(video: true)) { record(true) }
                .buttonStyle(.borderedProminent).tint(.teal)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Dismiss for this call").accessibilityLabel("Dismiss recording reminder")
        }
        .padding(.horizontal, 14)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.1)))
    }
}
