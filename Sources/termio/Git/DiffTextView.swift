import TermioShared
import AppKit
import SwiftUI

// MARK: - Diff text pane

/// The diff overlay's content: one non-editable `NSTextView` (TextKit 1, matching the
/// editor) holding the whole `DiffDocument`. Line semantics are painted, not stacked —
/// `DiffWashLayoutManager` fills the add/delete washes and band fills behind the text,
/// the gutter ruler draws line numbers and the `+`/`−` signs *outside* the selectable
/// text — so selection runs continuously across lines, copies pure code, and ⌘F opens the
/// same `FileFindBar` the code editor uses (driven by the shared `TextFindEngine`), not
/// AppKit's un-styleable system find bar.
struct DiffTextPane: NSViewRepresentable {
    let document: DiffDocument
    /// Syntax-colored lines by row id (the `DiffHighlighter` pass), applied in place
    /// once they land; the document renders plain until then.
    let styled: [Int: NSAttributedString]
    let font: NSFont
    /// The terminal's `Thicken glyphs`, so a diff and the terminal beside it are smoothed
    /// the same way (see `DiffWashLayoutManager.thickenGlyphs`).
    let thickenGlyphs: Bool
    let backgroundColor: NSColor
    /// Line-number ink, from the shared `gutterInk(for:)` so the diff's gutter and the
    /// file editor's read as one family.
    let numberColor: NSColor
    /// Splices a band's hidden lines back in, from the end the reader asked for
    /// (rebuilds the document upstream).
    let onExpand: (Int, DiffBandDirection) -> Void
    /// ← / → sibling walk; returns false at either end so the press dies quietly.
    let onWalk: (Int) -> Bool
    let onClose: () -> Void
    /// Wrap long lines to the pane's width. Off for a split column, where a wrapped line would
    /// fold into a different number of fragments on each side and pull the two panes' rows out
    /// of step; panes that share a `scrollSync` pan together instead.
    var wraps: Bool = true
    /// Keeps this pane's viewport locked to the pane beside it (see `DiffPaneScrollSync`).
    var scrollSync: DiffPaneScrollSync? = nil
    /// Which half of a synced pair this pane is.
    var paneSide: DiffPaneScrollSync.Side? = nil
    /// Fixed gutter geometry (a split pair shares one); nil derives it from the document.
    var gutterMetrics: DiffGutterMetrics? = nil
    /// The pane took the keyboard — a split diff searches the pane the reader is in.
    var onActivate: (() -> Void)? = nil
    /// Whether the pane claims first responder on appear. Off for the second pane of a split
    /// pair, so which column starts focused does not depend on the order SwiftUI mounts them.
    var autoFocuses: Bool = true
    /// Find state driven by the overlay's `FileFindBar` — empty query paints nothing.
    var findQuery: String = ""
    var findOptions: FindOptions = FindOptions()
    /// The row to highlight and reveal, by row id rather than by index: the same row exists in
    /// both columns of a split diff, and both columns should light it up. Ignored on an empty
    /// query or a row this pane does not carry.
    var findFocusedRow: Int? = nil
    /// Fires with the rows this pane matched, in document order, after any recompute.
    var onMatchesChanged: (([Int]) -> Void)? = nil
    /// Bumped when the find bar closes, so the text view reclaims first responder and its
    /// ← / → walk and Esc work again.
    var reclaimFocus: Int = 0
    /// Whether bumping `reclaimFocus` moves the keyboard here. The other pane of a split pair
    /// still takes the token — so its own next activation does not replay an old one — but does
    /// not pull the keyboard out of the column the reader is in.
    var reclaimsFocus: Bool = true
    /// Embedded mode: the pane is stacked inside an outer scroll (the multi-file card list), so it
    /// must not scroll or grab focus itself — it grows to its content and reports that height back so
    /// the SwiftUI card can size to it, letting the outer list own the scroll.
    var embedded: Bool = false
    var onContentHeight: ((CGFloat) -> Void)? = nil
    /// "Add to Chat" in the right-click menu: the argument is the selected diff text,
    /// `nil` when nothing is selected (the owner inserts the diffed file's path instead).
    /// Left `nil` where the pane has no chat to feed (the embedded PR file cards).
    var addToChat: ((String?) -> Void)? = nil
    var canAddToChat: (() -> Bool)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// A built pane: the scroll view the representable hands back, plus the pieces its
    /// coordinator wires up.
    struct PaneViews {
        let scrollView: NSScrollView
        let textView: DiffTextView
        let layoutManager: DiffWashLayoutManager
        let container: NSTextContainer
        let ruler: DiffGutterRulerView
    }

    /// Builds a pane's view hierarchy. Kept out of `makeNSView` so tests can lay the same views
    /// out: the wrapping shape *is* the mechanism behind a split column's horizontal scrolling,
    /// and "a long line runs off the column instead of folding" is worth pinning against real
    /// TextKit rather than argued from the flags.
    static func makeViews(wraps: Bool, embedded: Bool, showsVerticalScroller: Bool,
                          backgroundColor: NSColor, numberColor: NSColor,
                          font: NSFont) -> PaneViews {
        let storage = NSTextStorage()
        let layoutManager = DiffWashLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer()
        // Soft-wrap to the panel width — the inline pane. A split column turns this off and lets
        // the container grow with the text, so the scroll view scrolls sideways instead of folding
        // long lines into fragments the column beside it cannot match.
        container.widthTracksTextView = wraps
        if !wraps {
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                            height: CGFloat.greatestFiniteMagnitude)
        }
        // Horizontal breathing room lives here, not in textContainerInset: AppKit clips
        // all layout-manager drawing to the inset region, so an inset would leave an
        // unpaintable blank strip splitting the gutter's wash band from the text's.
        container.lineFragmentPadding = 11
        layoutManager.addTextContainer(container)

        let textView = DiffTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.textContainerInset = NSSize(width: 0, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = !wraps
        textView.autoresizingMask = wraps ? [.width] : []
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        // The pair scrolls as one surface: the left column keeps its scrollbars off the seam
        // between them, so the hairline divider reads as a divider rather than a bulkhead.
        scrollView.hasVerticalScroller = showsVerticalScroller
        scrollView.hasHorizontalScroller = !wraps
        // Embedded panes are sized to their content by the SwiftUI card, so they never actually scroll
        // — but keep the scroll view otherwise standard (only auto-hide the overlay scroller) so its
        // ruler still lays out to the full height. Disabling the scroller knocks the gutter short.
        if !wraps || embedded {
            scrollView.autohidesScrollers = true
            scrollView.scrollerStyle = .overlay
        }
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = backgroundColor
        // Paint the clip view the same color so the ruler/text seam can never show as a hairline.
        scrollView.contentView.drawsBackground = true
        scrollView.contentView.backgroundColor = backgroundColor

        let ruler = DiffGutterRulerView(scrollView: scrollView, codeFont: font,
                                        gutterColor: backgroundColor,
                                        numberColor: numberColor)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        return PaneViews(scrollView: scrollView, textView: textView,
                         layoutManager: layoutManager, container: container, ruler: ruler)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let views = Self.makeViews(wraps: wraps, embedded: embedded,
                                   showsVerticalScroller: wraps || paneSide != .left,
                                   backgroundColor: backgroundColor, numberColor: numberColor,
                                   font: font)
        let scrollView = views.scrollView
        let textView = views.textView
        let layoutManager = views.layoutManager
        let ruler = views.ruler
        textView.onExpand = onExpand
        textView.onWalk = onWalk
        textView.onClose = onClose
        textView.addToChat = addToChat
        textView.canAddToChat = canAddToChat
        context.coordinator.onActivate = onActivate
        textView.onActivate = onActivate
        if let scrollSync, let paneSide { scrollSync.register(scrollView, side: paneSide) }

        // The ruler must fully redraw on three events: content changes and the view
        // re-wrapping on resize (both via the text view's frame changes), and —
        // crucially — *scrolling*. AppKit's copy-on-scroll only repaints the newly
        // exposed strip, so without a full invalidation the gutter's absolutely
        // positioned numbers desync into a garbled smear (the editor's ruler learned
        // this the hard way).
        context.coordinator.scrollView = scrollView
        context.coordinator.embedded = embedded
        context.coordinator.onContentHeight = onContentHeight
        context.coordinator.scrollSync = scrollSync
        context.coordinator.paneSide = paneSide

        textView.postsFrameChangedNotifications = true
        context.coordinator.observeFrame(of: textView)
        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observeScroll(of: scrollView)

        apply(to: textView, layoutManager: layoutManager, ruler: ruler,
              coordinator: context.coordinator)
        context.coordinator.reportHeightIfNeeded()

        // Keys (← → walk, Esc) should work the moment the overlay lands, without a click first —
        // but an embedded pane must not steal focus (many stacked panes would fight over it).
        if !embedded, autoFocuses {
            DispatchQueue.main.async { [weak textView] in
                guard let textView, let window = textView.window else { return }
                if window.firstResponder === window || window.firstResponder is NSTextView == false {
                    window.makeFirstResponder(textView)
                }
            }
        }
        return scrollView
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.scrollSync?.unregister(scrollView, side: coordinator.paneSide)
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? DiffTextView,
              let layoutManager = textView.layoutManager as? DiffWashLayoutManager,
              let ruler = context.coordinator.ruler else { return }
        textView.onExpand = onExpand
        textView.onWalk = onWalk
        textView.onClose = onClose
        textView.onActivate = onActivate
        context.coordinator.onActivate = onActivate
        context.coordinator.scrollSync = scrollSync
        context.coordinator.paneSide = paneSide
        // Re-assign per update: the closures capture the CURRENT request (← / → walks
        // swap the diffed file in place), so a stale capture would insert the previous
        // file's path.
        textView.addToChat = addToChat
        textView.canAddToChat = canAddToChat
        scrollView.backgroundColor = backgroundColor
        scrollView.contentView.backgroundColor = backgroundColor
        textView.backgroundColor = backgroundColor
        let documentChanged = context.coordinator.appliedDocument !== document
        apply(to: textView, layoutManager: layoutManager, ruler: ruler,
              coordinator: context.coordinator)
        if documentChanged { context.coordinator.invalidateFind() }

        context.coordinator.onMatchesChanged = onMatchesChanged
        context.coordinator.updateFind(query: findQuery, options: findOptions,
                                       focusedRow: findFocusedRow, in: textView)
        context.coordinator.reclaimFocusIfNeeded(reclaimFocus, in: textView)

        context.coordinator.onContentHeight = onContentHeight
        // A band-expand or a syntax pass changes the content height; re-measure so the card resizes.
        context.coordinator.reportHeightIfNeeded()
    }

    /// Swaps the document in when it changed (initial load, band expand) and lays the
    /// syntax colors over it when they land — both idempotent against re-renders.
    private func apply(to textView: DiffTextView, layoutManager: DiffWashLayoutManager,
                       ruler: DiffGutterRulerView, coordinator: Coordinator) {
        textView.backgroundColor = backgroundColor
        layoutManager.thickenGlyphs = thickenGlyphs
        if coordinator.appliedDocument !== document {
            coordinator.appliedDocument = document
            coordinator.appliedStyled = nil
            layoutManager.document = document
            textView.document = document
            textView.textStorage?.setAttributedString(document.attributed)
        }
        // Outside the document-identity check so a theme change re-inks the gutter of an
        // already-open diff, matching the editor's every-update restyle.
        ruler.onExpand = onExpand
        ruler.configure(document: document, codeFont: font, gutterColor: backgroundColor,
                        numberColor: numberColor, metrics: gutterMetrics)
        // A dictionary identity check, not equality: the highlight pass lands at most
        // once per load, so pointer-style diffing by count is enough and O(1).
        if !styled.isEmpty, coordinator.appliedStyled != styled.count {
            coordinator.appliedStyled = styled.count
            applyStyled(to: textView)
        }
    }

    /// Lays the highlighter's colors (and any bold/italic trait fonts) over the plain
    /// document in place — geometry-stable for same-width fonts, so the scroll
    /// position holds while the colors fade in.
    private func applyStyled(to textView: DiffTextView) {
        guard let storage = textView.textStorage else { return }
        storage.beginEditing()
        for line in document.lines where !line.isBand {
            guard let colored = styled[line.rowId],
                  colored.length == line.range.length - 1 else { continue }
            colored.enumerateAttributes(in: NSRange(location: 0, length: colored.length)) { attrs, range, _ in
                var overlay: [NSAttributedString.Key: Any] = [:]
                if let color = attrs[.foregroundColor] as? NSColor { overlay[.foregroundColor] = color }
                if let font = attrs[.font] as? NSFont { overlay[.font] = font }
                guard !overlay.isEmpty else { return }
                storage.addAttributes(overlay, range: NSRange(
                    location: line.range.location + range.location, length: range.length))
            }
        }
        storage.endEditing()
    }

    @MainActor
    final class Coordinator {
        var appliedDocument: DiffDocument?
        var appliedStyled: Int?
        weak var ruler: DiffGutterRulerView?
        var onMatchesChanged: (([Int]) -> Void)?
        var onActivate: (() -> Void)?
        var scrollSync: DiffPaneScrollSync?
        var paneSide: DiffPaneScrollSync.Side?
        // Embedded (card-stacked) sizing: measure the laid-out content and hand its height to SwiftUI.
        weak var scrollView: NSScrollView?
        var embedded = false
        var onContentHeight: ((CGFloat) -> Void)?
        var reclaimsFocus = true
        private var reportedHeight: CGFloat = -1

        /// Measure the text's laid-out height and report it (once, on change) so the SwiftUI card sizes
        /// to fit and the outer list scrolls. No-op unless embedded.
        func reportHeightIfNeeded() {
            guard embedded, let scrollView,
                  let textView = scrollView.documentView as? DiffTextView,
                  let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let height = layoutManager.usedRect(for: container).height
                + textView.textContainerInset.height * 2
            guard abs(height - reportedHeight) > 0.5 else { return }
            reportedHeight = height
            let callback = onContentHeight
            DispatchQueue.main.async { callback?(height) }
        }
        /// The same incremental-find engine the code editor uses — highlights and semantics
        /// stay identical across the two ⌘F surfaces.
        private let find = TextFindEngine()
        private var appliedFindQuery: String = ""
        private var appliedFindOptions: FindOptions = FindOptions()
        private var appliedFocusedRow: Int?
        /// The row each match landed on, parallel to `find.matches`. One list, two questions:
        /// which rows matched (the split pair merges on them) and which local match to paint.
        private var matchRows: [Int] = []
        /// The last list handed upstream, so a repaint does not re-report it.
        private var reportedRows: [Int] = []
        private var appliedReclaim: Int = 0

        /// Recompute + repaint after a new query, option change, or focus move (the diff is
        /// read-only, so there's no edit path to keep matches in sync with — unlike the editor).
        func updateFind(query: String, options: FindOptions, focusedRow: Int?, in textView: NSTextView) {
            let queryChanged = query != appliedFindQuery || options != appliedFindOptions
            if queryChanged {
                appliedFindQuery = query
                appliedFindOptions = options
                find.recompute(query: query, options: options, in: textView)
                matchRows = rows(for: find.matches)
                notifyMatchRows()
                appliedFocusedRow = nil
            }
            // Unrelated re-renders (a sibling walk, a theme change) flow through here too — only
            // repaint when the query, options, or focused row actually moved.
            guard queryChanged || focusedRow != appliedFocusedRow else { return }
            find.paint(focused: matchIndex(of: focusedRow), reveal: focusedRow != nil, in: textView)
            appliedFocusedRow = focusedRow
        }

        /// The row a match opens on, so a split pair can merge the two columns' hits: a context
        /// line matches in both columns but is one line, and counting it twice would misreport the
        /// diff. A match in a paragraph's own newline has no line to name, so it is dropped.
        private func rows(for matches: [NSRange]) -> [Int] {
            guard let document = appliedDocument else { return [] }
            return matches.compactMap { document.line(at: $0.location)?.rowId }
        }

        private func matchIndex(of row: Int?) -> Int {
            guard let row else { return -1 }
            return matchRows.firstIndex(of: row) ?? -1
        }

        /// A band-expand rebuilds the document, wiping the highlights and shifting offsets, so
        /// force the next `updateFind` to recompute against the fresh text.
        func invalidateFind() {
            appliedFindQuery = ""
            appliedFindOptions = FindOptions()
            appliedFocusedRow = nil
            matchRows = []
            reportedRows = []
        }

        /// Closing the find bar hands the keyboard back to the text view so ← / → and Esc work.
        func reclaimFocusIfNeeded(_ token: Int, in textView: NSTextView) {
            guard token != appliedReclaim else { return }
            appliedReclaim = token
            guard reclaimsFocus else { return }
            textView.window?.makeFirstResponder(textView)
        }

        private func notifyMatchRows() {
            guard matchRows != reportedRows else { return }
            reportedRows = matchRows
            let callback = onMatchesChanged
            let rows = matchRows
            DispatchQueue.main.async { callback?(rows) }
        }

        func observeFrame(of textView: NSTextView) {
            NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: textView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.ruler?.needsDisplay = true
                    // A width change re-wraps the text, so the content height moves — re-measure.
                    self?.reportHeightIfNeeded()
                }
            }
        }

        func observeScroll(of scrollView: NSScrollView) {
            NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.ruler?.needsDisplay = true
                    // A split pair is one viewport: whichever pane moved, the other follows.
                    // Read through `scrollView` rather than the notification: the observer is
                    // registered on that clip view, and the object itself is not sendable into
                    // this closure.
                    guard let side = self.paneSide,
                          let clipView = self.scrollView?.contentView else { return }
                    self.scrollSync?.scrolled(clipView, from: side)
                }
            }
        }
    }
}

// MARK: - Text view

/// Keeps two split panes on one viewport. Both documents carry the same rows in the same
/// order, so a single offset is the right answer for both: the same y is the same line, and
/// the same x is the same column of code. Only one direction is ever live — the pane the
/// reader moved pushes the other, and the push it echoes back is ignored rather than bounced
/// between them. Everything here is main-thread AppKit state, driven from the panes'
/// bounds-change notifications.
final class DiffPaneScrollSync {
    enum Side: Sendable, Equatable { case left, right }

    private weak var left: NSClipView?
    private weak var right: NSClipView?
    /// The offset this object last pushed, and into which pane. The echoed notification comes
    /// back through the same handler as a reader's scroll, and this is what tells them apart.
    private var pushed: (side: Side, origin: NSPoint)?

    func register(_ scrollView: NSScrollView, side: Side) {
        switch side {
        case .left: left = scrollView.contentView
        case .right: right = scrollView.contentView
        }
    }

    func unregister(_ scrollView: NSScrollView, side: Side?) {
        switch side {
        case .left: if left === scrollView.contentView { left = nil }
        case .right: if right === scrollView.contentView { right = nil }
        case nil: break
        }
    }

    func scrolled(_ clipView: NSClipView, from side: Side) {
        if let pushed, pushed.side == side, pushed.origin == clipView.bounds.origin {
            self.pushed = nil
            return
        }
        let peer = side == .left ? right : left
        guard let peer, peer.bounds.origin != clipView.bounds.origin else { return }
        pushed = (side == .left ? .right : .left, clipView.bounds.origin)
        peer.scroll(to: clipView.bounds.origin)
        peer.enclosingScrollView?.reflectScrolledClipView(peer)
        // A horizontal move drags the gutter's washes sideways with the text, so both panes
        // repaint; the vertical case is already covered by the ruler's own invalidation.
        peer.enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }
}

/// The diff's text view: read-only but selectable, with the overlay's keys folded in —
/// ← / → walk the sibling files, Esc closes, ↑ / ↓ stay with scrolling (there is no
/// caret to move), and a click on an expandable band splices its lines back in.
final class DiffTextView: NSTextView {
    var document: DiffDocument?
    var onExpand: ((Int, DiffBandDirection) -> Void)?
    var onWalk: ((Int) -> Bool)?
    var onClose: (() -> Void)?
    /// "Add to Chat": the argument is the selected diff text (`nil` = no selection,
    /// the owner inserts the diffed file's path). Gate read at menu-open time.
    var addToChat: ((String?) -> Void)?
    var canAddToChat: (() -> Bool)?
    /// The pane took the keyboard. A split diff reads it to know which column the reader is
    /// working in — the one ⌘F searches and the find bar's arrows walk.
    var onActivate: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onActivate?() }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        let hasModifiers = !event.modifierFlags
            .intersection([.command, .option, .control, .shift]).isEmpty
        if !hasModifiers {
            switch event.keyCode {
            case 123: _ = onWalk?(-1); return    // ← — dies quietly at either end
            case 124: _ = onWalk?(+1); return    // →
            case 125: scroll(byLines: +3); return
            case 126: scroll(byLines: -3); return
            case 53: onClose?(); return          // Esc (find bar handles its own first)
            default: break
            }
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }

    /// A minimal right-click menu: Copy, plus Close. NSTextView's default would inject
    /// the read-only text grab-bag (Look Up / Translate / Speech / Share / Services) a
    /// diff has no use for; returning our own menu — without calling `super` — drops all
    /// of it, matching the editor's and reader's stripped menus.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.allowsContextMenuPlugIns = false
        // Not `copy:`: macOS 26 decorates the standard editing selectors with a system symbol
        // that `image = nil` cannot clear, and the rest of this menu is plain text.
        menu.addItem(withTitle: localized("Copy"), action: #selector(copySelection), keyEquivalent: "")
        if canAddToChat?() == true {
            menu.addItem(.separator())
            // One name everywhere (Cursor's): a selection goes over as the pasted
            // snippet, none means the diffed file's path — context says which.
            let add = NSMenuItem(title: localized("Add to Chat"), action: #selector(addToChatAction), keyEquivalent: "")
            add.target = self
            menu.addItem(add)
        }
        if onClose != nil {
            menu.addItem(.separator())
            let close = NSMenuItem(title: localized("Close"), action: #selector(closeFromMenu), keyEquivalent: "")
            close.target = self
            menu.addItem(close)
        }
        return menu
    }

    @objc private func addToChatAction() {
        let range = selectedRange()
        let selection = range.length > 0 ? (string as NSString).substring(with: range) : nil
        addToChat?(selection)
    }

    @objc private func closeFromMenu() { onClose?() }

    @objc private func copySelection(_ sender: Any?) { copy(sender) }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copySelection) { return selectedRange().length > 0 }
        return super.validateUserInterfaceItem(item)
    }

    override func mouseDown(with event: NSEvent) {
        // The row itself is the "show me the whole gap" target; the gutter's chevrons
        // reveal it a screenful at a time.
        if let anchor = expandableBand(atViewPoint: convert(event.locationInWindow, from: nil)) {
            onExpand?(anchor, .all)
            return
        }
        super.mouseDown(with: event)
    }

    /// The band under a click, hit anywhere across the row (the nearest-glyph mapping
    /// clamps horizontally; the fragment-rect check rejects clicks past the last line).
    /// Takes a point in this view's own coordinates, so the reveal rule can be exercised
    /// without a window or an event stream — `super.mouseDown` tracks the mouse until a
    /// mouse-up arrives, which a test has no way to deliver.
    func expandableBand(atViewPoint point: NSPoint) -> Int? {
        guard let document, let layoutManager, let textContainer else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: local, in: textContainer)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let padding = DiffDocument.bandPadding
        guard local.y >= fragment.minY - padding, local.y <= fragment.maxY + padding else { return nil }
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        guard let line = document.line(at: character), line.isRevealable else { return nil }
        return line.rowId
    }

    /// ⌘C copies the selected *code* — band labels are chrome, not content, so a
    /// selection sweeping across one drops the "n unchanged lines" text on the way
    /// to the pasteboard. (The gutter never needs stripping; it lives in the ruler.)
    override func copy(_ sender: Any?) {
        guard let document else { return super.copy(sender) }
        let content = string as NSString
        var pieces: [String] = []
        for value in selectedRanges {
            let selection = value.rangeValue
            guard selection.length > 0 else { continue }
            var kept = ""
            var index = document.lineIndex(at: selection.location)
            while index < document.lines.count {
                let line = document.lines[index]
                let overlap = NSIntersectionRange(line.range, selection)
                if overlap.length == 0, line.range.location >= NSMaxRange(selection) { break }
                if overlap.length > 0, !line.isBand {
                    kept += content.substring(with: overlap)
                }
                index += 1
            }
            if !kept.isEmpty { pieces.append(kept) }
        }
        guard !pieces.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(pieces.joined(separator: "\n"), forType: .string)
    }

    private func scroll(byLines delta: CGFloat) {
        guard let clip = enclosingScrollView?.contentView else { return }
        let lineHeight = layoutManager?.defaultLineHeight(for: font ?? .systemFont(ofSize: 12)) ?? 14
        var origin = clip.bounds.origin
        origin.y += delta * lineHeight
        clip.scroll(to: clip.constrainBoundsRect(
            NSRect(origin: origin, size: clip.bounds.size)).origin)
        enclosingScrollView?.reflectScrolledClipView(clip)
    }
}

// MARK: - Layout manager

/// Paints the diff's line semantics behind the text: full-width add/delete washes and
/// the bands' faint fills. Runs before `super.drawBackground`, so TextKit's own pass
/// (the intraline-emphasis `.backgroundColor` spans, the selection highlight) always
/// composites on top.
final class DiffWashLayoutManager: NSLayoutManager {
    var document: DiffDocument?
    /// Follows the terminal's `Thicken glyphs`. Ghostty rasterizes its own glyphs and only
    /// dilates them when that switch is on, while AppKit smooths every glyph it draws — so
    /// the same face at the same size reads heavier in a diff than in the terminal one pane
    /// over. Turning smoothing off with the switch keeps one setting over both surfaces.
    var thickenGlyphs = false

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if !thickenGlyphs {
            NSGraphicsContext.current?.cgContext.setShouldSmoothFonts(false)
        }
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let document, let container = textContainers.first {
            let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            // Washes span the full panel width, not just the laid-out text.
            let width = max(usedRect(for: container).width + origin.x,
                            container.textView?.bounds.width ?? 0)
            var index = document.lineIndex(at: charRange.location)
            while index < document.lines.count {
                let line = document.lines[index]
                index += 1
                if line.range.location >= NSMaxRange(charRange) { break }
                guard let fill = document.palette.wash(for: line.role) else { continue }
                let glyphs = glyphRange(forCharacterRange: line.range, actualCharacterRange: nil)
                var rect = boundingRect(forGlyphRange: glyphs, in: container)
                rect.origin.x = 0
                rect.size.width = width
                rect.origin.y += origin.y
                if line.isBand { rect = rect.insetBy(dx: 0, dy: -DiffDocument.bandPadding) }
                fill.setFill()
                rect.fill()
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}
