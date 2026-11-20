import AnyRecKit
import SwiftUI

/// The people the library can put a name to, each with a way to make it forget them.
struct PeopleList: View {
    @Bindable var controller: RecordingController

    var body: some View {
        List {
            if !controller.libraryIssues.isEmpty {
                Section("Worth a Look") { LibraryIssues(controller: controller) }
            }
            Section { ForEach(controller.people, id: \.name) { person in row(person) } }
        }
        .overlay {
            if controller.people.isEmpty {
                ContentUnavailableView(
                    "No People", systemImage: "person.2",
                    description: Text("Name a voice in a transcript and it's recognised on the next call."))
            }
        }
        .safeAreaInset(edge: .bottom) { VoicesExchange(controller: controller) }
    }

    private func row(_ person: VoiceLibrary.Person) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(person.name)
                Text(Wording.person(person))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: person.isOwner ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
        }
        .contextMenu {
            if person.isOwner {
                Button("This Isn’t Me") { controller.setOwner(nil) }
            } else {
                Button("This Is Me") { controller.setOwner(person.name) }
            }
            if !person.prints.isEmpty {
                Menu("Remove Voiceprint") {
                    ForEach(Array(person.prints.indices), id: \.self) { index in
                        let origin = person.origin(ofPrint: index)
                        Button(Wording.printOrigin(origin, number: index + 1,
                                                   title: controller.recordingTitle(folder: origin?.recording))) {
                            controller.removePrint(at: index, from: person.name)
                        }
                    }
                }
            }
            if !person.retired.isEmpty {
                /// Set aside to keep a few varied, strong voiceprints; bringing one back sets
                /// the weakest other aside instead.
                Menu("Bring Back Voiceprint") {
                    ForEach(Array(person.retired.indices), id: \.self) { index in
                        let origin = person.origin(ofRetired: index)
                        Button(Wording.printOrigin(origin, number: index + 1, title: controller.recordingTitle(folder: origin?.recording))) {
                            controller.bringBack(retired: index, of: person.name)
                        }
                    }
                }
            }
            Divider()
            Button("Forget \(person.name)") { controller.forget(person.name) }
        }
    }
}

/// The library's own doubts, one plain question each: two records that sound like one
/// person, and voice recordings that don't sound like the rest of their person's. Answering
/// merges, marks them different, or removes the odd recording.
private struct LibraryIssues: View {
    @Bindable var controller: RecordingController

    var body: some View {
        ForEach(pairs, id: \.0) { a, b in
            VStack(alignment: .leading, spacing: 6) {
                Text(Wording.samePerson(a, b))
                HStack {
                    Button("Same Person") { controller.mergePeople(a, b) }
                    Button("Different People") { controller.markDifferent(a, b) }
                }
                .controlSize(.small)
            }
            .padding(.vertical, 4)
        }
        ForEach(unlike, id: \.person) { item in
            let person = controller.people.first { $0.name == item.person }
            VStack(alignment: .leading, spacing: 6) {
                Text(Wording.unlikeVoices(item.person, isOwner: person?.isOwner == true))
                ForEach(item.prints, id: \.self) { index in
                    let origin = person?.origin(ofPrint: index)
                    HStack {
                        Text(Wording.printOrigin(origin, number: index + 1, title: controller.recordingTitle(folder: origin?.recording)))
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Remove") { controller.removePrint(at: index, from: item.person) }.controlSize(.small)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var pairs: [(String, String)] {
        controller.libraryIssues.compactMap { if case .samePerson(let a, let b, _) = $0 { (a, b) } else { nil } }
    }

    private var unlike: [(person: String, prints: [Int])] {
        var grouped: [String: [Int]] = [:]
        for issue in controller.libraryIssues { if case .unlike(let person, let print) = issue { grouped[person, default: []].append(print) } }
        return grouped.keys.sorted().map { ($0, grouped[$0]!.sorted()) }
    }
}

/// Voices in and out as one file, so a team names each person once.
struct VoicesExchange: View {
    @Bindable var controller: RecordingController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Import…") { controller.importVoicesPanel() }
                Button("Export…") { controller.exportVoicesPanel() }
                    .disabled(controller.people.isEmpty)
            }
            .controlSize(.small)
            if let message = controller.voicesMessage {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.bar)
    }
}

