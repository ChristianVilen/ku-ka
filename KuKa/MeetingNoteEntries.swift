import Foundation

enum MeetingNoteTime: Equatable, Codable {
    case recording(TimeInterval)
    case afterRecording
    case undated
}

struct MeetingNoteEntry: Identifiable, Equatable, Codable {
    let id: UUID
    var time: MeetingNoteTime
    var text: String
    var attachments: [String]

    init(id: UUID = UUID(), time: MeetingNoteTime, text: String = "", attachments: [String] = []) {
        self.id = id
        self.time = time
        self.text = text
        self.attachments = attachments
    }
}

enum MeetingNoteDocument {
    private static let header = "<!-- Ku-Ka notes v2 -->\n"
    private static let marker = "<!-- Ku-Ka row "
    private struct Metadata: Codable {
        let id: UUID
        let time: MeetingNoteTime
        let attachments: [String]
    }

    static func parse(_ text: String) -> [MeetingNoteEntry] {
        func legacy() -> [MeetingNoteEntry] {
            text.isEmpty ? [] : [MeetingNoteEntry(time: .undated, text: text)]
        }
        guard text.hasPrefix(header) else { return legacy() }
        let content = String(text.dropFirst(header.count))
        guard content.hasPrefix(marker) else { return legacy() }
        let chunks = String(content.dropFirst(marker.count)).components(separatedBy: "\n" + marker)
        var entries: [MeetingNoteEntry] = []
        for (index, chunk) in chunks.enumerated() {
            guard let end = chunk.range(of: " -->\n"),
                  let data = Data(base64Encoded: String(chunk[..<end.lowerBound])),
                  let metadata = try? JSONDecoder().decode(Metadata.self, from: data),
                  metadata.attachments.allSatisfy({ name in
                      name.hasSuffix(".png") && UUID(uuidString: String(name.dropLast(4))) != nil
                  }) else { return legacy() }
            if case .recording(let time) = metadata.time, !time.isFinite || time < 0 { return legacy() }
            let body = String(chunk[end.upperBound...]) + (index < chunks.count - 1 ? "\n" : "")
            guard let textStart = body.range(of: "\n\n"),
                  let textEnd = body.range(of: "\n<!-- Ku-Ka end -->\n", options: .backwards),
                  textStart.upperBound <= textEnd.lowerBound else { return legacy() }
            let content = String(body[textStart.upperBound..<textEnd.lowerBound])
            let lines = content.components(separatedBy: "\n")
            guard lines.allSatisfy({ $0.hasPrefix("    ") }) else { return legacy() }
            let entryText = lines.map { String($0.dropFirst(4)) }.joined(separator: "\n")
            entries.append(MeetingNoteEntry(id: metadata.id, time: metadata.time, text: entryText, attachments: metadata.attachments))
        }
        guard Set(entries.map(\.id)).count == entries.count else { return legacy() }
        return render(entries) == text ? entries : legacy()
    }

    static func render(_ entries: [MeetingNoteEntry]) -> String {
        let entries = entries.filter { !$0.text.isEmpty || !$0.attachments.isEmpty }
        guard !entries.isEmpty else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let rows = entries.compactMap { entry -> String? in
            guard let data = try? encoder.encode(Metadata(id: entry.id, time: entry.time, attachments: entry.attachments)) else { return nil }
            let label: String
            switch entry.time {
            case .recording(let time): label = RecordedTime.format(time)
            case .afterRecording: label = "After recording"
            case .undated: label = "Undated"
            }
            let lines = entry.text.components(separatedBy: "\n").map { "    " + $0 }.joined(separator: "\n")
            let images = entry.attachments.map { "\n![Screenshot](attachments/\($0))" }.joined()
            return marker + data.base64EncodedString() + " -->\n**\(label)**\(images)\n\n" + lines + "\n<!-- Ku-Ka end -->\n"
        }
        return header + rows.joined()
    }
}
