import Foundation

/// A suspect word that passed every check. Apart from `review.json`, only `WordQuestions.select`
/// makes one, so its heard text has 1 to 4 tokens and occurs as whole tokens in its quote, the
/// quote was in the transcript that the CLI got, and the list did not know the heard text.
struct WordQuestion: Codable, Equatable, Sendable {
    /// As the quote writes it, so typing it back means "correct as heard".
    let heard: String
    let suggestion: String?
    let kind: WordKind
    let quote: String
    let reason: String?
    /// "Them at 00:12:31". Nil when no transcript line has the whole quote.
    let place: String?

    /// Matches a question with its answer.
    var key: String { Self.key(of: heard) }

    /// The tokens of the heard text, as the list compares forms, so "Convio", "convio", and
    /// "Convio," are one word. The answer files store the heard text, not this key, so a file from
    /// any version gets the same keys. A heard text without a token, which only a hand-written
    /// `review.json` can have, keeps its folded text.
    static func key(of heard: String) -> String {
        Phrase(heard)?.tokens.joined(separator: " ") ?? Phrase.fold(heard)
    }

    fileprivate init(_ suspect: SuspectWord, heard: String, place: String?) {
        self.heard = heard
        suggestion = suspect.suggestion
        kind = suspect.kind
        quote = suspect.quote
        reason = suspect.reason
        self.place = place
    }
}

enum WordQuestions {
    static let limit = 5
    static let maximumTokens = 4

    /// Keeps a suspect when its heard text has at most `maximumTokens` tokens and is whole tokens of
    /// its quote, the quote is in `transcript` (both folded with `Phrase.fold`), the list does not
    /// know the heard text, and no suspect kept before it has the same `WordQuestion.key`. Then the
    /// suspects whose suggestion is a right form of the list come first, then people, then the
    /// rest, each in the CLI's order, and the first `limit` stay. A question's heard text is the
    /// first match in its quote, with one space for each run of whitespace: the quote's spelling
    /// and case, without the punctuation that the CLI may have kept around the word.
    static func select(_ suspects: [SuspectWord], in transcript: String, knownWords: KnownWordsList) -> [WordQuestion] {
        let content = Phrase.fold(transcript)
        let rightForms = Set(knownWords.words.compactMap { Phrase($0.right)?.tokens })
        var keys: Set<String> = []
        let kept = suspects.compactMap { suspect -> (suspect: SuspectWord, heard: String)? in
            guard let heard = Phrase(suspect.heard), heard.tokens.count <= maximumTokens,
                  let match = PhraseMatcher([heard]).matches(in: suspect.quote).first,
                  content.contains(Phrase.fold(suspect.quote)),
                  !knownWords.knows(suspect.heard),
                  keys.insert(WordQuestion.key(of: suspect.heard)).inserted
            else { return nil }
            return (suspect, suspect.quote[match.range].split(whereSeparator: \.isWhitespace).joined(separator: " "))
        }
        func group(_ suspect: SuspectWord) -> Int {
            if let suggestion = suspect.suggestion.flatMap(Phrase.init), rightForms.contains(suggestion.tokens) { return 0 }
            return suspect.kind == .person ? 1 : 2
        }
        return kept.enumerated()
            .sorted { (group($0.element.suspect), $0.offset) < (group($1.element.suspect), $1.offset) }
            .prefix(limit)
            .map { WordQuestion($0.element.suspect, heard: $0.element.heard,
                                place: Transcript.place(of: $0.element.suspect.quote, in: transcript)) }
    }
}

enum WordAnswer: Equatable, Sendable {
    case rightWord(String)
    case correctAsHeard
    case skipped
}

/// One meeting's questions from `review.json` with the answers from `review-answers.json`. It is
/// read from disk each time and never stored.
struct WordReview: Equatable {
    let meeting: MeetingFolder
    /// Never empty: a meeting without questions has no review.
    let questions: [WordQuestion]
    /// By `WordQuestion.key`.
    let answers: [String: WordAnswer]
    /// By `WordQuestion.key`: the questions whose heard form the list knows now, for example from an
    /// answer in another meeting. They are not open, and they are not answers.
    let known: Set<String>

    /// In question order.
    var openQuestions: [WordQuestion] { questions.filter { answers[$0.key] == nil && !known.contains($0.key) } }
    var isFinished: Bool { openQuestions.isEmpty }
    /// At least one answer that is not Skip, so Update Notes can change something.
    var hasAnswers: Bool { questions.contains { answers[$0.key].map { $0 != .skipped } ?? false } }

    /// Done meetings whose review has open questions, oldest first.
    static func unfinished(in root: URL, knownWords: KnownWordsList) -> [WordReview] {
        unfinished(among: MeetingFolder.all(in: root), knownWords: knownWords)
    }

    /// The same for a listing that the caller already has from `MeetingFolder.all(in:)`.
    static func unfinished(among meetings: [(MeetingFolder, MeetingStage)], knownWords: KnownWordsList) -> [WordReview] {
        meetings
            .compactMap { meeting, stage in stage == .done ? meeting.wordReview(knownWords: knownWords) : nil }
            .filter { !$0.isFinished }
    }
}

extension MeetingFolder {
    /// Nil when the meeting has no questions, or `review.json` cannot be read. An answers file that
    /// cannot be read counts as no answers, and an entry that does not read or an answer without its
    /// question is left out. What `knownWords` knows is read here and never written, so a list line
    /// removed later opens its questions again.
    func wordReview(knownWords: KnownWordsList) -> WordReview? {
        guard let data = try? Data(contentsOf: url(for: .questions)),
              let questions = try? JSONDecoder().decode(StoredQuestions.self, from: data).questions,
              !questions.isEmpty
        else { return nil }
        let keys = Set(questions.map(\.key))
        var answers: [String: WordAnswer] = [:]
        for stored in storedAnswers() where keys.contains(WordQuestion.key(of: stored.heard)) {
            answers[WordQuestion.key(of: stored.heard)] = stored.answer
        }
        return WordReview(meeting: self, questions: questions, answers: answers,
                          known: Set(questions.filter { knownWords.knows($0.heard) }.map(\.key)))
    }

    /// For the summarize step only, before `summary.md`. Without questions it removes `review.json`,
    /// so a run never leaves the questions of an earlier run.
    func saveQuestions(_ questions: [WordQuestion]) throws {
        guard !questions.isEmpty else {
            let file = url(for: .questions)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            return
        }
        try write(Self.json(StoredQuestions(questions: questions)), to: .questions)
    }

    /// For the review window only, after `summary.md`. Replaces an earlier answer to the same
    /// question and keeps the other answers that read.
    func saveAnswer(_ answer: WordAnswer, to question: WordQuestion) throws {
        var answers = storedAnswers()
        let stored = StoredAnswer(heard: question.heard, answer: answer)
        if let index = answers.firstIndex(where: { WordQuestion.key(of: $0.heard) == question.key }) {
            answers[index] = stored
        } else {
            answers.append(stored)
        }
        try write(Self.json(StoredAnswers(answers: answers)), to: .answers)
    }

    private func storedAnswers() -> [StoredAnswer] {
        guard let data = try? Data(contentsOf: url(for: .answers)) else { return [] }
        return (try? JSONDecoder().decode(StoredAnswers.self, from: data).answers) ?? []
    }

    private static func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self) + "\n"
    }
}

private struct StoredQuestions: Codable {
    let questions: [WordQuestion]
}

private struct StoredAnswers: Codable {
    let answers: [StoredAnswer]

    init(answers: [StoredAnswer]) {
        self.answers = answers
    }

    /// Skips each entry that does not decode, so one broken entry, or one that a later version
    /// wrote, does not open every other question again.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        answers = try container.decode([Entry].self, forKey: .answers).compactMap(\.answer)
    }

    private struct Entry: Decodable {
        let answer: StoredAnswer?

        init(from decoder: Decoder) throws {
            answer = try? StoredAnswer(from: decoder)
        }
    }
}

/// {"heard": "Convio", "answer": "right word", "word": "Konvio"}, {"heard": "Aino", "answer":
/// "correct as heard"}, or {"heard": "QX", "answer": "skipped"}.
private struct StoredAnswer: Codable {
    let heard: String
    let answer: WordAnswer

    private enum CodingKeys: String, CodingKey {
        case heard, answer, word
    }

    private enum Kind: String, Codable {
        case rightWord = "right word"
        case correctAsHeard = "correct as heard"
        case skipped
    }

    init(heard: String, answer: WordAnswer) {
        self.heard = heard
        self.answer = answer
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        heard = try container.decode(String.self, forKey: .heard)
        switch try container.decode(Kind.self, forKey: .answer) {
        case .rightWord: answer = .rightWord(try container.decode(String.self, forKey: .word))
        case .correctAsHeard: answer = .correctAsHeard
        case .skipped: answer = .skipped
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(heard, forKey: .heard)
        switch answer {
        case .rightWord(let word):
            try container.encode(Kind.rightWord, forKey: .answer)
            try container.encode(word, forKey: .word)
        case .correctAsHeard:
            try container.encode(Kind.correctAsHeard, forKey: .answer)
        case .skipped:
            try container.encode(Kind.skipped, forKey: .answer)
        }
    }
}
