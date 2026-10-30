import Foundation
import Darwin

// The queue owns cleanedDay and all file access; callbacks must be safe to send to it.
final class LogFiles: @unchecked Sendable {
    private let folder: URL
    private let clock: @Sendable () -> Date
    private let calendar: Calendar
    private let onFailure: @Sendable (Error) -> Void
    private let queue = DispatchQueue(label: "com.kuka.screenshot.log-files", qos: .utility)
    private var cleanedDay: Date?

    init(folder: URL, clock: @escaping @Sendable () -> Date = { Date() },
         calendar: Calendar = .current, onFailure: @escaping @Sendable (Error) -> Void) {
        self.folder = folder
        self.clock = clock
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        self.calendar = gregorian
        self.onFailure = onFailure
        queue.async {
            do {
                try self.prepareFolder()
                try self.cleanIfNeeded()
            } catch { self.onFailure(error) }
        }
    }

    func append(_ line: LogLine) {
        queue.async {
            do {
                try self.prepareFolder()
                try self.cleanIfNeeded()
                try self.write(line)
            } catch { self.onFailure(error) }
        }
    }

    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    func deleteAll() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    for file in try self.ownedFiles() { try self.remove(file.url) }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    static func name(for date: Date, timeZone: TimeZone) -> String {
        "Ku-Ka-\(dayFormatter(timeZone: timeZone).string(from: date)).log"
    }

    static func day(of name: String, timeZone: TimeZone) -> Date? {
        guard let match = name.wholeMatch(of: #/Ku-Ka-([0-9]{4}-[0-9]{2}-[0-9]{2})\.log/#) else { return nil }
        let text = String(match.1)
        let formatter = dayFormatter(timeZone: timeZone)
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return date
    }

    private static func dayFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }

    private func prepareFolder() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(folder.path, &info) == 0 else { throw POSIXError.current }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw POSIXError(.ENOTDIR) }
        guard chmod(folder.path, 0o700) == 0 else { throw POSIXError.current }
    }

    private func write(_ line: LogLine) throws {
        let url = folder.appendingPathComponent(Self.name(for: line.date, timeZone: line.timeZone))
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw POSIXError.current }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw POSIXError.current }
        guard info.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EINVAL) }
        guard fchmod(descriptor, 0o600) == 0 else { throw POSIXError.current }
        let data = Data((line.formatted + "\n").utf8)
        let count = data.withUnsafeBytes { bytes in
            var result: Int
            repeat { result = Darwin.write(descriptor, bytes.baseAddress!, bytes.count) }
            while result == -1 && errno == EINTR
            return result
        }
        guard count >= 0 else { throw POSIXError.current }
        guard count == data.count else { throw POSIXError(.EIO) }
    }

    private func cleanIfNeeded() throws {
        let today = calendar.startOfDay(for: clock())
        guard cleanedDay != today else { return }
        let oldestDay = calendar.date(byAdding: .day, value: -14, to: today)!
        var kept: [File] = []
        for file in try ownedFiles() {
            if file.day < oldestDay { try remove(file.url) }
            else { kept.append(file) }
        }
        var size = kept.reduce(Int64(0)) { $0 + $1.size }
        for file in kept.sorted(by: { $0.day < $1.day }) where size > 20_000_000 && file.day != today {
            try remove(file.url)
            size -= file.size
        }
        cleanedDay = today
    }

    private struct File {
        let url: URL
        let day: Date
        let size: Int64
    }

    private func ownedFiles() throws -> [File] {
        let urls: [URL]
        do { urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) }
        catch CocoaError.fileReadNoSuchFile { return [] }
        return try urls.compactMap { url in
            guard let day = Self.day(of: url.lastPathComponent, timeZone: calendar.timeZone) else { return nil }
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                if errno == ENOENT { return nil }
                throw POSIXError.current
            }
            guard info.st_mode & S_IFMT == S_IFREG else { return nil }
            return File(url: url, day: day, size: info.st_size)
        }
    }

    private func remove(_ url: URL) throws {
        if unlink(url.path) != 0 && errno != ENOENT { throw POSIXError.current }
    }
}

private extension POSIXError {
    static var current: POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
