import Foundation
import AnyRecKit

/// The catalogue as a pickable list: section titles drawn as headers, and the way
/// back from the row that was picked to what it stood for.
struct CapturePicker {
    let items: [PickerItem]
    private let choices: [Int: CaptureChoice]

    init(_ catalogue: CaptureCatalogue) {
        var items: [PickerItem] = []
        var choices: [Int: CaptureChoice] = [:]

        for section in catalogue.sections {
            items.append(.header(section.title))
            for entry in section.entries {
                choices[items.count] = entry.choice
                items.append(PickerItem(label: entry.choice.label, detail: entry.detail))
            }
        }

        self.items = items
        self.choices = choices
    }

    func index(of choice: CaptureChoice?) -> Int? {
        guard let choice else { return nil }
        return choices.first { $0.value.target == choice.target }?.key
    }

    func choice(at index: Int) -> CaptureChoice? { choices[index] }
}
