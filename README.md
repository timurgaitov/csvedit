# csvedit

A native macOS CSV editor built for responsiveness on huge files. Pure Swift +
AppKit, no dependencies, no Xcode project — builds with the command line tools.

## Why Swift and not Zig

The UI has to be AppKit to feel native, and driving AppKit from Zig means
hand-writing Objective-C runtime glue for every control. Swift gives the same
low-level control where it matters — the hot paths below run on raw mapped
bytes with no bounds-checked abstractions in the way — and first-class AppKit
everywhere else.

## How it stays fast

- **Memory-mapped files.** Opening a file never reads it into memory; the OS
  pages bytes in on demand. A 1 GB file opens instantly.
- **Background indexing.** A quote-aware byte scanner finds row offsets off the
  main thread (~1.6 GB/s) and streams batches to the UI, so the table fills in
  live while big files index. Only row *offsets* are stored — 8 bytes per row.
- **Lazy parsing.** Rows are split into fields only when they scroll into view
  (~0.7 µs/row), with a small cache for the visible region.
- **Sparse edit overlay.** Edits, added/deleted rows and columns live in small
  dictionaries keyed by stable row IDs. The file content is never copied.
- **Raw-copy saves.** On save, untouched rows are streamed byte-for-byte from
  the mapped file (~640 MB/s); only edited rows are re-encoded. Saves go to a
  temp file and replace the original atomically.

## Build & run

```sh
./build.sh          # produces build/csvedit.app
open build/csvedit.app
```

## Tests

```sh
./test.sh
```

Two suites:

- **Engine tests** — RFC 4180 parsing (quotes, escaped quotes, embedded
  newlines, CRLF), delimiter detection (`,` `;` tab `|`), edit/save round
  trips, and a 1M-row performance benchmark.
- **UI integration tests** — boot a real `NSApplication` and drive real
  window controllers in-process: open → render → edit → undo/redo →
  row/column ops → async save → reopen, asserting on document state and the
  bytes written to disk. No accessibility permissions needed; windows appear
  briefly on screen while they run.

## Features

- Open / edit / save CSV, TSV, semicolon- and pipe-delimited files
  (delimiter auto-detected; preserved on save)
- In-place cell editing: double-click or press Return; Tab / Shift-Tab /
  Return navigate between cells while editing, Esc cancels
- Insert/delete rows (context menu, Table menu, ⌘⏎ / ⌘⌫)
- Add/rename/delete columns (right-click the column header)
- "First Row Is Header" toggle (Table menu)
- Undo/redo for cell edits and all structural changes
- Copy selected rows as tab-separated text (⌘C)
- Multiple windows, unsaved-changes prompt on close
- Status bar: row/column counts, file size, delimiter, indexing progress

## Known limits

- Sorting and find are not implemented yet.
- Column reordering by dragging headers is disabled.
- "First Row Is Header" can only be toggled before making edits.
