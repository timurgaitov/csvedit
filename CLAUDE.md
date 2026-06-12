# csvedit

Native macOS CSV editor (Swift + AppKit, no dependencies, no Xcode project).
Performance is the product: never block the main thread, never load or copy
the whole file.

## Build, test, run

```sh
./build.sh                                   # -> build/csvedit.app (swiftc -O -wmo)
open build/csvedit.app /tmp/some.csv

./test.sh    # engine tests (parsing, saves, 1M-row perf benchmark)
             # + in-process UI tests (real NSApplication + controller)
```

- test.sh copies test files to `main.swift` because they have top-level code.
- UI tests (`test/ui_test.swift`) drive the real EditorWindowController and
  NSTableView in-process — no accessibility permissions needed; windows flash
  briefly on screen. They must call `settle()` between undo-registering
  actions: NSUndoManager groups registrations per run-loop turn.
- Build uses `-swift-version 5`: the code is not strict-concurrency clean.
- Baseline perf on M-series (regressions matter): index ~1.6 GB/s,
  parse ~0.7 µs/row, save ~640 MB/s.

## Architecture

- `Sources/CSVTable.swift` — read-only mmap'd file. Background byte scan finds
  row start offsets (quote-aware; only offsets are stored, 8 B/row). Fields
  parsed lazily per row. **`safeRowCount`, not `rowStarts.count`**: during
  indexing the last discovered row has no known end yet and must not be read.
- `Sources/Document.swift` — `CSVDocument`: CSVTable + sparse edit overlay.
  Rows have stable IDs: `< newRowIDBase` (1<<40) = file data-row index,
  `>=` = editor-added. `rowIDs` stays nil (identity mapping) until the first
  row insert/delete. Columns: `colMap` maps display→logical; logical
  `>= fileColCount` = added column, values exist only in `cellEdits`.
  Save fast path requires `colMap` to be the identity — then unedited rows are
  raw byte-copied; any column change re-encodes every row.
- `Sources/EditorWindow.swift` — window controller + NSTableView (view-based,
  lazy). All undo registration lives here, not in CSVDocument.
- `Sources/AppDelegate.swift` — menus (built in code), multi-window, file open.

## Invariants / gotchas

- All CSVDocument mutation on the main thread. `performSave` may run on a
  background queue, but only while the UI blocks edits (`isSaving`).
  Background reads must pass `useCache: false` (the row cache is not locked).
- **Saving does NOT reload the file.** The model equals what was written, and
  the old mmap stays valid (replaced inode lives until unmapped). Reloading
  caused a visible blink — don't reintroduce it. Undo history survives saves.
- Structural row edits are disabled until indexing completes (`rowIDs` would
  freeze the row count mid-index). Cell edits are safe anytime.
- The controller property is `csvDocument` because NSWindowController already
  has a `document: AnyObject?` property — don't rename it back.
- The controller owns `docUndoManager` and overrides `undoManager` /
  implements windowWillReturnUndoManager. NSWindowController's inherited
  undoManager resolves via the nil `document` and returns nil — relying on it
  silently breaks all undo (shipped broken in 1.0.0; caught by the UI tests).
- The custom field editor (windowWillReturnFieldEditor) has undo disabled on
  purpose: in-cell typing must not pollute the document undo stack.
- "First Row Is Header" toggle is only valid on a clean document (row IDs are
  header-offset dependent).

## Releasing (Homebrew)

Distributed via cask: `brew install --cask timurgaitov/tap/csvedit`.

1. Bump `CFBundleVersion` + `CFBundleShortVersionString` in Info.plist.
2. `./build.sh && ditto -c -k --keepParent build/csvedit.app csvedit-X.Y.Z.zip`
3. `git tag vX.Y.Z && git push origin vX.Y.Z`, then
   `gh release create vX.Y.Z csvedit-X.Y.Z.zip`
4. Update `version` and `sha256` in `Casks/csvedit.rb` in
   github.com/timurgaitov/homebrew-tap.

App is ad-hoc signed, not notarized — other Macs hit Gatekeeper on first
launch (cask caveats explain the workaround). Official homebrew-cask
submission is blocked on notarization + notability (~225 stars for
self-submission).
