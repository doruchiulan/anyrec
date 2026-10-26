import AnyRecKit
import SwiftUI

struct WelcomeHeader: View {
    @Binding var step: WelcomeStep
    let permissionsReady: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Spacer()
                ForEach(WelcomeStep.allCases) { item in
                    Button { step = item } label: {
                        HStack(spacing: 7) {
                            Image(systemName: item.number < step.number ? "checkmark.circle.fill" : "\(item.number).circle.fill")
                            Text(item.rawValue)
                        }
                        .font(.callout.weight(item == step ? .semibold : .regular))
                        .foregroundStyle(item == step ? Color.primary : Color.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(item == step ? Color.teal.opacity(0.12) : .clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(item == .transcription && !permissionsReady)
                    .accessibilityValue(item == step ? "Current step" : "")
                }
            }
            HStack(alignment: .center, spacing: 20) {
                Image(systemName: step.symbol)
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.teal)
                    .frame(width: 78, height: 78)
                    .background(.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 22))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text(step.title).font(.system(size: 28, weight: .semibold))
                    Text(step.lead).font(.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(30)
        .background(LinearGradient(colors: [.teal.opacity(0.08), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}

struct WelcomeCard<Control: View>: View {
    let symbol: String
    let title: String
    let detail: String
    var engine: TranscriptionEngine? = nil
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.teal)
                .frame(width: 32).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(title).font(.headline)
                    if let engine { EngineInfo(engine: engine) }
                }
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            control.controlSize(.large)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.06)))
    }
}
