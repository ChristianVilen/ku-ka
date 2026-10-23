import Foundation

/// Case order is the order the CLIs are tried (`Summarizer` iterates
/// `allCases`), so the preferred CLI must stay first.
enum SummaryCLI: String, CaseIterable {
    case antigravity = "agy"
    case claude = "claude"

    /// A GUI app does not get the user's shell PATH.
    func candidatePaths(home: URL) -> [String] {
        Self.userToolDirectories(home: home).map { "\($0)/\(rawValue)" }
    }

    static func userToolDirectories(home: URL) -> [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", home.appendingPathComponent(".local/bin").path]
    }

    /// agy reads anything after -p as the prompt, so its flags must come
    /// first (measured).
    func arguments(prompt: String) -> [String] {
        switch self {
        case .antigravity: return ["--disable-slash-commands", "-p", prompt]
        case .claude: return ["-p", "--tools", "", "--no-session-persistence", "--strict-mcp-config", prompt]
        }
    }
}

struct CommandResult: Equatable {
    enum Termination: Equatable {
        case exited(Int32)
        case timedOut
    }
    let termination: Termination
    let stdout: String
    let stderr: String
}

protocol CommandRunning {
    func run(executable: URL, arguments: [String], timeout: Duration) async throws -> CommandResult
}

final class ProcessCommandRunner: CommandRunning {
    private let home: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    func run(executable: URL, arguments: [String], timeout: Duration) async throws -> CommandResult {
        let fileManager = FileManager.default
        let runFolder = fileManager.temporaryDirectory
            .appendingPathComponent("ku-ka-summary-\(UUID().uuidString)", isDirectory: true)
        let emptyWorkingDirectory = runFolder.appendingPathComponent("work", isDirectory: true)
        try fileManager.createDirectory(at: emptyWorkingDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: runFolder) }
        let stdoutURL = runFolder.appendingPathComponent("stdout")
        let stderrURL = runFolder.appendingPathComponent("stderr")

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        // Files, not pipes: a pipe holds 64 KB, and a child that fills it
        // blocks until someone reads, so pipes would need reading while the
        // child runs.
        let stdoutFile = try Self.emptyFile(at: stdoutURL)
        let stderrFile = try Self.emptyFile(at: stderrURL)
        defer {
            try? stdoutFile.close()
            try? stderrFile.close()
        }
        process.standardOutput = stdoutFile
        process.standardError = stderrFile
        process.currentDirectoryURL = emptyWorkingDirectory
        let path = (SummaryCLI.userToolDirectories(home: home) + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
            .joined(separator: ":")
        process.environment = ProcessInfo.processInfo.environment.merging(["PATH": path]) { $1 }
        let (exits, exited) = AsyncStream<Void>.makeStream()
        process.terminationHandler = { _ in exited.finish() }

        try Task.checkCancellation()
        try process.run()
        let timer = Task {
            do { try await Task.sleep(for: timeout) } catch { return false }
            process.terminate()
            return true
        }
        await withTaskCancellationHandler {
            for await _ in exits {}
        } onCancel: {
            process.terminate()
        }
        timer.cancel()
        try Task.checkCancellation()

        let termination: CommandResult.Termination = await timer.value ? .timedOut : .exited(process.terminationStatus)
        return CommandResult(termination: termination,
                             stdout: String(decoding: try Data(contentsOf: stdoutURL), as: UTF8.self),
                             stderr: String(decoding: try Data(contentsOf: stderrURL), as: UTF8.self))
    }

    private static func emptyFile(at url: URL) throws -> FileHandle {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try FileHandle(forWritingTo: url)
    }
}

struct SummaryFailure: Equatable, CustomStringConvertible {
    enum Reason: Equatable {
        case notInstalled(searched: [String])
        case couldNotLaunch(String)
        case exited(status: Int32, stderrTail: String)
        case timedOut
        case emptyOutput
    }
    let cli: SummaryCLI
    let reason: Reason

    var description: String {
        let name = cli.rawValue
        switch reason {
        case .notInstalled(let searched):
            return "\(name) was not found at \(searched.joined(separator: ", "))"
        case .couldNotLaunch(let message):
            return "\(name) could not start: \(message)"
        case .exited(let status, let stderrTail):
            let detail = stderrTail.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return detail.isEmpty ? "\(name) exited with status \(status)" : "\(name) exited with status \(status): \(detail)"
        case .timedOut:
            return "\(name) took too long and was stopped"
        case .emptyOutput:
            return "\(name) exited without writing a summary"
        }
    }
}

enum SummaryResult: Equatable {
    case written(markdown: String, by: SummaryCLI, after: [SummaryFailure])
    case failed([SummaryFailure])
}

struct Summarizer {
    private let runner: CommandRunning
    private let home: URL
    private let isExecutable: (String) -> Bool
    private let timeout: Duration

    init(runner: CommandRunning = ProcessCommandRunner(),
         home: URL = FileManager.default.homeDirectoryForCurrentUser,
         isExecutable: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
         timeout: Duration = .seconds(600)) {
        self.runner = runner
        self.home = home
        self.isExecutable = isExecutable
        self.timeout = timeout
    }

    func summarize(transcript: String) async -> SummaryResult {
        let prompt = SummaryPrompt.make(transcript: transcript)
        var failures: [SummaryFailure] = []
        for cli in SummaryCLI.allCases {
            if Task.isCancelled { break }
            let searched = cli.candidatePaths(home: home)
            guard let path = searched.first(where: isExecutable) else {
                failures.append(SummaryFailure(cli: cli, reason: .notInstalled(searched: searched)))
                continue
            }
            let reason: SummaryFailure.Reason
            do {
                let result = try await runner.run(executable: URL(fileURLWithPath: path),
                                                  arguments: cli.arguments(prompt: prompt), timeout: timeout)
                switch result.termination {
                case .exited(0) where !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                    return .written(markdown: result.stdout, by: cli, after: failures)
                case .exited(0): reason = .emptyOutput
                case .exited(let status): reason = .exited(status: status, stderrTail: String(result.stderr.suffix(300)))
                case .timedOut: reason = .timedOut
                }
            } catch {
                reason = .couldNotLaunch(error.localizedDescription)
            }
            failures.append(SummaryFailure(cli: cli, reason: reason))
        }
        return .failed(failures)
    }
}

enum SummaryPrompt {
    static func make(transcript: String) -> String {
        """
        You are writing meeting notes from the transcript below. "Me" is the person who \
        recorded the meeting. "Them" is everyone else on the call, and the transcript does \
        not tell those people apart. A "Me" line can sometimes repeat a "Them" line because of echo.

        Write Markdown with exactly these sections:
        ## Summary
        Three to five sentences.
        ## Decisions
        A bullet list. Write "None recorded." if there are none.
        ## Action items
        A checklist in the form "- [ ] Owner: task". The owner is Me, Them, or a name said in the meeting.
        ## Key points
        A bullet list.

        Use only what the transcript says. Do not invent names, dates, or numbers. \
        Reply with the Markdown only.

        Transcript:

        \(transcript)
        """
    }
}

enum SummaryDocument {
    static func markdown(title: String, body: String, by cli: SummaryCLI, after failures: [SummaryFailure]) -> String {
        let text = "# \(title)\n\n\(body.trimmingCharacters(in: .whitespacesAndNewlines))\n\n---\n\n"
        guard !failures.isEmpty else { return text + "Summary by `\(cli.rawValue)`.\n" }
        return text + "Summary by `\(cli.rawValue)`. Tried first:\n\n" + failures.map { "- \($0)\n" }.joined()
    }
}
