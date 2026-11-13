import Foundation

extension MeetingReader {
    public func list(filter: MeetingFilter = .init(), offset: Int = 0, limit: Int = 25) throws -> MeetingPage<MeetingDetails> {
        try validatePage(offset: offset, limit: limit)
        var matches: [MeetingDetails] = []
        var skipped = 0
        for directory in try directories() {
            try Task.checkCancellation()
            let meeting = try snapshot(directory.lastPathComponent).details
            guard filter.matches(meeting) else { continue }
            if skipped < offset { skipped += 1; continue }
            if matches.count == limit { return MeetingPage(items: matches, nextOffset: offset + matches.count) }
            matches.append(meeting)
        }
        return MeetingPage(items: matches, nextOffset: nil)
    }

    public func meeting(_ id: String) throws -> MeetingDetails { try snapshot(id).details }

    public func participants(_ id: String) throws -> MeetingParticipants { try snapshot(id).participants }

    public func summary(_ id: String) throws -> MeetingSummary {
        let data = try snapshot(id)
        return MeetingSummary(meetingID: id, generation: data.generation, summary: data.summary,
                              markdown: data.summaryMarkdown, warnings: data.warnings)
    }

    public func transcript(
        _ id: String, offset: Int = 0, limit: Int = 100, start: Double? = nil, end: Double? = nil
    ) throws -> MeetingTranscript {
        try validatePage(offset: offset, limit: limit, maximum: 200)
        guard start.map({ $0.isFinite && $0 >= 0 }) ?? true, end.map({ $0.isFinite && $0 >= 0 }) ?? true,
              start == nil || end == nil || start! < end! else {
            throw MeetingReadError.invalid("Use nonnegative seconds with start less than end.")
        }
        let data = try snapshot(id)
        guard let transcript = data.transcript else {
            throw MeetingReadError.unavailable("No readable transcript is available for this meeting.")
        }
        let filtered = transcript.utterances.enumerated().filter { _, line in
            (start.map { line.end > $0 } ?? true) && (end.map { line.start < $0 } ?? true)
        }
        let lines = filtered.dropFirst(offset).prefix(limit).map { index, line in
            MeetingTranscript.Line(index: index, start: line.start, end: line.end,
                                   speaker: line.speaker.label, speakerName: data.name(for: line.speaker), text: line.text)
        }
        let next = offset < filtered.count && lines.count < filtered.count - offset ? offset + lines.count : nil
        return MeetingTranscript(meetingID: id, generation: data.generation, engine: transcript.engine,
            language: transcript.language, notes: transcript.notes, lines: lines, nextOffset: next, warnings: data.warnings)
    }

    public func search(
        _ query: String, scope: String = "all", filter: MeetingFilter = .init(),
        offset: Int = 0, limit: Int = 25
    ) throws -> MeetingPage<MeetingSearchHit> {
        try validatePage(offset: offset, limit: limit)
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 500,
              ["all", "title", "transcript", "participants", "summary"].contains(scope) else {
            throw MeetingReadError.invalid("Supply a query of 1–500 characters and a supported search scope.")
        }
        var hits: [MeetingSearchHit] = []
        var warnings: [String] = []
        var skipped = 0
        for directory in try directories() {
            try Task.checkCancellation()
            let data = try snapshot(directory.lastPathComponent)
            warnings += data.warnings.map { "\(directory.lastPathComponent): \($0)" }
            guard filter.matches(data.details) else { continue }
            for hit in data.hits(query: query, scope: scope) {
                if skipped < offset { skipped += 1; continue }
                if hits.count == limit { return MeetingPage(items: hits, nextOffset: offset + hits.count, warnings: warnings) }
                hits.append(hit)
            }
        }
        return MeetingPage(items: hits, nextOffset: nil, warnings: warnings)
    }

    private func validatePage(offset: Int, limit: Int, maximum: Int = 100) throws {
        guard offset >= 0, (1...maximum).contains(limit) else {
            throw MeetingReadError.invalid("offset must be nonnegative; limit must be between 1 and \(maximum).")
        }
    }
}

extension MeetingSnapshot {
    func name(for speaker: Speaker) -> String? {
        switch speaker {
        case .voice(let letter): voices?.names[letter]
        case .named(let name): name
        default: nil
        }
    }

    func hits(query: String, scope: String) -> [MeetingSearchHit] {
        var hits: [MeetingSearchHit] = []
        let meeting = details
        let fields = [("title", meeting.title), ("participants", participants.names.joined(separator: ", ")),
                      ("summary", summary?.markdown ?? summaryMarkdown ?? "")]
        for (field, text) in fields where scope == "all" || scope == field {
            if text.meetingContains(query) {
                hits.append(MeetingSearchHit(meetingID: meeting.id, title: meeting.title, field: field,
                    excerpt: excerpt(text, query: query), start: nil, end: nil, speaker: nil, lineIndex: nil))
            }
        }
        if scope == "all" || scope == "transcript" {
            for (index, line) in (transcript?.utterances ?? []).enumerated() where line.text.meetingContains(query) {
                hits.append(MeetingSearchHit(meetingID: meeting.id, title: meeting.title, field: "transcript",
                    excerpt: excerpt(line.text, query: query), start: line.start, end: line.end,
                    speaker: name(for: line.speaker) ?? line.speaker.label, lineIndex: index))
            }
        }
        return hits
    }

    private func excerpt(_ text: String, query: String) -> String {
        guard let match = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                                     locale: Locale(identifier: "en_US_POSIX")) else { return String(text.prefix(400)) }
        let start = text.index(match.lowerBound, offsetBy: -100, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(start, offsetBy: 400, limitedBy: text.endIndex) ?? text.endIndex
        return (start > text.startIndex ? "…" : "") + String(text[start..<end]) + (end < text.endIndex ? "…" : "")
    }
}
