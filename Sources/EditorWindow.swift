import AppKit
import UniformTypeIdentifiers

/// Table view with Return/e-to-edit, Esc-to-close-find, /-to-find, cell-wise
/// cursor keys (←/→ and vim-style hjkl) and a row context menu.
final class EditorTableView: NSTableView {
    var onReturnKey: (() -> Void)?
    var contextMenuBuilder: ((Int) -> NSMenu?)?
    /// Returns true if the key was consumed (find bar visible).
    var onEscape: (() -> Bool)?
    var onMoveCell: ((_ dRow: Int, _ dCol: Int) -> Void)?
    var onStartFind: (() -> Void)?
    var onGoToLine: (() -> Void)?

    // Opt out of responsive (overdraw) scrolling. The Core-Animation smooth
    // scroll path moves the table between display passes, but the line-number
    // ruler only repaints per display pass, so it visibly trailed the rows.
    // Standard scrolling keeps the table and ruler in lockstep.
    override class var isCompatibleWithResponsiveScrolling: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, let onReturnKey { // return / enter
            onReturnKey()
            return
        }
        if event.keyCode == 53, let onEscape, onEscape() { return } // esc
        // ":" needs Shift, so it can't live in the modifier-free block below.
        if event.characters == ":", let onGoToLine,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            onGoToLine()
            return
        }
        if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            if let onMoveCell {
                switch event.keyCode {
                case 123: onMoveCell(0, -1); return // ←  (↑/↓ stay native)
                case 124: onMoveCell(0, 1); return  // →
                default: break
                }
                switch event.charactersIgnoringModifiers {
                case "h": onMoveCell(0, -1); return
                case "j": onMoveCell(1, 0); return
                case "k": onMoveCell(-1, 0); return
                case "l": onMoveCell(0, 1); return
                default: break
                }
            }
            switch event.charactersIgnoringModifiers {
            case "e": if let onReturnKey { onReturnKey(); return }
            case "/": if let onStartFind { onStartFind(); return }
            default: break
            }
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0 && !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return contextMenuBuilder?(row)
    }
}

/// Search field that claims ⌘Return while being edited — it must win over
/// the Add Row menu item, which owns that key equivalent globally.
final class FindSearchField: NSSearchField {
    var onCommandReturn: (() -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           event.keyCode == 36 || event.keyCode == 76, // return / enter
           event.modifierFlags.contains(.command),
           event.modifierFlags.intersection([.shift, .option, .control]).isEmpty,
           currentEditor() != nil,
           let onCommandReturn {
            return onCommandReturn()
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Vertical ruler that draws 1-based row numbers. Unlike a table column it
/// stays fixed while the table scrolls horizontally and never shifts column
/// indices (cell editing, header menus and the UI tests address columns by
/// document index).
final class LineNumberRulerView: NSRulerView {
    weak var tableView: NSTableView?
    var font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    /// First displayed row's line number (2 when the first file row is a header).
    var firstLineNumber = 1

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tableView else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let range = tableView.rows(in: tableView.visibleRect)
        for row in range.location..<(range.location + range.length) {
            let rowRect = convert(tableView.rect(ofRow: row), from: tableView)
            let label = String(row + firstLineNumber) as NSString
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 6,
                                   y: rowRect.midY - size.height / 2),
                       withAttributes: attrs)
        }
    }
}

/// Header view that vends a per-column context menu (rename, insert, delete)
/// and auto-sizes a column when its resize divider is double-clicked.
final class EditorHeaderView: NSTableHeaderView {
    var contextMenuBuilder: ((Int) -> NSMenu?)?
    var onSizeToFit: ((Int) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return contextMenuBuilder?(column(at: point))
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let col = dividerColumn(for: event) {
            onSizeToFit?(col)
            return
        }
        super.mouseDown(with: event)
    }

    /// The column whose right-edge resize divider sits under `event`, if any.
    private func dividerColumn(for event: NSEvent) -> Int? {
        guard let tableView else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let tolerance: CGFloat = 4
        for col in 0..<tableView.numberOfColumns {
            if abs(point.x - headerRect(ofColumn: col).maxX) <= tolerance { return col }
        }
        return nil
    }
}

final class EditorWindowController: NSWindowController, NSWindowDelegate,
    NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSSearchFieldDelegate,
    NSMenuItemValidation {

    let csvDocument = CSVDocument()
    var onClose: ((EditorWindowController) -> Void)?

    let tableView = EditorTableView() // internal: driven directly by ui tests
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var lineNumberRuler: LineNumberRulerView?
    private var isSaving = false
    private var customFieldEditor: NSTextView?

    // Find bar (internal: driven directly by ui tests)
    let findBar = NSVisualEffectView()
    let searchField = FindSearchField()
    let findMatchLabel = NSTextField(labelWithString: "")
    private(set) var findMatches: [(row: Int, col: Int)] = []
    private(set) var findCurrent: Int?

    /// Column component of the cell cursor; the row component is the table's
    /// selected row. Return edits this cell, ←/→/hjkl move it.
    private(set) var currentCol = 0
    private var lastCursorCell: (row: Int, col: Int)?
    private var findGeneration = 0
    private var findScanComplete = true
    private var scrollTopToContent: NSLayoutConstraint!
    private var scrollTopToFindBar: NSLayoutConstraint!

    private static let defaultFontSize: CGFloat = 12
    private var fontSize = EditorWindowController.defaultFontSize
    private var cellFont = NSFont.monospacedDigitSystemFont(
        ofSize: EditorWindowController.defaultFontSize, weight: .regular)

    /// NSWindowController's inherited undoManager resolves via its (nil)
    /// `document` and returns nil, silently dropping registrations — so own
    /// one explicitly and serve it to both the responder chain and the window.
    private let docUndoManager = UndoManager()
    override var undoManager: UndoManager? { docUndoManager }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { docUndoManager }

    private static let cellID = NSUserInterfaceItemIdentifier("cell")

    private let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Untitled"
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        window.center()
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - UI construction

    private func buildUI() {
        guard let content = window?.contentView else { return }

        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = true
        tableView.allowsTypeSelect = false // letters navigate/edit, not jump rows
        tableView.allowsColumnReordering = false
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.gridStyleMask = [.solidVerticalGridLineMask]
        tableView.gridColor = NSColor.separatorColor.withAlphaComponent(0.4)
        tableView.rowHeight = 20
        tableView.intercellSpacing = NSSize(width: 6, height: 2)
        if #available(macOS 11.0, *) { tableView.style = .plain }

        let header = EditorHeaderView(frame: NSRect(x: 0, y: 0, width: 0, height: 24))
        header.contextMenuBuilder = { [weak self] col in self?.headerMenu(forColumn: col) }
        header.onSizeToFit = { [weak self] col in self?.sizeColumnToFit(col) }
        tableView.headerView = header
        tableView.contextMenuBuilder = { [weak self] row in self?.rowMenu(forRow: row) }
        tableView.onReturnKey = { [weak self] in self?.editSelectedRow() }
        tableView.onEscape = { [weak self] in
            guard let self, !self.findBar.isHidden else { return false }
            self.closeFind(nil)
            return true
        }
        tableView.onMoveCell = { [weak self] dRow, dCol in
            self?.moveCellSelection(dRow: dRow, dCol: dCol)
        }
        tableView.onStartFind = { [weak self] in self?.showFind(nil) }
        tableView.onGoToLine = { [weak self] in self?.goToLine(nil) }
        tableView.target = self
        tableView.action = #selector(tableClicked(_:))
        tableView.doubleAction = #selector(tableDoubleClicked(_:))

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let ruler = LineNumberRulerView(scrollView: scrollView, orientation: .verticalRuler)
        ruler.clientView = tableView
        ruler.tableView = tableView
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        lineNumberRuler = ruler
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        findBar.material = .titlebar
        findBar.blendingMode = .withinWindow
        findBar.translatesAutoresizingMaskIntoConstraints = false
        findBar.isHidden = true

        searchField.placeholderString = "Find  (⏎ next, ⇧⏎ previous, ⌘⏎ edit, esc done)"
        searchField.delegate = self
        searchField.onCommandReturn = { [weak self] in
            guard let self else { return false }
            let hasMatch = self.currentFindPosition != nil
            self.closeFind(nil)
            if hasMatch { self.editSelectedRow() }
            return true
        }

        findMatchLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        findMatchLabel.textColor = .secondaryLabelColor
        findMatchLabel.lineBreakMode = .byTruncatingTail
        findMatchLabel.setContentHuggingPriority(.init(1), for: .horizontal)

        let findStack = NSStackView(views: [searchField, findMatchLabel])
        findStack.orientation = .horizontal
        findStack.spacing = 8
        findStack.translatesAutoresizingMaskIntoConstraints = false
        findBar.addSubview(findStack)

        let statusBar = NSVisualEffectView()
        statusBar.material = .titlebar
        statusBar.blendingMode = .withinWindow
        statusBar.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusBar.addSubview(statusLabel)

        content.addSubview(scrollView)
        content.addSubview(findBar)
        content.addSubview(statusBar)

        scrollTopToContent = scrollView.topAnchor.constraint(equalTo: content.topAnchor)
        scrollTopToFindBar = scrollView.topAnchor.constraint(equalTo: findBar.bottomAnchor)

        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(equalTo: content.topAnchor),
            findBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            findBar.heightAnchor.constraint(equalToConstant: 34),
            findStack.leadingAnchor.constraint(equalTo: findBar.leadingAnchor, constant: 8),
            findStack.trailingAnchor.constraint(equalTo: findBar.trailingAnchor, constant: -8),
            findStack.centerYAnchor.constraint(equalTo: findBar.centerYAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 300),
            scrollTopToContent,
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 22),
            statusLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusBar.trailingAnchor, constant: -10),
            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
        ])
    }

    private func rebuildTableColumns() {
        for column in tableView.tableColumns.reversed() {
            tableView.removeTableColumn(column)
        }
        for i in 0..<csvDocument.colCount {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col\(i)"))
            column.title = csvDocument.headerTitle(col: i)
            column.width = 130
            column.minWidth = 40
            column.maxWidth = 4000
            tableView.addTableColumn(column)
        }
    }

    /// Fit a column's width to its content. Only the currently visible rows are
    /// measured — never scan the whole file (it could be millions of rows).
    private func sizeColumnToFit(_ displayCol: Int) {
        guard displayCol >= 0, displayCol < tableView.tableColumns.count else { return }
        let column = tableView.tableColumns[displayCol]

        let headerFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        var maxWidth = (csvDocument.headerTitle(col: displayCol) as NSString)
            .size(withAttributes: [.font: headerFont]).width

        let cellAttrs: [NSAttributedString.Key: Any] = [.font: cellFont]
        let visible = tableView.rows(in: tableView.visibleRect)
        if visible.length > 0 {
            for row in visible.location..<(visible.location + visible.length) {
                let w = (csvDocument.value(row: row, col: displayCol) as NSString)
                    .size(withAttributes: cellAttrs).width
                if w > maxWidth { maxWidth = w }
            }
        }

        // Cell insets (2+2) plus a little breathing room.
        let newWidth = (maxWidth + 12).rounded(.up)
        column.width = max(column.minWidth, min(newWidth, column.maxWidth))
    }

    // MARK: - Document lifecycle

    func setUpNewDocument() {
        csvDocument.setUpEmpty()
        window?.title = "Untitled"
        window?.representedURL = nil
        window?.isDocumentEdited = false
        rebuildTableColumns()
        tableView.reloadData()
        updateStatus()
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        window?.makeFirstResponder(tableView)
    }

    func loadFile(at url: URL) {
        let table: CSVTable
        do {
            table = try CSVTable(url: url)
        } catch {
            presentError(error)
            return
        }
        csvDocument.attach(table: table, url: url)
        window?.title = url.lastPathComponent
        window?.representedURL = url
        window?.isDocumentEdited = false
        rebuildTableColumns()
        tableView.reloadData()
        updateStatus()

        table.onProgress = { [weak self] _, done in
            guard let self else { return }
            if self.csvDocument.colCount == 0 {
                self.csvDocument.setUpColumns()
                self.rebuildTableColumns()
            }
            self.tableView.noteNumberOfRowsChanged()
            self.updateStatus()
            if done && self.csvDocument.rowCount == 0 && self.csvDocument.colCount == 0 {
                // Empty file: behave like a blank document.
                self.csvDocument.setUpEmpty()
                self.csvDocument.url = url
                self.rebuildTableColumns()
                self.tableView.reloadData()
                self.updateStatus()
            }
            if self.tableView.selectedRow < 0 && self.csvDocument.rowCount > 0 {
                self.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                // An empty table refuses first-responder status, so focus it
                // only now that it has content — arrow keys work right away.
                self.window?.makeFirstResponder(self.tableView)
            }
        }
        table.startIndexing()
    }

    private func updateStatus() {
        var parts: [String] = []
        let rows = numberFormatter.string(from: NSNumber(value: csvDocument.rowCount)) ?? "0"
        parts.append("\(rows) rows × \(csvDocument.colCount) columns")
        if let t = csvDocument.table {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(t.data.count), countStyle: .file))
            let names: [UInt8: String] = [0x2C: "comma", 0x3B: "semicolon", 0x09: "tab", 0x7C: "pipe"]
            if let name = names[t.delimiter] { parts.append(name) }
            if !t.indexingComplete { parts.append("indexing…") }
        }
        if isSaving { parts.append("saving…") }
        if csvDocument.isDirty { parts.append("edited") }
        statusLabel.stringValue = parts.joined(separator: "   •   ")
        updateLineNumberWidth()
    }

    @objc private func scrollBoundsChanged(_ note: Notification) {
        lineNumberRuler?.needsDisplay = true
    }

    private func updateLineNumberWidth() {
        guard let ruler = lineNumberRuler else { return }
        // With a header, the first data row is file line 2, so numbering is
        // offset by one and the widest number is rowCount + 1.
        ruler.firstLineNumber = csvDocument.hasHeader ? 2 : 1
        let lastLine = csvDocument.rowCount + ruler.firstLineNumber - 1
        let widest = "\(max(lastLine, 1))" as NSString
        let width = widest.size(withAttributes: [.font: ruler.font]).width
        ruler.ruleThickness = max(28, ceil(width) + 12)
        ruler.needsDisplay = true
    }

    // MARK: - Font size

    @objc func increaseFontSize(_ sender: Any?) { setFontSize(fontSize + 1) }
    @objc func decreaseFontSize(_ sender: Any?) { setFontSize(fontSize - 1) }
    @objc func resetFontSize(_ sender: Any?) { setFontSize(Self.defaultFontSize) }

    private func setFontSize(_ size: CGFloat) {
        let clamped = min(max(size, 8), 36)
        guard clamped != fontSize else { NSSound.beep(); return }
        fontSize = clamped
        cellFont = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
        tableView.rowHeight = ceil(fontSize) + 8
        tableView.reloadData()
        lineNumberRuler?.font = NSFont.monospacedDigitSystemFont(
            ofSize: max(9, fontSize - 2), weight: .regular)
        updateLineNumberWidth()
    }

    private func markEdited() {
        window?.isDocumentEdited = true
        updateStatus()
        // Any edit can shift or change match positions.
        if !findBar.isHidden { restartFind(jumpToFirst: false) }
    }

    private func editsAllowed(structuralRows: Bool = false) -> Bool {
        if isSaving { return false }
        if structuralRows, let t = csvDocument.table, !t.indexingComplete {
            NSSound.beep()
            return false
        }
        return true
    }

    // MARK: - Table data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int { csvDocument.rowCount }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn,
              let colIndex = tableView.tableColumns.firstIndex(of: tableColumn) else { return nil }
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = makeCellView()
        }
        cell.textField?.font = cellFont
        cell.textField?.stringValue = csvDocument.value(row: row, col: colIndex)
        if let tf = cell.textField {
            if let m = currentFindPosition, m.row == row, m.col == colIndex {
                tf.drawsBackground = true
                tf.backgroundColor = .findHighlightColor
                tf.textColor = .black
            } else {
                tf.drawsBackground = false
                tf.textColor = .labelColor
            }
        }
        cell.wantsLayer = true
        let isCursor = row == tableView.selectedRow && colIndex == currentCol
        cell.layer?.borderWidth = isCursor ? 2 : 0
        cell.layer?.borderColor = NSColor.controlAccentColor.cgColor
        cell.layer?.cornerRadius = 3
        return cell
    }

    private func makeCellView() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = Self.cellID
        let tf = NSTextField()
        tf.isBordered = false
        tf.drawsBackground = false
        tf.isEditable = true
        tf.usesSingleLineMode = true
        tf.cell?.isScrollable = true
        tf.lineBreakMode = .byTruncatingTail
        tf.font = cellFont
        tf.delegate = self
        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(tf)
        cell.textField = tf
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: - Cell editing

    func controlTextDidChange(_ obj: Notification) {
        if obj.object as AnyObject === searchField {
            restartFind(jumpToFirst: true)
        }
    }

    /// Fires when the search field's cancel button clears the query.
    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        restartFind(jumpToFirst: false)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let tf = obj.object as? NSTextField else { return }
        let row = tableView.row(for: tf)
        let col = tableView.column(for: tf)
        guard row >= 0, col >= 0 else { return }
        applyCellEdit(tf.stringValue, row: row, col: col)
    }

    private func applyCellEdit(_ newValue: String, row: Int, col: Int) {
        guard row < csvDocument.rowCount, col < csvDocument.colCount else { return }
        let old = csvDocument.value(row: row, col: col)
        guard newValue != old else { return }
        csvDocument.setValue(newValue, row: row, col: col)
        registerCellUndo(old: old, row: row, col: col)
        markEdited()
        reloadCell(row: row, col: col)
    }

    private func registerCellUndo(old: String, row: Int, col: Int) {
        undoManager?.registerUndo(withTarget: self) { me in
            let current = me.csvDocument.value(row: row, col: col)
            me.csvDocument.setValue(old, row: row, col: col)
            me.registerCellUndo(old: current, row: row, col: col)
            me.markEdited()
            me.reloadCell(row: row, col: col)
            me.tableView.scrollRowToVisible(row)
        }
        undoManager?.setActionName("Edit Cell")
    }

    private func reloadCell(row: Int, col: Int) {
        tableView.reloadData(forRowIndexes: IndexSet(integer: row),
                             columnIndexes: IndexSet(integer: col))
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if control === searchField {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    findPrevious(nil)
                } else {
                    findNext(nil)
                }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                closeFind(nil)
                return true
            default:
                return false
            }
        }
        guard let tf = control as? NSTextField else { return false }
        let row = tableView.row(for: tf)
        let col = tableView.column(for: tf)
        guard row >= 0, col >= 0 else { return false }
        switch selector {
        case #selector(NSResponder.insertTab(_:)),
             #selector(NSResponder.insertBacktab(_:)),
             #selector(NSResponder.insertNewline(_:)):
            window?.makeFirstResponder(tableView) // commits via controlTextDidEndEditing; stay on this cell
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            tf.stringValue = csvDocument.value(row: row, col: col)
            window?.makeFirstResponder(tableView)
            return true
        default:
            return false
        }
    }

    private func editCell(row: Int, col: Int) {
        guard editsAllowed(), row >= 0, row < csvDocument.rowCount,
              col >= 0, col < csvDocument.colCount else { return }
        currentCol = col
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        refreshCellCursor()
        tableView.scrollRowToVisible(row)
        tableView.scrollColumnToVisible(col)
        tableView.editColumn(col, row: row, with: nil, select: true)
    }

    private func editSelectedRow() {
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        editCell(row: row, col: min(currentCol, max(0, csvDocument.colCount - 1)))
    }

    @objc private func tableClicked(_ sender: Any?) {
        let col = tableView.clickedColumn
        guard col >= 0 else { return }
        currentCol = col
        refreshCellCursor()
    }

    @objc private func tableDoubleClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        let col = tableView.clickedColumn
        guard row >= 0, col >= 0 else { return }
        editCell(row: row, col: col)
    }

    // MARK: - Cell cursor

    func moveCellSelection(dRow: Int, dCol: Int) {
        let rows = csvDocument.rowCount
        let cols = csvDocument.colCount
        guard rows > 0, cols > 0 else { return }
        let row = tableView.selectedRow < 0
            ? 0 : max(0, min(rows - 1, tableView.selectedRow + dRow))
        currentCol = max(0, min(cols - 1, currentCol + dCol))
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        refreshCellCursor() // selectRowIndexes only notifies when the row changed
        tableView.scrollRowToVisible(row)
        tableView.scrollColumnToVisible(currentCol)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        refreshCellCursor()
    }

    /// Reload the cells that gained or lost the cursor so the border redraws.
    private func refreshCellCursor() {
        let new: (row: Int, col: Int)? =
            tableView.selectedRow >= 0 ? (tableView.selectedRow, currentCol) : nil
        if let old = lastCursorCell, old.row != new?.row || old.col != new?.col {
            reloadCellIfValid(old)
        }
        if let new { reloadCellIfValid(new) }
        lastCursorCell = new
    }

    /// A plain field editor with undo disabled, so in-cell typing doesn't
    /// pollute the document-level undo stack with dead text-view entries.
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        guard client is NSTextField else { return nil }
        if customFieldEditor == nil {
            let tv = NSTextView()
            tv.isFieldEditor = true
            tv.allowsUndo = false
            customFieldEditor = tv
        }
        return customFieldEditor
    }

    // MARK: - Row operations

    @objc func addRowBelow(_ sender: Any?) {
        guard editsAllowed(structuralRows: true) else { return }
        let selected = tableView.selectedRow
        let at = selected >= 0 ? selected + 1 : csvDocument.rowCount
        performInsertRows(ids: [csvDocument.makeRowID()], at: [at], thenEdit: true)
    }

    @objc func deleteSelectedRows(_ sender: Any?) {
        guard editsAllowed(structuralRows: true) else { return }
        let selection = tableView.selectedRowIndexes
        guard !selection.isEmpty else { NSSound.beep(); return }
        performRemoveRows(at: Array(selection))
    }

    @objc private func insertRowFromMenu(_ sender: NSMenuItem) {
        guard editsAllowed(structuralRows: true) else { return }
        performInsertRows(ids: [csvDocument.makeRowID()], at: [sender.tag], thenEdit: true)
    }

    func performInsertRows(ids: [Int], at indices: [Int], thenEdit: Bool = false) {
        csvDocument.insertRows(ids: ids, at: indices)
        undoManager?.registerUndo(withTarget: self) { me in me.performRemoveRows(at: indices) }
        undoManager?.setActionName("Insert Row")
        tableView.insertRows(at: IndexSet(indices), withAnimation: [])
        markEdited()
        if let first = indices.first {
            tableView.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
            tableView.scrollRowToVisible(first)
            if thenEdit { editCell(row: first, col: 0) }
        }
    }

    func performRemoveRows(at indices: [Int]) {
        let sorted = indices.sorted()
        let ids = csvDocument.removeRows(at: sorted)
        undoManager?.registerUndo(withTarget: self) { me in me.performInsertRows(ids: ids, at: sorted) }
        undoManager?.setActionName("Delete Rows")
        tableView.removeRows(at: IndexSet(sorted), withAnimation: [])
        markEdited()
        if csvDocument.rowCount > 0, let first = sorted.first {
            let row = min(max(0, first - 1), csvDocument.rowCount - 1)
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        }
    }

    // MARK: - Column operations

    @objc func addColumnAtEnd(_ sender: Any?) {
        guard editsAllowed() else { return }
        promptForText(title: "Add Column",
                      message: "Name for the new column:",
                      initial: CSVDocument.letterName(csvDocument.colCount)) { [weak self] name in
            guard let self else { return }
            self.performAddColumn(named: name, at: self.csvDocument.colCount)
        }
    }

    @objc private func insertColumnFromMenu(_ sender: NSMenuItem) {
        guard editsAllowed() else { return }
        let at = sender.tag
        promptForText(title: "Insert Column",
                      message: "Name for the new column:",
                      initial: "") { [weak self] name in
            self?.performAddColumn(named: name, at: at)
        }
    }

    @objc private func renameColumnFromMenu(_ sender: NSMenuItem) {
        guard editsAllowed() else { return }
        let col = sender.tag
        guard col < csvDocument.colCount else { return }
        promptForText(title: "Rename Column",
                      message: "New name:",
                      initial: csvDocument.headerTitle(col: col)) { [weak self] name in
            guard let self, !name.isEmpty else { return }
            self.performRenameColumn(displayIndex: col, newName: name)
        }
    }

    @objc private func deleteColumnFromMenu(_ sender: NSMenuItem) {
        guard editsAllowed() else { return }
        let col = sender.tag
        guard col < csvDocument.colCount, csvDocument.colCount > 1 else { NSSound.beep(); return }
        performRemoveColumns(at: [col])
    }

    func performAddColumn(named name: String?, at index: Int) {
        _ = csvDocument.addColumn(named: name, at: index)
        undoManager?.registerUndo(withTarget: self) { me in me.performRemoveColumns(at: [index]) }
        undoManager?.setActionName("Add Column")
        rebuildTableColumns()
        tableView.reloadData()
        markEdited()
    }

    func performRemoveColumns(at indices: [Int]) {
        let sorted = indices.sorted()
        let logicals = csvDocument.removeColumns(at: sorted)
        undoManager?.registerUndo(withTarget: self) { me in
            me.performReinsertColumns(logicals: logicals, at: sorted)
        }
        undoManager?.setActionName("Delete Column")
        rebuildTableColumns()
        tableView.reloadData()
        markEdited()
    }

    private func performReinsertColumns(logicals: [Int], at indices: [Int]) {
        csvDocument.insertColumns(logicals: logicals, at: indices)
        undoManager?.registerUndo(withTarget: self) { me in me.performRemoveColumns(at: indices) }
        undoManager?.setActionName("Add Column")
        rebuildTableColumns()
        tableView.reloadData()
        markEdited()
    }

    func performRenameColumn(displayIndex: Int, newName: String?) {
        guard displayIndex < csvDocument.colCount else { return }
        let logical = csvDocument.colMap[displayIndex]
        let old = csvDocument.headerNames[logical]
        csvDocument.headerNames[logical] = newName
        csvDocument.isDirty = true
        undoManager?.registerUndo(withTarget: self) { me in
            me.performRenameColumn(displayIndex: displayIndex, newName: old)
        }
        undoManager?.setActionName("Rename Column")
        if displayIndex < tableView.tableColumns.count {
            tableView.tableColumns[displayIndex].title = csvDocument.headerTitle(col: displayIndex)
        }
        markEdited()
    }

    @objc func toggleFirstRowHeader(_ sender: Any?) {
        guard !csvDocument.isDirty else { NSSound.beep(); return }
        guard csvDocument.table != nil else { NSSound.beep(); return }
        csvDocument.hasHeader.toggle()
        rebuildTableColumns()
        tableView.reloadData()
        updateStatus()
        if !findBar.isHidden { restartFind(jumpToFirst: false) }
    }

    // MARK: - Context menus

    private func headerMenu(forColumn col: Int) -> NSMenu? {
        guard col >= 0, col < csvDocument.colCount else { return nil }
        let menu = NSMenu()
        let title = csvDocument.headerTitle(col: col)

        let rename = NSMenuItem(title: "Rename “\(title)”…",
                                action: #selector(renameColumnFromMenu(_:)), keyEquivalent: "")
        rename.target = self
        rename.tag = col
        menu.addItem(rename)

        menu.addItem(.separator())

        let before = NSMenuItem(title: "Insert Column Before",
                                action: #selector(insertColumnFromMenu(_:)), keyEquivalent: "")
        before.target = self
        before.tag = col
        menu.addItem(before)

        let after = NSMenuItem(title: "Insert Column After",
                               action: #selector(insertColumnFromMenu(_:)), keyEquivalent: "")
        after.target = self
        after.tag = col + 1
        menu.addItem(after)

        menu.addItem(.separator())

        let delete = NSMenuItem(title: "Delete Column “\(title)”",
                                action: #selector(deleteColumnFromMenu(_:)), keyEquivalent: "")
        delete.target = self
        delete.tag = col
        menu.addItem(delete)

        return menu
    }

    private func rowMenu(forRow row: Int) -> NSMenu? {
        let menu = NSMenu()
        if row >= 0 {
            let above = NSMenuItem(title: "Insert Row Above",
                                   action: #selector(insertRowFromMenu(_:)), keyEquivalent: "")
            above.target = self
            above.tag = row
            menu.addItem(above)

            let below = NSMenuItem(title: "Insert Row Below",
                                   action: #selector(insertRowFromMenu(_:)), keyEquivalent: "")
            below.target = self
            below.tag = row + 1
            menu.addItem(below)

            menu.addItem(.separator())

            let n = tableView.selectedRowIndexes.count
            let delete = NSMenuItem(title: n > 1 ? "Delete \(n) Rows" : "Delete Row",
                                    action: #selector(deleteSelectedRows(_:)), keyEquivalent: "")
            delete.target = self
            menu.addItem(delete)

            menu.addItem(.separator())

            let copy = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
            copy.target = self
            menu.addItem(copy)
        } else {
            let add = NSMenuItem(title: "Add Row", action: #selector(addRowBelow(_:)), keyEquivalent: "")
            add.target = self
            menu.addItem(add)
        }
        return menu
    }

    // MARK: - Copy

    @objc func copy(_ sender: Any?) {
        let selection = tableView.selectedRowIndexes
        guard !selection.isEmpty else { NSSound.beep(); return }
        var lines: [String] = []
        lines.reserveCapacity(selection.count)
        for row in selection {
            lines.append((0..<csvDocument.colCount)
                .map { csvDocument.value(row: row, col: $0) }
                .joined(separator: "\t"))
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(lines.joined(separator: "\n"), forType: .string)
    }

    // MARK: - Find

    @objc func showFind(_ sender: Any?) {
        if findBar.isHidden {
            findBar.isHidden = false
            scrollTopToContent.isActive = false
            scrollTopToFindBar.isActive = true
        }
        window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
        if !searchField.stringValue.isEmpty { restartFind(jumpToFirst: true) }
    }

    @objc func closeFind(_ sender: Any?) {
        guard !findBar.isHidden else { return }
        findGeneration += 1 // cancel any in-flight scan
        clearCurrentFindHighlight()
        findMatches = []
        findScanComplete = true
        findBar.isHidden = true
        scrollTopToFindBar.isActive = false
        scrollTopToContent.isActive = true
        window?.makeFirstResponder(tableView)
    }

    @objc func findNext(_ sender: Any?) { stepFind(1) }
    @objc func findPrevious(_ sender: Any?) { stepFind(-1) }

    private func stepFind(_ delta: Int) {
        guard !findMatches.isEmpty else { NSSound.beep(); return }
        let count = findMatches.count
        let next: Int
        if let cur = findCurrent {
            next = ((cur + delta) % count + count) % count
        } else {
            next = delta > 0 ? 0 : count - 1
        }
        selectMatch(next)
    }

    private var currentFindPosition: (row: Int, col: Int)? {
        guard let cur = findCurrent, cur < findMatches.count else { return nil }
        return findMatches[cur]
    }

    private func clearCurrentFindHighlight() {
        guard let m = currentFindPosition else { findCurrent = nil; return }
        findCurrent = nil
        reloadCellIfValid(m)
    }

    private func selectMatch(_ idx: Int) {
        let m = findMatches[idx]
        guard m.row < csvDocument.rowCount, m.col < csvDocument.colCount else {
            restartFind(jumpToFirst: true) // stale match positions
            return
        }
        clearCurrentFindHighlight()
        findCurrent = idx
        currentCol = m.col // Esc + Return then edits the matched cell
        tableView.selectRowIndexes(IndexSet(integer: m.row), byExtendingSelection: false)
        refreshCellCursor()
        tableView.scrollRowToVisible(m.row)
        tableView.scrollColumnToVisible(m.col)
        reloadCellIfValid(m)
        updateFindLabel()
    }

    private func reloadCellIfValid(_ m: (row: Int, col: Int)) {
        guard m.row < tableView.numberOfRows, m.col < tableView.numberOfColumns else { return }
        reloadCell(row: m.row, col: m.col)
    }

    /// Rescan the document for the query in main-thread chunks, so huge files
    /// never freeze the UI. A bumped generation cancels stale scans.
    func restartFind(jumpToFirst: Bool) {
        findGeneration += 1
        clearCurrentFindHighlight()
        findMatches = []
        findScanComplete = true
        let query = searchField.stringValue
        guard !findBar.isHidden, !query.isEmpty else {
            updateFindLabel()
            return
        }
        findScanComplete = false
        scanForMatches(from: 0, query: query, generation: findGeneration, jumpToFirst: jumpToFirst)
    }

    private func scanForMatches(from startRow: Int, query: String, generation: Int,
                                jumpToFirst: Bool) {
        guard generation == findGeneration else { return }
        let endRow = min(startRow + 4096, csvDocument.rowCount)
        let cols = csvDocument.colCount
        let hadMatches = !findMatches.isEmpty
        for row in startRow..<endRow {
            for col in 0..<cols where csvDocument.value(row: row, col: col)
                .range(of: query, options: .caseInsensitive) != nil {
                findMatches.append((row, col))
            }
        }
        if jumpToFirst, !hadMatches, !findMatches.isEmpty {
            selectMatch(0)
        }
        if endRow < csvDocument.rowCount {
            updateFindLabel()
            DispatchQueue.main.async { [weak self] in
                self?.scanForMatches(from: endRow, query: query, generation: generation,
                                     jumpToFirst: jumpToFirst)
            }
        } else {
            findScanComplete = true
            updateFindLabel()
        }
    }

    private func updateFindLabel() {
        if searchField.stringValue.isEmpty {
            findMatchLabel.stringValue = ""
        } else if findMatches.isEmpty {
            findMatchLabel.stringValue = findScanComplete ? "Not found" : "Searching…"
        } else {
            let total = "\(findMatches.count)\(findScanComplete ? "" : "+")"
            if let cur = findCurrent {
                findMatchLabel.stringValue = "\(cur + 1) of \(total)"
            } else {
                findMatchLabel.stringValue = "\(total) matches"
            }
        }
    }

    // MARK: - Go to line

    @objc func goToLine(_ sender: Any?) {
        guard csvDocument.rowCount > 0 else { NSSound.beep(); return }
        let firstLine = csvDocument.hasHeader ? 2 : 1
        let lastLine = csvDocument.rowCount + firstLine - 1
        promptForText(title: "Go to Line",
                      message: "Line number (\(firstLine)–\(lastLine)):",
                      initial: "") { [weak self] text in
            guard let self else { return }
            guard let line = Int(text.trimmingCharacters(in: .whitespaces)) else {
                NSSound.beep(); return
            }
            self.jumpToLine(line)
        }
    }

    /// Select and reveal the row whose line number (as drawn by the ruler)
    /// matches `line`, clamping out-of-range input to the first/last row.
    /// Internal so the UI tests can drive it without the modal prompt.
    func jumpToLine(_ line: Int) {
        guard csvDocument.rowCount > 0 else { return }
        let firstLine = csvDocument.hasHeader ? 2 : 1
        let row = max(0, min(csvDocument.rowCount - 1, line - firstLine))
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        refreshCellCursor()
        tableView.scrollRowToVisible(row)
        window?.makeFirstResponder(tableView)
    }

    // MARK: - Undo plumbing

    @objc func undo(_ sender: Any?) { undoManager?.undo() }
    @objc func redo(_ sender: Any?) { undoManager?.redo() }

    // MARK: - Saving

    @objc func saveDocument(_ sender: Any?) {
        guard !isSaving else { return }
        if let t = csvDocument.table, !t.indexingComplete { NSSound.beep(); return }
        if let url = csvDocument.url {
            saveTo(url)
        } else {
            saveDocumentAs(sender)
        }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        guard !isSaving, let window else { return }
        if let t = csvDocument.table, !t.indexingComplete { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = csvDocument.url?.lastPathComponent ?? "Untitled.csv"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.saveTo(url)
        }
    }

    private func saveTo(_ url: URL) {
        window?.makeFirstResponder(tableView) // commit any in-progress cell edit
        isSaving = true
        tableView.isEnabled = false
        updateStatus()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                try csvDocument.performSave(to: url)
                DispatchQueue.main.async { self.didSave(to: url) }
            } catch {
                DispatchQueue.main.async {
                    self.isSaving = false
                    self.tableView.isEnabled = true
                    self.updateStatus()
                    self.presentError(error)
                }
            }
        }
    }

    /// The save serialized exactly the current in-memory model, so disk and
    /// model now agree — no reload needed. The old file mapping stays valid
    /// (the replaced inode lives until unmapped), edits simply remain as a
    /// no-longer-dirty overlay, and undo history survives.
    private func didSave(to url: URL) {
        isSaving = false
        tableView.isEnabled = true
        csvDocument.url = url
        csvDocument.isDirty = false
        window?.title = url.lastPathComponent
        window?.representedURL = url
        window?.isDocumentEdited = false
        updateStatus()
    }

    /// Synchronous save used by the close-window path.
    private func saveSynchronously() -> Bool {
        var url = csvDocument.url
        if url == nil {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.allowsOtherFileTypes = true
            panel.nameFieldStringValue = "Untitled.csv"
            guard panel.runModal() == .OK else { return false }
            url = panel.url
        }
        guard let url else { return false }
        do {
            try csvDocument.performSave(to: url)
            return true
        } catch {
            presentError(error)
            return false
        }
    }

    // MARK: - Window delegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard csvDocument.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes made to “\(window?.title ?? "this document")”?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return saveSynchronously()
        case .alertSecondButtonReturn:
            return false
        default:
            return true
        }
    }

    func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }

    // MARK: - Menu validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(saveDocument(_:)), #selector(saveDocumentAs(_:)):
            return !isSaving && (csvDocument.table?.indexingComplete ?? true)
        case #selector(deleteSelectedRows(_:)), #selector(copy(_:)):
            return !tableView.selectedRowIndexes.isEmpty
        case #selector(addRowBelow(_:)):
            return !isSaving && (csvDocument.table?.indexingComplete ?? true)
        case #selector(addColumnAtEnd(_:)):
            return !isSaving
        case #selector(toggleFirstRowHeader(_:)):
            menuItem.state = csvDocument.hasHeader ? .on : .off
            return !csvDocument.isDirty && csvDocument.table != nil
        case #selector(increaseFontSize(_:)):
            return fontSize < 36
        case #selector(decreaseFontSize(_:)):
            return fontSize > 8
        case #selector(resetFontSize(_:)):
            return fontSize != Self.defaultFontSize
        case #selector(goToLine(_:)):
            return csvDocument.rowCount > 0
        case #selector(undo(_:)):
            return undoManager?.canUndo ?? false
        case #selector(redo(_:)):
            return undoManager?.canRedo ?? false
        default:
            return true
        }
    }

    // MARK: - Helpers

    private func promptForText(title: String, message: String, initial: String,
                               completion: @escaping (String) -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        tf.stringValue = initial
        alert.accessoryView = tf
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = tf
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                completion(tf.stringValue)
            }
        }
    }
}
