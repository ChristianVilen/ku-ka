import Foundation
import Darwin

protocol LogReading: Sendable {
    func rows(in interval: DateInterval?) async throws -> [LogRow]
}

extension LogReading {
    @concurrent
    func filteredRows(using filter: LogFilter, now: Date, launchDate: Date,
                      processID: Int32, calendar: Calendar) async throws -> [LogRow] {
        try Task.checkCancellation()
        let rows = try await rows(in: filter.range.interval(now: now, launchDate: launchDate, calendar: calendar))
        try Task.checkCancellation()
        return filter.rows(rows, now: now, launchDate: launchDate, processID: processID, calendar: calendar)
    }
}

actor LogFileReader: LogReading {
    private let folder: URL
    private let timeZone: TimeZone
    private let load: @Sendable (URL) throws -> Data
    private var cache: [URL: CachedFile] = [:]

    init(folder: URL, timeZone: TimeZone = .current,
         load: @escaping @Sendable (URL) throws -> Data = { try LogFileReader.readFile($0) }) {
        self.folder = folder
        self.timeZone = timeZone
        self.load = load
    }

    func rows(in interval: DateInterval?) throws -> [LogRow] {
        try Task.checkCancellation()
        let urls: [URL]
        do { urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) }
        catch CocoaError.fileReadNoSuchFile { cache.removeAll(); return [] }
        var current: [URL: CachedFile] = [:]
        var result: [LogRow] = []
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            try Task.checkCancellation()
            guard let day = LogFiles.day(of: url.lastPathComponent, timeZone: timeZone),
                  interval.map({ day >= $0.start && day < $0.end }) ?? true else { continue }
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                if errno == ENOENT { continue }
                throw Self.systemError()
            }
            guard info.st_mode & S_IFMT == S_IFREG else { continue }
            let stamp = Stamp(size: info.st_size, seconds: info.st_mtimespec.tv_sec,
                              nanoseconds: info.st_mtimespec.tv_nsec, inode: info.st_ino)
            let entry: CachedFile
            if let cached = cache[url], cached.stamp == stamp {
                entry = cached
            } else {
                let data: Data
                do { data = try load(url) }
                catch let error as POSIXError where error.code == .ENOENT { continue }
                let text = String(decoding: data, as: UTF8.self)
                var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
                if lines.last == "" { lines.removeLast() }
                entry = CachedFile(stamp: stamp, rows: lines.map { LogRow(text: $0, day: day) })
            }
            current[url] = entry
            result.append(contentsOf: entry.rows)
        }
        cache = current
        return result
    }

    private struct Stamp: Equatable {
        let size: Int64
        let seconds: Int
        let nanoseconds: Int
        let inode: UInt64
    }

    private struct CachedFile {
        let stamp: Stamp
        let rows: [LogRow]
    }

    private static func readFile(_ url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw systemError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw systemError() }
        guard info.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EINVAL) }
        var remaining = info.st_size
        var data = Data()
        while remaining > 0 {
            try Task.checkCancellation()
            guard let part = try handle.read(upToCount: Int(min(remaining, 65_536))), !part.isEmpty else { break }
            data.append(part)
            remaining -= Int64(part.count)
        }
        return data
    }

    private static func systemError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
