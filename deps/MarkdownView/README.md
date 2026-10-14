# MarkdownView (vendored)

Limare's message renderer: [Lakr233/MarkdownView](https://github.com/Lakr233/MarkdownView)
**4.8.2** (`a95d4e8d570365fde2267e93e64a067b6c5ab363`), MIT licensed (see `LICENSE`).

Only `Sources/MarkdownView` and `Sources/MarkdownParser` are kept, and `Package.swift` is
trimmed to those two libraries; the dependency requirements are upstream's. Litext, SwiftMath,
swift-collections, swift-cmark and LRUCache still come from their remotes, locked by
`src/macos/Limare.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

## Limare changes

Every change from upstream is listed here; `git log -- deps/MarkdownView` holds the diffs.

1. **The code and table sheets close directly (macOS).** Each sheet's bar has a close (✕)
   button at its trailing end, and a click on the window behind the sheet closes it.
   Upstream closes them only through the sheet's ⋯ menu or Esc.
   Files: `Supplements/SheetMenu.swift`, `Components/TableView/TableSheet.swift`,
   `Components/CodeView/CodeSheet.swift`.
2. **Ordered list numbers are text.** An item's number is typeset as `1.` at the size of its
   text, on its baseline. Upstream draws numbers 0–50 as filled `N.circle.fill` symbols.
   File: `MarkdownTextBuilder/TextBuilder+Do.swift`.
3. **Rendered-text caches are cleared on the main queue.** `LRUCache` clears itself on memory
   pressure from a global queue, which released Litext attachments off the main actor and
   crashed the app. The caches of attributed strings opt out and are cleared by one
   main-queue memory-pressure source. Files: `Supplements/MainActorCachePurge.swift`,
   `MarkdownTextBuilder/MarkdownContent.swift`, `Supplements/InlineNode+Render.swift`,
   `Supplements/InlineCode.swift`.
4. **Soft breaks can render as line breaks.** `MarkdownTheme.softBreaksAreLineBreaks` turns a
   single newline inside a paragraph into a line separator (U+2028) instead of a space, so text
   a person typed keeps its lines. Off by default; Limare turns it on for user messages.
   Files: `MarkdownTheme/MarkdownTheme.swift`, `Supplements/InlineNode+Render.swift`.

## Updating

Copy the two source directories from the new upstream tag over these, re-apply the changes
above (or drop the ones upstream now covers), and update the version line at the top.
