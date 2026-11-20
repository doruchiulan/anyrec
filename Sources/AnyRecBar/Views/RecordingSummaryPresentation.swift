import AnyRecKit

struct RecordingSummaryPresentation {
    let original: Summary
    let named: Summary
    let markdown: String
    let staleNotice: String?

    init(_ original: Summary, transcript: Transcript?, names: [String: String]) {
        self.original = original
        named = original.named(names)
        markdown = named.markdown
        staleNotice = transcript.flatMap { Wording.summaryStale(original.staleness(of: $0, names: names)) }
    }
}
