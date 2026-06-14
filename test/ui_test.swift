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
expect(c.csvDocument.isCellUnsaved(row: 0, col: 0), "edited cell marked unsaved")
expect(!c.csvDocument.isCellUnsaved(row: 1, col: 0), "untouched cell not marked unsaved")

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
expectEqual(c.tableView.selectedRow, 1, "previous row selected after delete")
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
expect(!c.csvDocument.isCellUnsaved(row: 0, col: 0), "unsaved-cell mark cleared after save")
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

// MARK: 12. Line numbers & font size

print("line numbers & font size:")
let ruler = c.tableView.enclosingScrollView?.verticalRulerView
expect(ruler is LineNumberRulerView, "line number ruler installed")
expect((ruler?.ruleThickness ?? 0) >= 28, "ruler has visible thickness")
let baseHeight = c.tableView.rowHeight
c.increaseFontSize(nil)
expect(c.tableView.rowHeight > baseHeight, "⌘+ increases row height")
c.resetFontSize(nil)
expectEqual(c.tableView.rowHeight, baseHeight, "⌘0 restores default size")
c.decreaseFontSize(nil)
expect(c.tableView.rowHeight < baseHeight, "⌘− decreases row height")
c.resetFontSize(nil)

c.close()

// MARK: 13. Find (⌘F)

print("find:")
let findURL = fixture("find.csv", "name,qty\napple,1\nbanana,2\npineapple,3\n")
let c7 = openController(findURL)
c7.showFind(nil)
expect(!c7.findBar.isHidden, "⌘F shows the find bar")
c7.searchField.stringValue = "apple"
c7.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,
                                     object: c7.searchField))
expectEqual(c7.findMatches.count, 2, "two matching cells found")
expectEqual(c7.findMatchLabel.stringValue, "1 of 2", "label shows position and total")
expectEqual(c7.tableView.selectedRow, 0, "jumps to first match")
c7.findNext(nil)
expectEqual(c7.tableView.selectedRow, 2, "next moves to second match")
expectEqual(c7.findMatchLabel.stringValue, "2 of 2", "label follows traversal")
c7.findNext(nil)
expectEqual(c7.tableView.selectedRow, 0, "next wraps to first match")
c7.findPrevious(nil)
expectEqual(c7.tableView.selectedRow, 2, "previous wraps back to last match")

// Return in the search field advances (no current event in tests → no shift).
let dummyTextView = NSTextView()
expect(c7.control(c7.searchField, textView: dummyTextView,
                  doCommandBy: #selector(NSResponder.insertNewline(_:))),
       "return key is consumed by the search field")
expectEqual(c7.tableView.selectedRow, 0, "return advances to next match")

c7.searchField.stringValue = "zzz"
c7.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,
                                     object: c7.searchField))
expectEqual(c7.findMatchLabel.stringValue, "Not found", "label reports no matches")

// Edits restart the search with fresh positions.
c7.searchField.stringValue = "apple"
c7.restartFind(jumpToFirst: false)
commitEdit(c7, row: 1, col: 0, value: "crabapple")
expectEqual(c7.findMatches.count, 3, "search rescans after an edit")

expect(c7.control(c7.searchField, textView: dummyTextView,
                  doCommandBy: #selector(NSResponder.cancelOperation(_:))),
       "esc is consumed by the search field")
expect(c7.findBar.isHidden, "esc hides the find bar")
c7.close()

// MARK: 14. Cell cursor & keyboard navigation

print("cell navigation:")
let navURL = fixture("nav.csv", "a,b,c\n1,2,3\n4,5,6\n7,8,9\n")
let c8 = openController(navURL)
func navKey(_ chars: String, _ keyCode: UInt16) {
    let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                             timestamp: 0, windowNumber: c8.window?.windowNumber ?? 0,
                             context: nil, characters: chars, charactersIgnoringModifiers: chars,
                             isARepeat: false, keyCode: keyCode)!
    c8.tableView.keyDown(with: e)
}
expectEqual(c8.tableView.selectedRow, 0, "first row selected on open")
expect(c8.window?.firstResponder === c8.tableView, "table focused on open")
expectEqual(c8.currentCol, 0, "cursor starts at column 0")
navKey("l", 37)
expectEqual(c8.currentCol, 1, "l moves right")
navKey("j", 38)
expectEqual(c8.tableView.selectedRow, 1, "j moves down")
navKey("k", 40)
expectEqual(c8.tableView.selectedRow, 0, "k moves up")
navKey("h", 4)
expectEqual(c8.currentCol, 0, "h moves left")
navKey("h", 4)
expectEqual(c8.currentCol, 0, "left edge clamps")
navKey(String(UnicodeScalar(0xF703)!), 124) // →
expectEqual(c8.currentCol, 1, "right arrow moves right")
navKey(String(UnicodeScalar(0xF702)!), 123) // ←
expectEqual(c8.currentCol, 0, "left arrow moves left")
navKey(String(UnicodeScalar(0xF701)!), 125) // ↓ — native row move
expectEqual(c8.tableView.selectedRow, 1, "down arrow moves down")

// e starts editing the cursor cell instead of type-select jumping.
navKey("e", 14)
expect(c8.window?.firstResponder is NSTextView, "e starts editing the cursor cell")
c8.window?.makeFirstResponder(c8.tableView)
settle()

// "/" opens find; ⌘Return edits the matched cell in one step.
navKey("/", 44)
expect(!c8.findBar.isHidden, "/ opens the find bar")
c8.searchField.stringValue = "5"
c8.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,
                                     object: c8.searchField))
expectEqual(c8.tableView.selectedRow, 1, "find jumps to matched row")
expectEqual(c8.currentCol, 1, "find puts the cursor on the matched column")
let cmdReturn = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                                 timestamp: 0, windowNumber: c8.window?.windowNumber ?? 0,
                                 context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                 isARepeat: false, keyCode: 36)!
expect(c8.searchField.performKeyEquivalent(with: cmdReturn),
       "⌘⏎ is consumed by the search field")
expect(c8.findBar.isHidden, "⌘⏎ closes the find bar")
expect(c8.window?.firstResponder is NSTextView, "⌘⏎ starts editing the matched cell")
c8.window?.makeFirstResponder(c8.tableView)
settle()
c8.close()

// MARK: 15. Go to line

print("go to line:")
let gotoURL = fixture("goto.csv", "a,b,c\n1,2,3\n4,5,6\n7,8,9\n")
let c9 = openController(gotoURL)
// Default header: the ruler starts at line 2, so line N maps to row N-2.
expect(c9.csvDocument.hasHeader, "header on by default")
c9.jumpToLine(2)
expectEqual(c9.tableView.selectedRow, 0, "with header, line 2 is the first data row")
c9.jumpToLine(4)
expectEqual(c9.tableView.selectedRow, 2, "line 4 selects the last data row")
c9.jumpToLine(999)
expectEqual(c9.tableView.selectedRow, c9.csvDocument.rowCount - 1, "out-of-range clamps to last row")
c9.jumpToLine(1)
expectEqual(c9.tableView.selectedRow, 0, "below-range input clamps to first row")
expect(c9.window?.firstResponder === c9.tableView, "table refocused after jump")
// Without a header the ruler starts at line 1, so the offset shifts by one.
c9.toggleFirstRowHeader(nil)
expect(!c9.csvDocument.hasHeader, "header toggled off")
c9.jumpToLine(1)
expectEqual(c9.tableView.selectedRow, 0, "no header, line 1 is the first row")
c9.jumpToLine(3)
expectEqual(c9.tableView.selectedRow, 2, "no header, line 3 selects row index 2")
c9.close()

// MARK: - Save is refused while indexing (no partial-file truncation)

print("save blocked while indexing:")
do {
    // A file large enough that the background index does not finish before we
    // get a chance to act. Header + 200k data rows.
    var big = "a,b,c\n"
    for i in 0..<200_000 { big += "\(i),x,y\n" }
    let url = fixture("indexing.csv", big)
    let total = 200_001 // header + data rows

    let c = EditorWindowController()
    c.window?.orderFront(nil)
    c.loadFile(at: url)
    // The background scan has not been pumped yet, so the index is incomplete.
    expect(!c.isIndexed, "index incomplete right after load")

    let saveItem = NSMenuItem(title: "Save",
                              action: #selector(EditorWindowController.saveDocument(_:)),
                              keyEquivalent: "")
    expect(!c.validateMenuItem(saveItem), "Save menu item disabled while indexing")

    // Issue a save command anyway: it must be refused, not write a truncated
    // file over the original. This is the data-loss regression guard.
    c.saveDocument(nil)
    expectEqual(fileMatrix(url).count, total, "mid-index save left the file untouched (no truncation)")

    // Once indexing finishes the guard clears and a real save preserves all rows.
    expect(pump { c.isIndexed }, "indexing completes")
    expect(c.validateMenuItem(saveItem), "Save menu item enabled once indexed")
    c.saveDocument(nil)
    expect(pump { !c.csvDocument.isDirty && c.isIndexed }, "save settles")
    expectEqual(fileMatrix(url).count, total, "post-index save preserves every row")
    c.close()
}

// MARK: - Done

try? FileManager.default.removeItem(at: tmpDir)
print(failures == 0 ? "\nALL UI TESTS PASSED" : "\n\(failures) UI TEST FAILURES")
exit(failures == 0 ? 0 : 1)
