import AnyRecKit
import SwiftUI

struct ObservedParticipants: View {
    let participants: CallParticipants

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("In the Call Window").font(.subheadline.bold())
            ForEach(participants.roster, id: \.name) { person in
                LabeledContent(person.name) {
                    Text(Wording.spokeAlone(person.speaking)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
