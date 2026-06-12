import AppKit
import UniformTypeIdentifiers

/// Table view with Return-to-edit and a row context menu.
final class EditorTableView: NSTableView {
    var onReturnKey: (() -> Void)?
    var contextMenuBuilder: ((Int) -> NSMenu?)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, let onReturnKey { // return / enter
            onReturnKey()
            return
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

/// Header view that vends a per-column context menu (rename, insert, delete).
final class EditorHeaderView: NSTableHeaderView {
    var contextMenuBuilder: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return contextMenuBuilder?(column(at: point))
    }
}

final class EditorWindowController: NSWindowController, NSWindowDelegate,
    NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuItemValidation {

    let csvDocument = CSVDocument()
    var onClose: ((EditorWindowController) -> Void)?

    private let tableView = EditorTableView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var isSaving = false
    private var customFieldEditor: NSTextView?

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
        tableView.headerView = header
        tableView.contextMenuBuilder = { [weak self] row in self?.rowMenu(forRow: row) }
        tableView.onReturnKey = { [weak self] in self?.editSelectedRow() }
        tableView.target = self
        tableView.doubleAction = #selector(tableDoubleClicked(_:))

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

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
        content.addSubview(statusBar)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
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

    // MARK: - Document lifecycle

    func setUpNewDocument() {
        csvDocument.setUpEmpty()
        window?.title = "Untitled"
        window?.representedURL = nil
        window?.isDocumentEdited = false
        rebuildTableColumns()
        tableView.reloadData()
        updateStatus()
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
    }

    private func markEdited() {
        window?.isDocumentEdited = true
        updateStatus()
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
        cell.textField?.stringValue = csvDocument.value(row: row, col: colIndex)
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
        tf.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
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
        guard let tf = control as? NSTextField else { return false }
        let row = tableView.row(for: tf)
        let col = tableView.column(for: tf)
        guard row >= 0, col >= 0 else { return false }
        switch selector {
        case #selector(NSResponder.insertTab(_:)):
            endEditingAndMove(row: row, col: col, dRow: 0, dCol: 1)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            endEditingAndMove(row: row, col: col, dRow: 0, dCol: -1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            endEditingAndMove(row: row, col: col, dRow: 1, dCol: 0)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            tf.stringValue = csvDocument.value(row: row, col: col)
            window?.makeFirstResponder(tableView)
            return true
        default:
            return false
        }
    }

    private func endEditingAndMove(row: Int, col: Int, dRow: Int, dCol: Int) {
        window?.makeFirstResponder(tableView) // commits via controlTextDidEndEditing
        var r = row + dRow
        var c = col + dCol
        if dCol != 0 {
            if c >= csvDocument.colCount { c = 0; r += 1 }
            if c < 0 { c = csvDocument.colCount - 1; r -= 1 }
        }
        guard r >= 0, r < csvDocument.rowCount, c >= 0, c < csvDocument.colCount else { return }
        editCell(row: r, col: c)
    }

    private func editCell(row: Int, col: Int) {
        guard editsAllowed(), row >= 0, row < csvDocument.rowCount,
              col >= 0, col < csvDocument.colCount else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        tableView.scrollColumnToVisible(col)
        tableView.editColumn(col, row: row, with: nil, select: true)
    }

    private func editSelectedRow() {
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        editCell(row: row, col: 0)
    }

    @objc private func tableDoubleClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        let col = tableView.clickedColumn
        guard row >= 0, col >= 0 else { return }
        editCell(row: row, col: col)
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

    private func performInsertRows(ids: [Int], at indices: [Int], thenEdit: Bool = false) {
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

    private func performRemoveRows(at indices: [Int]) {
        let sorted = indices.sorted()
        let ids = csvDocument.removeRows(at: sorted)
        undoManager?.registerUndo(withTarget: self) { me in me.performInsertRows(ids: ids, at: sorted) }
        undoManager?.setActionName("Delete Rows")
        tableView.removeRows(at: IndexSet(sorted), withAnimation: [])
        markEdited()
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

    private func performAddColumn(named name: String?, at index: Int) {
        _ = csvDocument.addColumn(named: name, at: index)
        undoManager?.registerUndo(withTarget: self) { me in me.performRemoveColumns(at: [index]) }
        undoManager?.setActionName("Add Column")
        rebuildTableColumns()
        tableView.reloadData()
        markEdited()
    }

    private func performRemoveColumns(at indices: [Int]) {
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

    private func performRenameColumn(displayIndex: Int, newName: String?) {
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
