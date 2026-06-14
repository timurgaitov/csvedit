import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [EditorWindowController] = []
    private var cascadePoint = NSPoint.zero

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        newDocument(nil)
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        for path in filenames {
            openURL(URL(fileURLWithPath: path))
        }
        sender.reply(toOpenOrPrint: .success)
    }

    // MARK: - Actions

    @objc func newDocument(_ sender: Any?) {
        let controller = makeController()
        controller.setUpNewDocument()
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            for url in panel.urls {
                self?.openURL(url)
            }
        }
    }

    func openURL(_ url: URL) {
        let controller = makeController()
        controller.loadFile(at: url)
    }

    private func makeController() -> EditorWindowController {
        let controller = EditorWindowController()
        controller.onClose = { [weak self] ctrl in
            self?.controllers.removeAll { $0 === ctrl }
        }
        controllers.append(controller)
        if let window = controller.window {
            cascadePoint = window.cascadeTopLeft(from: cascadePoint)
        }
        controller.showWindow(nil)
        return controller
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let main = NSMenu()

        // App menu
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About csvedit",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide csvedit",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit csvedit",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(appMenu, title: "csvedit"))

        // File
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New", action: #selector(newDocument(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenu.addItem(withTitle: "Save", action: #selector(EditorWindowController.saveDocument(_:)), keyEquivalent: "s")
        let saveAs = fileMenu.addItem(withTitle: "Save As…",
                                      action: #selector(EditorWindowController.saveDocumentAs(_:)),
                                      keyEquivalent: "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        main.addItem(submenu(fileMenu, title: "File"))

        // Edit
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: #selector(EditorWindowController.undo(_:)), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo",
                                    action: #selector(EditorWindowController.redo(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Find…",
                         action: #selector(EditorWindowController.showFind(_:)), keyEquivalent: "f")
        editMenu.addItem(withTitle: "Go to Line…",
                         action: #selector(EditorWindowController.goToLine(_:)), keyEquivalent: "g")
        main.addItem(submenu(editMenu, title: "Edit"))

        // View
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Increase Font Size",
                         action: #selector(EditorWindowController.increaseFontSize(_:)),
                         keyEquivalent: "+")
        // ⌘= (the unshifted key) must work too, like every macOS app.
        let increaseAlt = viewMenu.addItem(withTitle: "Increase Font Size",
                                           action: #selector(EditorWindowController.increaseFontSize(_:)),
                                           keyEquivalent: "=")
        increaseAlt.isHidden = true
        increaseAlt.allowsKeyEquivalentWhenHidden = true
        viewMenu.addItem(withTitle: "Decrease Font Size",
                         action: #selector(EditorWindowController.decreaseFontSize(_:)),
                         keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Actual Size",
                         action: #selector(EditorWindowController.resetFontSize(_:)),
                         keyEquivalent: "0")
        main.addItem(submenu(viewMenu, title: "View"))

        // Table
        let tableMenu = NSMenu(title: "Table")
        let addRow = tableMenu.addItem(withTitle: "Add Row",
                                       action: #selector(EditorWindowController.addRowBelow(_:)),
                                       keyEquivalent: "\r")
        addRow.keyEquivalentModifierMask = [.command]
        let deleteRows = tableMenu.addItem(withTitle: "Delete Selected Rows",
                                           action: #selector(EditorWindowController.deleteSelectedRows(_:)),
                                           keyEquivalent: "\u{08}")
        deleteRows.keyEquivalentModifierMask = [.command]
        tableMenu.addItem(.separator())
        tableMenu.addItem(withTitle: "Add Column…",
                          action: #selector(EditorWindowController.addColumnAtEnd(_:)),
                          keyEquivalent: "")
        tableMenu.addItem(.separator())
        tableMenu.addItem(withTitle: "First Row Is Header",
                          action: #selector(EditorWindowController.toggleFirstRowHeader(_:)),
                          keyEquivalent: "")
        main.addItem(submenu(tableMenu, title: "Table"))

        // Window
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        main.addItem(submenu(windowMenu, title: "Window"))
        NSApp.windowsMenu = windowMenu

        return main
    }

    private func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
