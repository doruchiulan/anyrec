import SwiftUI

struct CallReminderView: View {
    let appName: String
    let record: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.circle.fill").font(.title2).foregroundStyle(.teal)
                .accessibilityHidden(true)
            Text("Record \(appName) call?").font(.callout.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 0)
            Button("Record", action: record)
                .buttonStyle(.borderedProminent).tint(.teal)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Dismiss for this call").accessibilityLabel("Dismiss recording reminder")
        }
        .padding(.horizontal, 14)
        .frame(width: 390, height: 54)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.1)))
    }
}
