import AnyRecKit
import SwiftUI

/// Who the call window showed during the recording, read from `call-participants.json`,
/// and how much of the call it could be read for. Evidence beside the transcript's
/// speakers, not a guaranteed attendance list.
struct ObservedParticipants: View {
    let participants: CallParticipants
    let voices: RecordingVoices?
    let duration: TimeInterval

    var body: some View {
        let roster = participants.roster
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(roster, id: \.name) { person in
                    LabeledContent(person.name) {
                        Text(Wording.spokeAlone(person.speaking)).foregroundStyle(.secondary)
                    }
                }
                Text(Wording.readable(participants.readable, of: duration))
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(Wording.voiceFacts(voices), id: \.self) { fact in
                    Text(fact).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Text("In the Call Window").font(.headline)
        }
    }
}
