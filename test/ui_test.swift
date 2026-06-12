import AppKit

// In-process UI integration tests: boots a real NSApplication, drives real
// EditorWindowController instances (real NSTableView, real undo manager,
// real async indexing and saving), and asserts on document state and on the
// bytes written to disk. Compiled with all Sources except main.swift.
//
// Windows are created briefly on screen (accessory policy, no focus steal).

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

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

/// Pump the main run loop until a condition holds (or time out).
@discardableResult
func pump(timeout: TimeInterval = 10, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    return true
}

let tmpDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("csvedit-uitest-\(getpid())")
try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

func fixture(_ name: String, _ content: String) -> URL {
    let url = tmpDir.appendingPathComponent(name)
    try! Data(content.utf8).write(to: url)
    return url
}

func openController(_ url: URL) -> EditorWindowController {
    let controller = EditorWindowController()
    controller.window?.orderFront(nil)
    controller.loadFile(at: url)
    expect(pump { controller.csvDocument.table?.indexingComplete ?? false },
           "indexing completes for \(url.lastPathComponent)")
    return controller
}

/// Let the run loop turn once, closing the current undo group — mirrors the
/// event separation between distinct user actions in the real app.
func settle() {
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
}

/// Commit a cell edit through the same delegate path the field editor uses.
func commitEdit(_ controller: EditorWindowController, row: Int, col: Int, value: String) {
    controller.window?.makeFirstResponder(nil) // end any editing session first
    guard let cell = controller.tableView.view(atColumn: col, row: row, makeIfNecessary: true)
            as? NSTableCellView,
          let tf = cell.textField else {
        failures += 1
        print("  FAIL: no cell view at row \(row), col \(col)")
        return
    }
    tf.stringValue = value
    controller.controlTextDidEndEditing(
        Notification(name: NSControl.textDidEndEditingNotification, object: tf))
    settle()
}

func renderedValue(_ controller: EditorWindowController, row: Int, col: Int) -> String? {
    (controller.tableView.view(atColumn: col, row: row, makeIfNecessary: true)
        as? NSTableCellView)?.textField?.stringValue
}

/// Snapshot of what the document says it contains, header included.
func matrix(_ doc: CSVDocument) -> [[String]] {
    var rows: [[String]] = []
    if doc.hasHeader {
        rows.append((0..<doc.colCount).map { doc.headerTitle(col: $0) })
    }
    for r in 0..<doc.rowCount {
        rows.append((0..<doc.colCount).map { doc.value(row: r, col: $0) })
    }
    return rows
}

func fileMatrix(_ url: URL) -> [[String]] {
    let t = try! CSVTable(url: url)
    t.indexSynchronously()
    return (0..<t.safeRowCount).map { t.fields(forRow: $0) }
}

// MARK: 1. Open, index, render

print("open & render:")
let basicURL = fixture(
    "basic.csv",
    "name,qty,price\nwidget,2,3.50\n\"a,b\",7,\"he said \"\"hi\"\"\"\ngamma,9,1\n")
let c = openController(basicURL)
expectEqual(c.csvDocument.rowCount, 3, "data row count")
expectEqual(c.csvDocument.colCount, 3, "column count")
expectEqual(c.tableView.numberOfRows, 3, "table view row count")
expectEqual(c.tableView.tableColumns.map(\.title), ["name", "qty", "price"], "header titles")
expectEqual(renderedValue(c, row: 1, col: 0), "a,b", "rendered quoted cell")
expectEqual(renderedValue(c, row: 1, col: 2), "he said \"hi\"", "rendered escaped quotes")

// MARK: 2. Cell edit through the field-editor commit path

print("cell editing:")
commitEdit(c, row: 0, col: 0, value: "WIDGET PRO, MAX")
expectEqual(c.csvDocument.value(row: 0, col: 0), "WIDGET PRO, MAX", "edit committed to document")
expectEqual(renderedValue(c, row: 0, col: 0), "WIDGET PRO, MAX", "edit visible in table")
expect(c.csvDocument.isDirty, "document dirty after edit")
expect(c.window?.isDocumentEdited == true, "window shows edited marker")

// MARK: 3. Undo / redo

print("undo & redo:")
expect(c.window?.undoManager?.canUndo == true, "undo registered")
c.undo(nil); settle()
expectEqual(c.csvDocument.value(row: 0, col: 0), "widget", "undo reverts cell")
expectEqual(renderedValue(c, row: 0, col: 0), "widget", "undo updates table")
c.redo(nil); settle()
expectEqual(c.csvDocument.value(row: 0, col: 0), "WIDGET PRO, MAX", "redo reapplies cell")

// MARK: 4. Row operations

print("row operations:")
c.tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
c.addRowBelow(nil); settle()
expectEqual(c.csvDocument.rowCount, 4, "row inserted in document")
expectEqual(c.tableView.numberOfRows, 4, "row inserted in table")
commitEdit(c, row: 2, col: 0, value: "inserted-row")
expectEqual(c.csvDocument.value(row: 2, col: 0), "inserted-row", "new row editable")

c.tableView.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
c.deleteSelectedRows(nil); settle()
expectEqual(c.csvDocument.rowCount, 3, "row deleted")
expectEqual(c.csvDocument.value(row: 2, col: 0), "gamma", "following row moved up")
c.undo(nil); settle()
expectEqual(c.csvDocument.rowCount, 4, "undo restores deleted row")
expectEqual(c.csvDocument.value(row: 2, col: 0), "inserted-row", "undo restores row contents")

// MARK: 5. Column operations

print("column operations:")
c.performAddColumn(named: "note", at: 3); settle()
expectEqual(c.csvDocument.colCount, 4, "column added in document")
expectEqual(c.tableView.tableColumns.count, 4, "column added in table")
expectEqual(c.tableView.tableColumns[3].title, "note", "added column title")
commitEdit(c, row: 0, col: 3, value: "a note")
expectEqual(c.csvDocument.value(row: 0, col: 3), "a note", "added column editable")

c.performRenameColumn(displayIndex: 3, newName: "remark"); settle()
expectEqual(c.tableView.tableColumns[3].title, "remark", "column renamed")

c.performRemoveColumns(at: [1]); settle() // drop "qty"
expectEqual(c.csvDocument.colCount, 3, "column deleted")
expectEqual(c.tableView.tableColumns.map(\.title), ["name", "price", "remark"], "remaining titles")
c.undo(nil); settle()
expectEqual(c.csvDocument.colCount, 4, "undo restores column")
expectEqual(c.csvDocument.value(row: 1, col: 1), "7", "restored column has file data")

// MARK: 6. Save through the controller (async background save)

print("save:")
let beforeSave = matrix(c.csvDocument)
c.saveDocument(nil)
expect(pump { !c.csvDocument.isDirty }, "async save completes")
expect(c.window?.isDocumentEdited == false, "window clean after save")
expect(c.window?.undoManager?.canUndo == true, "undo history survives save")
expectEqual(fileMatrix(basicURL), beforeSave, "file on disk matches document exactly")

// Edit-after-save still works and re-dirties.
commitEdit(c, row: 0, col: 0, value: "post-save")
expect(c.csvDocument.isDirty, "dirty again after post-save edit")
c.undo(nil); settle()

// MARK: 7. Reopen round trip

print("reopen round trip:")
let c2 = openController(basicURL)
expectEqual(matrix(c2.csvDocument), beforeSave, "reopened document matches what was saved")
c2.close()

// MARK: 8. Header toggle

print("header toggle:")
let nhURL = fixture("noheader.csv", "1,2\n3,4\n")
let c3 = openController(nhURL)
expectEqual(c3.csvDocument.rowCount, 1, "header-mode row count")
c3.toggleFirstRowHeader(nil)
expectEqual(c3.csvDocument.rowCount, 2, "no-header-mode row count")
expectEqual(c3.tableView.tableColumns.map(\.title), ["A", "B"], "letter column titles")
expectEqual(c3.csvDocument.value(row: 0, col: 0), "1", "first file row becomes data")
c3.close()

// MARK: 9. Delimiter preservation

print("delimiter preservation:")
let semiURL = fixture("semi.csv", "a;b\n1;2\n")
let c4 = openController(semiURL)
expectEqual(c4.csvDocument.table?.delimiter, 0x3B, "semicolon detected")
commitEdit(c4, row: 0, col: 1, value: "x;y")
c4.saveDocument(nil)
expect(pump { !c4.csvDocument.isDirty }, "semicolon save completes")
let semiText = String(decoding: try! Data(contentsOf: semiURL), as: UTF8.self)
expectEqual(semiText, "a;b\n1;\"x;y\"\n", "saved with semicolons, value quoted")
c4.close()

// MARK: 10. Blank document

print("blank document:")
let c5 = EditorWindowController()
c5.window?.orderFront(nil)
c5.setUpNewDocument()
expectEqual(c5.csvDocument.rowCount, 1, "blank doc starts with one row")
expectEqual(c5.csvDocument.colCount, 3, "blank doc starts with three columns")
commitEdit(c5, row: 0, col: 0, value: "hello")
c5.performRenameColumn(displayIndex: 0, newName: "greeting"); settle()
let blankURL = tmpDir.appendingPathComponent("blank.csv")
c5.csvDocument.url = blankURL // avoid the save panel
c5.saveDocument(nil)
expect(pump { !c5.csvDocument.isDirty }, "blank doc save completes")
expectEqual(fileMatrix(blankURL), [["greeting", "B", "C"], ["hello", "", ""]],
            "blank doc saved correctly")
c5.close()

// MARK: 11. Large file opens responsively

print("large file (200k rows):")
var big = "id,value\n"
big.reserveCapacity(4_000_000)
for i in 0..<200_000 { big += "\(i),v\(i)\n" }
let bigURL = fixture("big.csv", big)
let start = DispatchTime.now()
let c6 = openController(bigURL)
let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
expectEqual(c6.csvDocument.rowCount, 200_000, "all rows indexed")
expect(elapsed < 5.0, String(format: "indexed via UI pipeline in %.2f s (< 5 s)", elapsed))
c6.tableView.scrollRowToVisible(199_999)
expectEqual(renderedValue(c6, row: 199_999, col: 1), "v199999", "last row renders after jump")
c6.close()

c.close()

// MARK: - Done

try? FileManager.default.removeItem(at: tmpDir)
print(failures == 0 ? "\nALL UI TESTS PASSED" : "\n\(failures) UI TEST FAILURES")
exit(failures == 0 ? 0 : 1)
