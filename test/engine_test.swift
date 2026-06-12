import Foundation

// Correctness and performance checks for the CSV engine (CSVTable + CSVDocument).
// Compiled together with Sources/CSVTable.swift and Sources/Document.swift only.

var failures = 0

func expect(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok: \(message)")
    } else {
        failures += 1
        print("  FAIL: \(message)")
    }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: String) {
    if a == b {
        print("  ok: \(message)")
    } else {
        failures += 1
        print("  FAIL: \(message) — got \(a), expected \(b)")
    }
}

func table(from text: String) -> CSVTable {
    let t = CSVTable(data: Data(text.utf8), delimiter: CSVTable.detectDelimiter(in: Data(text.utf8)))
    t.indexSynchronously()
    return t
}

// MARK: - Parsing

print("parsing:")
do {
    let t = table(from: "a,b,c\n1,2,3\n")
    expectEqual(t.safeRowCount, 2, "simple file row count")
    expectEqual(t.fields(forRow: 0), ["a", "b", "c"], "header fields")
    expectEqual(t.fields(forRow: 1), ["1", "2", "3"], "data fields")
}
do {
    let t = table(from: "a,b\r\n\"x,y\",\"he said \"\"hi\"\"\"\r\n\"multi\nline\",2\r\nlast,row")
    expectEqual(t.safeRowCount, 4, "CRLF + quoted newline row count")
    expectEqual(t.fields(forRow: 1), ["x,y", "he said \"hi\""], "quoted comma and escaped quotes")
    expectEqual(t.fields(forRow: 2), ["multi\nline", "2"], "newline inside quoted field")
    expectEqual(t.fields(forRow: 3), ["last", "row"], "no trailing newline")
}
do {
    let t = table(from: "a,,c\n,,\ntrailing,\n")
    expectEqual(t.fields(forRow: 0), ["a", "", "c"], "empty middle field")
    expectEqual(t.fields(forRow: 1), ["", "", ""], "all empty fields")
    expectEqual(t.fields(forRow: 2), ["trailing", ""], "trailing empty field")
}
do {
    // Quote after a space still opens a quoted field (Excel-style leniency);
    // unquoted fields keep their leading spaces.
    let t = table(from: "a,b,c\nv1, \"x, y, z\", v3\np, q, r\n")
    expectEqual(t.fields(forRow: 1), ["v1", "x, y, z", " v3"], "space before opening quote")
    expectEqual(t.fields(forRow: 2), ["p", " q", " r"], "unquoted fields keep leading spaces")
}
do {
    expectEqual(CSVTable.detectDelimiter(in: Data("a;b;c\n1;2;3\n".utf8)), 0x3B, "semicolon detection")
    expectEqual(CSVTable.detectDelimiter(in: Data("a\tb\tc\n".utf8)), 0x09, "tab detection")
    expectEqual(CSVTable.detectDelimiter(in: Data("\"a;b\",c\n".utf8)), 0x2C, "quoted delimiters ignored")
}

// MARK: - Document round trip

print("document edit + save:")
let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("csvedit-test-\(getpid())")
try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmpDir) }

func roundTrip(_ doc: CSVDocument, name: String) throws -> CSVTable {
    let url = tmpDir.appendingPathComponent(name)
    try doc.performSave(to: url)
    let t = try CSVTable(url: url)
    t.indexSynchronously()
    return t
}

do {
    // Unedited fast-path save preserves content (modulo \r\n -> \n).
    let src = tmpDir.appendingPathComponent("src.csv")
    try Data("name,qty\r\nwidget,2\r\n\"a,b\",3\r\n".utf8).write(to: src)
    let t = try CSVTable(url: src)
    t.indexSynchronously()
    let doc = CSVDocument()
    doc.attach(table: t, url: src)
    doc.setUpColumns()
    expectEqual(doc.rowCount, 2, "data row count with header")
    expectEqual(doc.colCount, 2, "column count")
    expectEqual(doc.value(row: 1, col: 0), "a,b", "quoted value read")

    let saved = try roundTrip(doc, name: "untouched.csv")
    expectEqual(saved.safeRowCount, 3, "untouched save keeps all rows")
    expectEqual(saved.fields(forRow: 0), ["name", "qty"], "untouched save keeps header")
    expectEqual(saved.fields(forRow: 2), ["a,b", "3"], "untouched save keeps quoting")

    // Cell edit, row ops, column ops.
    doc.setValue("gadget, deluxe", row: 0, col: 0)
    doc.insertRows(ids: [doc.makeRowID()], at: [2])
    doc.setValue("new", row: 2, col: 0)
    _ = doc.addColumn(named: "note", at: 2)
    doc.setValue("hello \"world\"", row: 0, col: 2)
    doc.removeRows(at: [1])

    let saved2 = try roundTrip(doc, name: "edited.csv")
    expectEqual(saved2.safeRowCount, 3, "edited save row count (header + 2 data)")
    expectEqual(saved2.fields(forRow: 0), ["name", "qty", "note"], "edited header with added column")
    expectEqual(saved2.fields(forRow: 1), ["gadget, deluxe", "2", "hello \"world\""], "edited row re-encoded")
    expectEqual(saved2.fields(forRow: 2), ["new", "", ""], "inserted row saved")
}

do {
    // Column delete + rename, no-header mode.
    let src = tmpDir.appendingPathComponent("src2.csv")
    try Data("1,2,3\n4,5,6\n".utf8).write(to: src)
    let t = try CSVTable(url: src)
    t.indexSynchronously()
    let doc = CSVDocument()
    doc.attach(table: t, url: src)
    doc.hasHeader = false
    doc.setUpColumns()
    expectEqual(doc.rowCount, 2, "no-header row count")
    doc.removeColumns(at: [1])
    let saved = try roundTrip(doc, name: "dropcol.csv")
    expectEqual(saved.fields(forRow: 0), ["1", "3"], "deleted column gone, no header written")
    expectEqual(saved.safeRowCount, 2, "no-header save row count")
}

do {
    // Blank document built from scratch.
    let doc = CSVDocument()
    doc.setUpEmpty(columns: 2)
    doc.headerNames[doc.colMap[0]] = "id"
    doc.headerNames[doc.colMap[1]] = "name"
    doc.setValue("1", row: 0, col: 0)
    doc.setValue("Ada", row: 0, col: 1)
    doc.insertRows(ids: [doc.makeRowID()], at: [1])
    doc.setValue("2", row: 1, col: 0)
    let saved = try roundTrip(doc, name: "blank.csv")
    expectEqual(saved.fields(forRow: 0), ["id", "name"], "blank doc header")
    expectEqual(saved.fields(forRow: 1), ["1", "Ada"], "blank doc row 1")
    expectEqual(saved.fields(forRow: 2), ["2", ""], "blank doc row 2")
}

// MARK: - Performance

print("performance (1,000,000 rows × 8 columns):")
let bigURL = tmpDir.appendingPathComponent("big.csv")
do {
    var out = Data(capacity: 130_000_000)
    out.append(contentsOf: Array("id,name,email,city,score,active,notes,date\n".utf8))
    var chunk = ""
    for i in 0..<1_000_000 {
        chunk += "\(i),user\(i),user\(i)@example.com,San Francisco,\(i % 100).5,true,\"note, with comma \(i)\",2026-06-12\n"
        if i % 50_000 == 49_999 {
            out.append(contentsOf: Array(chunk.utf8))
            chunk = ""
        }
    }
    out.append(contentsOf: Array(chunk.utf8))
    try out.write(to: bigURL)
    let mb = Double(out.count) / 1_048_576
    print(String(format: "  generated %.0f MB test file", mb))

    let t = try CSVTable(url: bigURL)
    var start = DispatchTime.now()
    t.indexSynchronously()
    var elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
    expectEqual(t.safeRowCount, 1_000_001, "big file row count")
    print(String(format: "  indexed in %.3f s (%.0f MB/s)", elapsed, mb / elapsed))

    // Random access: parse 100k scattered rows (simulates fast scrolling).
    start = DispatchTime.now()
    var checksum = 0
    var rng: UInt64 = 0x12345678
    for _ in 0..<100_000 {
        rng = rng &* 6364136223846793005 &+ 1442695040888963407
        let row = Int(rng % 1_000_000) + 1
        checksum &+= t.fields(forRow: row, useCache: false).count
    }
    elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
    expectEqual(checksum, 800_000, "random-access field counts")
    print(String(format: "  parsed 100k random rows in %.3f s (%.1f µs/row)", elapsed, elapsed * 10))

    // Save with a single edit: fast path should stream-copy nearly everything.
    let doc = CSVDocument()
    doc.attach(table: t, url: bigURL)
    doc.setUpColumns()
    doc.setValue("EDITED", row: 500_000, col: 1)
    let outURL = tmpDir.appendingPathComponent("big-out.csv")
    start = DispatchTime.now()
    try doc.performSave(to: outURL)
    elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
    print(String(format: "  saved 1M rows (1 cell edited) in %.3f s (%.0f MB/s)", elapsed, mb / elapsed))

    let saved = try CSVTable(url: outURL)
    saved.indexSynchronously()
    expectEqual(saved.safeRowCount, 1_000_001, "saved big file row count")
    expectEqual(saved.fields(forRow: 500_001)[1], "EDITED", "edit present in saved file")
    expectEqual(saved.fields(forRow: 999_999)[6], "note, with comma 999998", "quoting preserved in raw-copied rows")
}

print(failures == 0 ? "\nALL TESTS PASSED" : "\n\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
