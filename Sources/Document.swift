import Foundation

/// Row IDs at or above this value denote rows added in the editor; below it,
/// the ID is the file data-row index. No real file can reach 2^40 rows.
let newRowIDBase = 1 << 40

/// Identifies a cell by stable row ID and logical column, so the "unsaved"
/// mark survives row/column reordering and insertions.
struct CellRef: Hashable {
    let rowID: Int
    let logical: Int
}

/// Editable CSV document: an immutable CSVTable plus a sparse edit overlay.
/// Cell edits, added/deleted rows and columns are all O(edit) in memory —
/// the file itself is never copied or rewritten until save.
///
/// All mutation happens on the main thread. performSave(to:) may run on a
/// background queue, but only while the UI blocks further edits.
final class CSVDocument {
    private(set) var table: CSVTable?
    var url: URL?
    var delimiter: UInt8 = 0x2C
    var hasHeader = true
    var isDirty = false

    /// Number of columns the underlying file has (logical columns 0..<fileColCount).
    private(set) var fileColCount = 0
    /// Display column -> logical column. Logical columns >= fileColCount were
    /// added in the editor and have no backing file data.
    private(set) var colMap: [Int] = []
    /// Logical column -> custom header name (renames and added-column names).
    var headerNames: [Int: String] = [:]
    private var nextLogicalCol = 0

    /// Display row -> row ID. nil means identity over file data rows (the
    /// common case: no rows added or removed yet).
    private(set) var rowIDs: [Int]? = nil
    private var nextNewRowID = newRowIDBase

    /// rowID -> (logical column -> value)
    private(set) var cellEdits: [Int: [Int: String]] = [:]

    /// Cells changed since the last save (or load). Highlighted in the UI and
    /// cleared on a successful save. Keyed by stable ID so the mark tracks the
    /// cell across row/column moves.
    private(set) var unsavedCells: Set<CellRef> = []

    private var headerOffset: Int { hasHeader ? 1 : 0 }

    var fileDataRowCount: Int {
        guard let t = table else { return 0 }
        return max(0, t.safeRowCount - headerOffset)
    }

    var rowCount: Int { rowIDs?.count ?? fileDataRowCount }
    var colCount: Int { colMap.count }

    // MARK: - Setup

    func attach(table: CSVTable, url: URL?) {
        self.table = table
        self.url = url
        delimiter = table.delimiter
        hasHeader = true
        fileColCount = 0
        colMap = []
        headerNames = [:]
        nextLogicalCol = 0
        rowIDs = nil
        nextNewRowID = newRowIDBase
        cellEdits = [:]
        unsavedCells = []
        isDirty = false
    }

    /// Determine the column layout from the first rows. Called once the first
    /// batch of row offsets has arrived.
    func setUpColumns() {
        guard let t = table, t.safeRowCount > 0 else { return }
        var maxCols = 0
        for r in 0..<min(100, t.safeRowCount) {
            maxCols = max(maxCols, t.fields(forRow: r).count)
        }
        fileColCount = maxCols
        colMap = Array(0..<maxCols)
        nextLogicalCol = maxCols
    }

    /// Blank document: a few empty columns and one empty row.
    func setUpEmpty(columns: Int = 3) {
        table = nil
        url = nil
        delimiter = 0x2C
        hasHeader = true
        fileColCount = 0
        colMap = []
        headerNames = [:]
        nextLogicalCol = 0
        rowIDs = nil
        nextNewRowID = newRowIDBase
        cellEdits = [:]
        unsavedCells = []
        for i in 0..<columns {
            colMap.append(nextLogicalCol)
            _ = i
            nextLogicalCol += 1
        }
        rowIDs = [makeRowID()]
        isDirty = false
    }

    // MARK: - Cell access

    func rowID(at row: Int) -> Int { rowIDs?[row] ?? row }

    func makeRowID() -> Int {
        defer { nextNewRowID += 1 }
        return nextNewRowID
    }

    private func materializeRowIDs() {
        if rowIDs == nil { rowIDs = Array(0..<fileDataRowCount) }
    }

    func value(row: Int, col: Int, useCache: Bool = true) -> String {
        guard col < colMap.count else { return "" }
        let id = rowID(at: row)
        let logical = colMap[col]
        if let edited = cellEdits[id]?[logical] { return edited }
        if id < newRowIDBase, logical < fileColCount, let t = table {
            let fields = t.fields(forRow: id + headerOffset, useCache: useCache)
            if logical < fields.count { return fields[logical] }
        }
        return ""
    }

    func setValue(_ value: String, row: Int, col: Int) {
        guard col < colMap.count else { return }
        cellEdits[rowID(at: row), default: [:]][colMap[col]] = value
        unsavedCells.insert(CellRef(rowID: rowID(at: row), logical: colMap[col]))
        isDirty = true
    }

    /// True if the cell at this display position has unsaved changes.
    func isCellUnsaved(row: Int, col: Int) -> Bool {
        guard col < colMap.count, !unsavedCells.isEmpty else { return false }
        return unsavedCells.contains(CellRef(rowID: rowID(at: row), logical: colMap[col]))
    }

    /// Clear all unsaved-change marks (the model now matches what is on disk).
    func clearUnsavedCells() { unsavedCells.removeAll() }

    // MARK: - Structure

    /// indices use final-position semantics (like NSTableView insertions):
    /// both arrays must be in ascending index order.
    func insertRows(ids: [Int], at indices: [Int]) {
        materializeRowIDs()
        for (k, idx) in indices.enumerated() {
            rowIDs!.insert(ids[k], at: idx)
        }
        isDirty = true
    }

    /// Returns the removed IDs in ascending-index order. Their cell edits are
    /// retained so an undo (re-insert) restores everything.
    @discardableResult
    func removeRows(at indices: [Int]) -> [Int] {
        materializeRowIDs()
        var removed: [Int] = []
        for idx in indices.sorted(by: >) {
            removed.append(rowIDs!.remove(at: idx))
        }
        isDirty = true
        return removed.reversed()
    }

    @discardableResult
    func addColumn(named name: String?, at displayIndex: Int) -> Int {
        let logical = nextLogicalCol
        nextLogicalCol += 1
        colMap.insert(logical, at: displayIndex)
        if let name, !name.isEmpty { headerNames[logical] = name }
        isDirty = true
        return logical
    }

    func insertColumns(logicals: [Int], at indices: [Int]) {
        for (k, idx) in indices.enumerated() {
            colMap.insert(logicals[k], at: idx)
        }
        isDirty = true
    }

    @discardableResult
    func removeColumns(at indices: [Int]) -> [Int] {
        var removed: [Int] = []
        for idx in indices.sorted(by: >) {
            removed.append(colMap.remove(at: idx))
        }
        isDirty = true
        return removed.reversed()
    }

    func headerTitle(col: Int) -> String {
        guard col < colMap.count else { return "" }
        let logical = colMap[col]
        if let name = headerNames[logical] { return name }
        if hasHeader, logical < fileColCount, let t = table, t.safeRowCount > 0 {
            let fields = t.fields(forRow: 0)
            if logical < fields.count { return fields[logical] }
        }
        return CSVDocument.letterName(col)
    }

    /// Spreadsheet-style column names: A, B, ..., Z, AA, AB, ...
    static func letterName(_ index: Int) -> String {
        var n = index
        var s = ""
        repeat {
            s = String(UnicodeScalar(UInt8(65 + n % 26))) + s
            n = n / 26 - 1
        } while n >= 0
        return s
    }

    // MARK: - Saving

    struct SaveError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Streams the document to disk (temp file + atomic replace). Rows that
    /// are untouched and whose column layout is unchanged are copied raw from
    /// the mapped file; everything else is re-encoded.
    func performSave(to target: URL) throws {
        let fm = FileManager.default
        let tmp = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).csvedit-\(getpid()).tmp")
        guard fm.createFile(atPath: tmp.path, contents: nil) else {
            throw SaveError(message: "Could not create a temporary file next to \(target.path)")
        }
        let fh = try FileHandle(forWritingTo: tmp)
        var open = true
        defer { if open { try? fh.close() } }

        var buf = Data(capacity: 1 << 22)
        let d = delimiter

        func flushIfNeeded(force: Bool = false) throws {
            if buf.count >= (1 << 22) || (force && !buf.isEmpty) {
                try fh.write(contentsOf: buf)
                buf.removeAll(keepingCapacity: true)
            }
        }
        func writeFields(_ values: [String]) throws {
            var line = ""
            for (i, v) in values.enumerated() {
                if i > 0 { line.unicodeScalars.append(UnicodeScalar(d)) }
                line += CSVDocument.encodeField(v, delimiter: d)
            }
            line += "\n"
            buf.append(contentsOf: Array(line.utf8))
            try flushIfNeeded()
        }

        if hasHeader {
            try writeFields((0..<colCount).map { headerTitle(col: $0) })
        }

        let fastPath = fileColCount > 0 && colMap == Array(0..<fileColCount)
        let count = rowCount
        let headerOff = headerOffset

        if let t = table {
            try t.data.withUnsafeBytes { (fileBuf: UnsafeRawBufferPointer) in
                let p = fileBuf.baseAddress?.assumingMemoryBound(to: UInt8.self)
                for r in 0..<count {
                    let id = rowID(at: r)
                    if fastPath, id < newRowIDBase, cellEdits[id] == nil, let p {
                        let range = t.byteRange(ofRow: id + headerOff)
                        buf.append(p + range.lowerBound, count: range.count)
                        buf.append(0x0A)
                        try flushIfNeeded()
                    } else {
                        try writeFields((0..<colCount).map { value(row: r, col: $0, useCache: false) })
                    }
                }
            }
        } else {
            for r in 0..<count {
                try writeFields((0..<colCount).map { value(row: r, col: $0, useCache: false) })
            }
        }

        try flushIfNeeded(force: true)
        try fh.close()
        open = false

        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: target)
        }
    }

    static func encodeField(_ s: String, delimiter d: UInt8) -> String {
        let needsQuoting = s.utf8.contains { $0 == d || $0 == 0x22 || $0 == 0x0A || $0 == 0x0D }
        guard needsQuoting else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
