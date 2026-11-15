import AnyRecKit
import SwiftUI

/// Who the call window showed during the recording, read from `call-participants.json`,
/// and how much of the call it could be read for: the Speakers panel's last section, and
/// a box of its own for a recording with no transcript yet. Evidence beside the
/// transcript's speakers, not a guaranteed attendance list.
struct ObservedParticipants: View {
    let participants: CallParticipants
    let voices: RecordingVoices?
    let duration: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("In the Call Window").font(.subheadline.bold())
            ForEach(participants.roster, id: \.name) { person in
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
    }
}
