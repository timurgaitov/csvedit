# csvedit

A fast, native macOS CSV editor.

![csvedit](screenshot.png)

## Install

```sh
brew install --cask timurgaitov/tap/csvedit
```

The app isn't notarized yet — if macOS blocks the first launch, right-click
the app in Finder and choose **Open**.

Or build from source (requires only the Xcode command line tools):

```sh
./build.sh && open build/csvedit.app
```

## Keyboard shortcuts

Navigation and editing:

| Key | Action |
| --- | --- |
| `↑` `↓` `←` `→` or `h` `j` `k` `l` | Move between cells |
| `⏎` or `e` | Edit the current cell |
| `⇥` / `⇧⇥` / `⏎` (while editing) | Commit and move right / left / down |
| `esc` (while editing) | Cancel the edit |

Find:

| Key | Action |
| --- | --- |
| `⌘F` or `/` | Open find |
| `⏎` / `⇧⏎` | Next / previous match |
| `⌘⏎` | Edit the matched cell |
| `esc` | Close find |

Other:

| Key | Action |
| --- | --- |
| `⌘⏎` | Add row below |
| `⌘⌫` | Delete selected rows |
| `⌘+` / `⌘−` / `⌘0` | Zoom font size |
| `⌘S` / `⌘⇧S` | Save / Save As |
| `⌘Z` / `⌘⇧Z` | Undo / Redo |
