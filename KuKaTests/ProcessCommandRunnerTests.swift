import XCTest
@testable import KuKa

final class ProcessCommandRunnerTests: XCTestCase {
    private let runner = ProcessCommandRunner(home: URL(fileURLWithPath: "/Users/test", isDirectory: true))

    private func shell(_ script: String, timeout: Duration = .seconds(10)) async throws -> CommandResult {
        try await runner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], timeout: timeout)
    }

    func testExitStatusIsReported() async throws {
        let success = try await runner.run(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], timeout: .seconds(10))
        let failure = try await runner.run(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [], timeout: .seconds(10))

        XCTAssertEqual(success, CommandResult(termination: .exited(0), stdout: "", stderr: ""))
        XCTAssertEqual(failure, CommandResult(termination: .exited(1), stdout: "", stderr: ""))
    }

    func testStdoutAndStderrAreKeptApart() async throws {
        let result = try await shell("echo answer; echo problem >&2; exit 3")

        XCTAssertEqual(result, CommandResult(termination: .exited(3), stdout: "answer\n", stderr: "problem\n"))
    }

    func testOutputLargerThanAPipeBufferArrivesWhole() async throws {
        let result = try await shell("head -c 100000 /dev/zero | tr '\\0' a")

        XCTAssertEqual(result.termination, .exited(0))
        XCTAssertEqual(result.stdout, String(repeating: "a", count: 100_000))
    }

    func testAChildThatRunsTooLongIsStopped() async throws {
        let started = Date()

        let result = try await shell("sleep 10", timeout: .milliseconds(300))

        XCTAssertEqual(result.termination, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testTheChildGetsEndOfFileOnStdin() async throws {
        let result = try await runner.run(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], timeout: .seconds(5))

        XCTAssertEqual(result, CommandResult(termination: .exited(0), stdout: "", stderr: ""))
    }

    func testTheChildRunsInAnEmptyFolderWithTheUserToolsOnItsPath() async throws {
        let result = try await shell("ls -A | wc -l | tr -d ' '; echo \"$PATH\"")

        XCTAssertEqual(result.stdout, "0\n/opt/homebrew/bin:/usr/local/bin:/Users/test/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin\n")
    }

    func testAMissingExecutableThrows() async {
        do {
            _ = try await runner.run(executable: URL(fileURLWithPath: "/nonexistent/agy"), arguments: [], timeout: .seconds(5))
            XCTFail("expected a launch error")
        } catch {
            XCTAssertEqual((error as? CocoaError)?.code, .fileNoSuchFile, "\(error)")
        }
    }

    func testCancellingTheCallerStopsTheChild() async throws {
        let marker = try makeTemporaryDirectory().appendingPathComponent("finished")
        let run = Task {
            try await self.shell("sleep 1; touch '\(marker.path)'", timeout: .seconds(60))
        }
        try await Task.sleep(for: .milliseconds(300))

        run.cancel()

        do {
            _ = try await run.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "the child kept running after cancellation")
    }
}
