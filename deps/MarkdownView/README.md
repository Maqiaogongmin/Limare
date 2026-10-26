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

5. **Inline code is padded with sized spaces, not attachments.** The 4 pt either side of a
   code span is a space in the code font at the size that makes it 4 pt wide, carrying an
   empty holder attachment (so it still copies as nothing). Upstream uses a run-delegate
   attachment, around which CoreText breaks lines about 40× more slowly: a 140 KB document
   with a thousand code spans took 600 ms to measure at each new width, now 15 ms.
   File: `Supplements/InlineCode.swift`.

6. **Headings are styled per level.** `MarkdownTheme.headings` holds a font and letter spacing
   for each level (`#` first; deeper levels take the last); empty keeps upstream's single
   `fonts.title`. Files: `MarkdownTheme/MarkdownTheme.swift`,
   `MarkdownTextBuilder/BlockProcessor.swift`.
7. **Links have their own colour.** `colors.highlight`, which only ever coloured links, is
   renamed `colors.link`; `colors.linkUnderline` underlines them. Files:
   `MarkdownTheme/MarkdownTheme.swift`, `Supplements/InlineNode+Render.swift`.
8. **Code blocks take a corner radius, an edge and a bar label font from the theme.**
   `sizes.codeBlockCornerRadius` (default 8, as upstream), `colors.codeBlockBorder` (none by
   default) and `fonts.codeBlockLabel` (default: the code font); the block is clipped to its
   corners on macOS so an opaque bar keeps to them, and the bar's height follows the label
   font in both layout and measurement. The language name is shown in lower case at half the
   body's opacity; the bar's buttons are 11 pt glyphs in the secondary label colour.
   Files: `MarkdownTheme/MarkdownTheme.swift`, `Components/CodeView/CodeView.swift`,
   `Components/CodeView/CodeViewConfiguration.swift`, `Components/CodeView/CodeView+Actions.swift`.
9. **Quieter quote bars and bullets.** The quote bar is 2.5 pt wide (upstream 4) at 18% of the
   body colour (upstream 10%); bullets are drawn at `sizes.bullet` diameter (default 6, the
   size upstream hard-coded; upstream's own `sizes.bullet` was unused) at 45% of their text's
   colour. Files: `Components/BlockquoteBarView.swift`, `MarkdownTextBuilder/TextBuilder+Do.swift`,
   `MarkdownTheme/MarkdownTheme.swift`.
10. **Images show as a label, not their URL.** Images are never loaded; upstream wrote an
    image's whole source URL out as body text. It is now an inline-code label of its alternative
    text (its file name when it has none), linked to the source. A link's underline skips
    inline code, whose pill already marks it. File: `Supplements/InlineNode+Render.swift`.
11. **Code blocks can be drawn as a rule, and without line numbers.** `MarkdownTheme.codeBlockStyle`
    is `.card` (upstream's tinted card with a bar; the default) or `.rule`: no fill, edge or bar, a
    `sizes.codeBlockRuleWidth` (default 2) rule down the left in `colors.codeBlockRule` (default 12%
    of `body`), the code 14 pt from the rule and 2 pt from the top and bottom. The language (none
    when the fence names none, instead of `</>`) and the buttons sit on a small `.popover` material
    panel at the top right, faded in while the pointer is over the block and while Copy shows its
    checkmark; hidden, they take no clicks. `showsCodeLineNumbers` (default true) hides the gutter,
    which then takes no width. Measurement and layout read the same insets
    (`CodeViewConfiguration.insets`). UIKit draws `.rule` as `.card`. Files:
    `MarkdownTheme/MarkdownTheme.swift`, `Components/CodeView/CodeView.swift`,
    `Components/CodeView/CodeViewConfiguration.swift`, `Components/CodeView/CodeView+Actions.swift`.
12. **Fences without a language are left uncoloured.** `SyntaxLanguage.named` returns nil (plain
    text) when the info string names no language, so a directory tree or a request log is not
    coloured as code. A name the catalog does not know still gets the shared `.generic` rules,
    as upstream gives every block. File: `Components/CodeView/Syntax/SyntaxLanguage.swift`.

## Updating

Copy the two source directories from the new upstream tag over these, re-apply the changes
above (or drop the ones upstream now covers), and update the version line at the top.
