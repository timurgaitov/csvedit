import Foundation

/// Read-only view of a CSV file on disk. The file is memory-mapped, never
/// loaded wholesale. Row boundaries are discovered by a quote-aware byte scan
/// (run on a background queue for the app, synchronously for tests); fields
/// are parsed lazily, per row, only when asked for.
final class CSVTable {
    let data: Data
    let delimiter: UInt8

    /// Byte offset of the start of each row. Appended on the main thread only
    /// (the app) or by the owning thread (tests).
    private(set) var rowStarts: [Int] = []
    private(set) var indexingComplete = false

    /// Called on the main thread as indexing progresses: (safeRowCount, done).
    var onProgress: ((Int, Bool) -> Void)?

    private var cache: [Int: [String]] = [:]

    init(url: URL) throws {
        data = try Data(contentsOf: url, options: [.alwaysMapped])
        delimiter = CSVTable.detectDelimiter(in: data)
    }

    init(data: Data, delimiter: UInt8) {
        self.data = data
        self.delimiter = delimiter
    }

    /// Rows that are safe to read right now. While indexing is in flight the
    /// last discovered row has no known end yet, so it is held back.
    var safeRowCount: Int {
        indexingComplete ? rowStarts.count : max(0, rowStarts.count - 1)
    }

    func startIndexing() {
        DispatchQueue.global(qos: .userInitiated).async {
            CSVTable.scanRowStarts(in: self.data) { batch, done in
                DispatchQueue.main.async {
                    self.rowStarts.append(contentsOf: batch)
                    if done { self.indexingComplete = true }
                    self.onProgress?(self.safeRowCount, done)
                }
            }
        }
    }

    func indexSynchronously() {
        CSVTable.scanRowStarts(in: data) { batch, done in
            rowStarts.append(contentsOf: batch)
            if done { indexingComplete = true }
        }
    }

    /// Quote-aware scan for record starts. Escaped quotes ("") toggle the
    /// in-quotes flag twice, so plain toggling is correct for boundaries.
    static func scanRowStarts(in data: Data, onBatch: ([Int], Bool) -> Void) {
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress, buf.count > 0 else {
                onBatch([], true)
                return
            }
            let p = base.assumingMemoryBound(to: UInt8.self)
            let n = buf.count
            var batch: [Int] = [0]
            batch.reserveCapacity(1 << 16)
            var inQuotes = false
            var i = 0
            while i < n {
                let b = p[i]
                if b == 0x22 {
                    inQuotes.toggle()
                } else if b == 0x0A && !inQuotes {
                    if i + 1 < n {
                        batch.append(i + 1)
                        if batch.count >= (1 << 16) {
                            onBatch(batch, false)
                            batch.removeAll(keepingCapacity: true)
                        }
                    }
                }
                i += 1
            }
            onBatch(batch, true)
        }
    }

    /// Byte range of a row's content, excluding the trailing \n / \r\n.
    func byteRange(ofRow row: Int) -> Range<Int> {
        let start = rowStarts[row]
        var end = row + 1 < rowStarts.count ? rowStarts[row + 1] : data.count
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            let p = base.assumingMemoryBound(to: UInt8.self)
            if end > start && p[end - 1] == 0x0A { end -= 1 }
            if end > start && p[end - 1] == 0x0D { end -= 1 }
        }
        return start..<end
    }

    /// Parsed fields of one row. The cache only serves the main thread;
    /// background work (saving) must pass useCache: false.
    func fields(forRow row: Int, useCache: Bool = true) -> [String] {
        if useCache, let cached = cache[row] { return cached }
        let parsed = parseFields(in: byteRange(ofRow: row))
        if useCache {
            if cache.count > 4096 { cache.removeAll(keepingCapacity: true) }
            cache[row] = parsed
        }
        return parsed
    }

    private func parseFields(in range: Range<Int>) -> [String] {
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> [String] in
            guard let base = buf.baseAddress else { return [""] }
            let p = base.assumingMemoryBound(to: UInt8.self)
            var fields: [String] = []
            var i = range.lowerBound
            let end = range.upperBound
            let d = delimiter
            while true {
                if i < end && p[i] == 0x22 {
                    var bytes: [UInt8] = []
                    i += 1
                    while i < end {
                        if p[i] == 0x22 {
                            if i + 1 < end && p[i + 1] == 0x22 {
                                bytes.append(0x22)
                                i += 2
                            } else {
                                i += 1
                                break
                            }
                        } else {
                            bytes.append(p[i])
                            i += 1
                        }
                    }
                    fields.append(String(decoding: bytes, as: UTF8.self))
                    while i < end && p[i] != d { i += 1 }
                } else {
                    let s = i
                    while i < end && p[i] != d { i += 1 }
                    fields.append(String(decoding: UnsafeBufferPointer(start: p + s, count: i - s), as: UTF8.self))
                }
                if i < end && p[i] == d { i += 1 } else { break }
            }
            return fields
        }
    }

    static func detectDelimiter(in data: Data) -> UInt8 {
        let candidates: [UInt8] = [0x2C, 0x3B, 0x09, 0x7C] // , ; tab |
        var counts = [Int](repeating: 0, count: candidates.count)
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            let p = base.assumingMemoryBound(to: UInt8.self)
            let n = min(buf.count, 1 << 16)
            var inQuotes = false
            var i = 0
            while i < n {
                let b = p[i]
                if b == 0x22 {
                    inQuotes.toggle()
                } else if b == 0x0A && !inQuotes {
                    break
                } else if !inQuotes, let idx = candidates.firstIndex(of: b) {
                    counts[idx] += 1
                }
                i += 1
            }
        }
        if let best = counts.indices.max(by: { counts[$0] < counts[$1] }), counts[best] > 0 {
            return candidates[best]
        }
        return 0x2C
    }
}
