import TermioShared
import AppKit
import SwiftUI

// MARK: - Diff overlay

/// A read-only unified diff that covers the terminal pane — the git counterpart of
/// `FilePreviewView`/`FileEditorView`, driven by `store.openDiff`. The content is one
/// TextKit view holding the whole diff (`DiffTextPane`): code keeps its syntax colors
/// (the editor's Highlightr pipeline) with the add/delete tint painted as a full-width
/// wash underneath, raw `@@` plumbing never appears — unchanged runs collapse into
/// expandable "n lines" bands — selection runs continuously across lines, and ⌘F opens the
/// same `FileFindBar` the code editor uses. Escape or the close button dismisses it.
struct GitDiffView: View {
    let request: GitDiffRequest
    @ObservedObject var settings: AppSettings
    let onClose: () -> Void
    /// Replaces the overlay's request in place — ← / → walk through `request.siblings`
    /// without dropping back to the list (Quick Look's arrow-key walk; ↑ ↓ stay with
    /// scrolling, and the same keys in the focused Changes list walk via selection).
    var onNavigate: ((GitDiffRequest) -> Void)? = nil

    /// For the right-click "Add to Chat": the gate and the prompt insertion live
    /// on the store.
    @EnvironmentObject private var store: TermioStore

    @Environment(\.colorScheme) private var colorScheme

    @State private var rows: [DiffRow] = []
    @State private var document: DiffDocument?
    @State private var isLoading = true
    /// The spinner waits 0.15 s before appearing, so a fast file-to-file walk swaps
    /// content with no intermediate flash; only a genuinely slow diff shows it.
    @State private var showsSpinner = false
    /// Syntax-colored line content per row id, filled by a background pass after the
    /// rows land; the document renders plain until then.
    @State private var styledLines: [Int: NSAttributedString] = [:]
    /// How much of each collapsed run the reader has revealed.
    @State private var expansion = DiffExpansion()
    /// The two columns of a split diff — both built from one fold, so their rows stay in step.
    @State private var splitPair: DiffDocument.SplitPair?
    /// Which column the reader is working in. A split searches this one, so a query does not
    /// count a context line twice — once per column.
    @State private var activeSide: DiffPaneScrollSync.Side = .left
    /// Keeps the two columns on one viewport (see `DiffPaneScrollSync`).
    @State private var scrollSync = DiffPaneScrollSync()

    /// Whether to render side by side. The preference is the reader's, but only a maximized
    /// detail can honor it: docked, the diff is a column of the inspector and has no width for
    /// two more.
    private var isSplitView: Bool { settings.diffSplitView && store.inspectorMaximized }

    // Find bar — the same `FileFindBar` the code editor uses, over the diff's read-only text.
    @State private var findBarVisible = false
    @State private var findQuery = ""
    @State private var findOptions = FindOptions()
    @State private var findFocusedIndex = 0
    /// Matching rows, per column. A split diff searches each column and merges the hits by row
    /// (`findMatches`), so a context line — which both columns carry — counts once.
    @State private var inlineMatches: [Int] = []
    @State private var leftMatches: [Int] = []
    @State private var rightMatches: [Int] = []
    /// The query at the last Return press; a second Return on the same query advances.
    @State private var findLastSubmittedQuery = ""
    /// Bumped on every ⌘F so the field re-focuses even when the bar is already open.
    @State private var findFocusTrigger = 0
    /// Bumped when the bar closes so the text view reclaims first responder.
    @State private var findReclaim = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(Color(nsColor: settings.terminalBackgroundColor).ignoresSafeArea())
        // The pane's text view owns the keys once mounted; these cover the loading
        // and empty states, where there is no text view to hold first responder.
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { walk(-1) ? .handled : .ignored }
        .onKeyPress(.rightArrow) { walk(+1) ? .handled : .ignored }
        .onExitCommand(perform: onClose)
        .task(id: request) { await load() }
        // Maximizing (and restoring) changes whether the pane can split, so the document has
        // to be rebuilt for the shape that applies now.
        .onChange(of: isSplitView) { rebuildDocument() }
        // Appearance flips change both the wash palette and the highlighter theme.
        .task(id: colorScheme) {
            guard !rows.isEmpty else { return }
            rebuildDocument()
            await buildStyledLines(rows)
        }
        .onReceive(NotificationCenter.default.publisher(for: .termioShowFindBar)) { _ in
            openFindBar()
        }
        // ⌘G / ⇧⌘G reach the diff's find bar too — it is the same bar, over the same engine.
        // ⌘E is not wired here: the buffer is read-only, and the verb belongs to the editor
        // whose text view holds the keyboard.
        .onReceive(NotificationCenter.default.publisher(for: .termioFindNext)) { _ in
            guard findBarVisible else { return }
            advanceFind(by: 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .termioFindPrevious)) { _ in
            guard findBarVisible else { return }
            advanceFind(by: -1)
        }
    }

    // MARK: Find

    /// ⌘F: reveal the find bar (only over a loaded diff — nothing to search otherwise).
    private func openFindBar() {
        guard hasContent else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 1)) { findBarVisible = true }
        // The text view holds first responder; drop it so the find field can take the keyboard.
        NSApp.keyWindow?.makeFirstResponder(nil)
        findFocusTrigger &+= 1
    }

    private func closeFindBar() {
        withAnimation(.spring(response: 0.3, dampingFraction: 1)) { findBarVisible = false }
        findQuery = ""
        findLastSubmittedQuery = ""
        findFocusedIndex = 0
        inlineMatches = []
        leftMatches = []
        rightMatches = []
        findOptions = FindOptions()
        findReclaim &+= 1
    }

    /// Return: fresh query → match 1; same query → next match.
    private func submitFind() {
        guard !findQuery.isEmpty else { return }
        if findQuery == findLastSubmittedQuery, !findMatches.isEmpty {
            advanceFind(by: 1)
        } else {
            findLastSubmittedQuery = findQuery
            findFocusedIndex = 0
        }
    }

    private func advanceFind(by offset: Int) {
        let count = findMatches.count
        guard count > 0 else { return }
        findFocusedIndex = ((findFocusedIndex + offset) % count + count) % count
    }

    /// The rows the query matched. Split, the left column's hits come first, then whatever the
    /// right column matched on rows of its own — a deletion is only ever on the left, an addition
    /// only on the right, and a context line is one row matched twice.
    private var findMatches: [Int] {
        isSplitView ? DiffFindMerge.rows(left: leftMatches, right: rightMatches) : inlineMatches
    }

    /// The row to highlight now, or nil when the query matched nothing.
    private var findFocusedRow: Int? {
        findMatches.indices.contains(findFocusedIndex) ? findMatches[findFocusedIndex] : nil
    }

    /// One column's report of what it matched.
    private func noteMatches(_ rows: [Int], side: DiffPaneScrollSync.Side?) {
        switch side {
        case .some(.left): leftMatches = rows
        case .some(.right): rightMatches = rows
        case .none: inlineMatches = rows
        }
        if findFocusedIndex >= findMatches.count { findFocusedIndex = 0 }
    }

    // MARK: Walking

    private var walkIndex: Int? {
        request.siblings.firstIndex { $0.path == request.change.path }
    }

    /// Steps to the previous/next diffable sibling. Returns false at either end so
    /// the key press falls through instead of pretending to act.
    private func walk(_ delta: Int) -> Bool {
        guard let onNavigate, let next = request.neighbor(delta) else { return false }
        onNavigate(next)
        return true
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(request.change.status.letter)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(request.change.status.tint)
                .frame(width: 16)
            // Name and directory as one text run with a single truncation point: as two
            // flexible texts a narrow pane split the width between them and truncated
            // both into noise. Tail truncation keeps the name (the head) readable longest.
            let directory = (request.change.path as NSString).deletingLastPathComponent
            let name = Text(request.name).font(.system(size: 12.5, weight: .medium))
            (directory.isEmpty
                ? name
                : name + Text("  \(directory)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            // "n of m" (Mail's message-walk wording) whenever there is a set to walk.
            if request.siblings.count > 1, let index = walkIndex {
                Text(localized("\(index + 1) of \(request.siblings.count)"))
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .padding(.trailing, 2)
            }
            // For a history diff, tag the header with the commit it belongs to.
            // `fixedSize` (as on the ± counts) keeps the tag on one line in a narrow
            // pane — the flexible path is the only element that gives up width.
            if let commit = request.commit {
                Text("@ \(commit.prefix(7))")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .padding(.trailing, 2)
            }
            HStack(spacing: 5) {
                if request.change.additions > 0 {
                    Text("+\(request.change.additions)").foregroundStyle(.green)
                }
                if request.change.deletions > 0 {
                    Text("−\(request.change.deletions)").foregroundStyle(.red)
                }
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .fixedSize()
            // Inline or side by side. Only a diff with the whole window to spend gets the
            // choice: docked, the pane is a column of the inspector and has no room for two.
            if store.inspectorMaximized {
                DetailChromeButton(
                    icon: isSplitView ? .layoutRows : .layoutColumns, size: 14,
                    help: isSplitView ? localized("Show one column (inline diff)")
                                      : localized("Show two columns (side-by-side diff)")
                ) { settings.diffSplitView.toggle() }
            }
            // The content-area window controls (hide list / maximize / close) ride the header's
            // trailing edge, after the diff's own stats.
            InspectorDetailChromeButtons()
        }
        .padding(.horizontal, 12)
        // Fixed height + inset hairline shared with the git pane's mode switch, so this
        // bar and the inspector's `Changes | History` bar line up across the split.
        .frame(height: GitChangesView.topBarHeight)
        .modifier(DetailHeaderTitlebarInset())
        .background(Color(nsColor: settings.terminalBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
    }

    // MARK: Content

    /// Whether there is a diff to show at all — what gates the find bar and the panes.
    private var hasContent: Bool { !rows.isEmpty }

    @ViewBuilder
    private var content: some View {
        Group {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(showsSpinner ? 1 : 0)
                    .task {
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        showsSpinner = true
                    }
            } else if isSplitView, let splitPair {
                split(splitPair)
            } else if let document {
                pane(document, side: nil, metrics: nil, autoFocuses: true)
            } else {
                PaneEmptyState(
                    localized("No Diff"),
                    icon: .fileDoc,
                    message: localized("No textual changes to show.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if findBarVisible, hasContent { findBar }
        }
    }

    /// The two columns of a split diff, one pane each, divided by the same hairline the header
    /// uses. Neither pane wraps, so a long line runs off its own column instead of folding into
    /// fragments the column beside it cannot match — and because the pair shares one
    /// `scrollSync`, panning sideways moves both columns' code at once.
    private func split(_ pair: DiffDocument.SplitPair) -> some View {
        HStack(spacing: 0) {
            pane(pair.left, side: .left,
                 metrics: .side(true, digits: pair.lineNumberDigits), autoFocuses: true)
            Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
            pane(pair.right, side: .right,
                 metrics: .side(false, digits: pair.lineNumberDigits), autoFocuses: false)
        }
    }

    /// One diff pane. Inline hands it the whole document; a split hands it one column and the
    /// gutter geometry that keeps both columns' code starting at the same x.
    private func pane(_ document: DiffDocument, side: DiffPaneScrollSync.Side?,
                      metrics: DiffGutterMetrics?, autoFocuses: Bool) -> some View {
        // Both columns run the query, so a match an addition or deletion carries is found
        // wherever it lives — a reader on the old side still finds text they can see on the new
        // one. Each reports the rows it hit and they are merged by row, so a context line counts
        // once (`findMatches`).
        let sideMatches: ([Int]) -> Void = { rows in noteMatches(rows, side: side) }
        return DiffTextPane(
            document: document,
            styled: styledLines,
            font: settings.resolvedTerminalFont(),
            thickenGlyphs: settings.fontThicken,
            backgroundColor: settings.terminalBackgroundColor,
            numberColor: settings.gutterInk(for: colorScheme),
            onExpand: { anchor, direction in
                expansion.reveal(anchor, direction)
                rebuildDocument()
            },
            onWalk: { walk($0) },
            onClose: onClose,
            wraps: side == nil,
            scrollSync: side == nil ? nil : scrollSync,
            paneSide: side,
            gutterMetrics: metrics,
            onActivate: { if let side { activeSide = side } },
            autoFocuses: autoFocuses,
            findQuery: findBarVisible ? findQuery : "",
            findOptions: findOptions,
            findFocusedRow: findFocusedRow,
            onMatchesChanged: sideMatches,
            reclaimFocus: findReclaim,
            // Closing the find bar hands the keyboard back to the column the reader was in, not
            // to whichever one happens to answer last.
            reclaimsFocus: side == nil || side == activeSide,
            // Cursor's split, like the editor: a selection goes over as the pasted
            // snippet; no selection means the diffed file, which lands as its path.
            addToChat: { selection in
                if let selection {
                    _ = store.addSnippetToSelectedSessionPrompt(selection)
                } else {
                    let url = URL(fileURLWithPath: request.repoRoot)
                        .appendingPathComponent(request.change.path)
                    _ = store.addPathToSelectedSessionPrompt(url)
                }
            },
            canAddToChat: { store.selectedSessionRunsAgent }
        )
    }

    private var findBar: some View {        FileFindBar(
            query: $findQuery,
            options: $findOptions,
            currentMatch: findMatches.isEmpty ? 0 : findFocusedIndex + 1,
            totalMatches: findMatches.count,
            onSubmit: submitFind,
            onNext: { advanceFind(by: 1) },
            onPrevious: { advanceFind(by: -1) },
            onClose: closeFindBar,
            focusTrigger: findFocusTrigger
        )
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    // MARK: Loading + syntax colors

    private func load() async {
        let parsed = await DiffSource.rows(
            for: request.change, in: request.repoRoot, device: request.device,
            commit: request.commit, range: request.range)
        rows = parsed
        rebuildDocument()
        isLoading = false
        await buildStyledLines(parsed)
    }

    /// Lays the rows out again with the palette that applies *now*, in the shape that applies
    /// now. The tints are opaque, pre-mixed against the terminal background and baked into the
    /// document's emphasis spans, so unlike the dynamic system colors they replaced they do not
    /// re-resolve on their own when the appearance flips — the document has to be rebuilt.
    private func rebuildDocument() {
        guard !rows.isEmpty else {
            document = nil
            splitPair = nil
            return
        }
        let font = settings.resolvedTerminalFont()
        let palette = settings.diffPalette(for: colorScheme)
        let spacing = settings.codeLineSpacing(for: font)
        if isSplitView {
            document = nil
            splitPair = DiffDocument.buildSplitPair(rows: rows, expansion: expansion,
                                                    palette: palette, codeFont: font,
                                                    lineSpacing: spacing)
        } else {
            splitPair = nil
            document = DiffDocument.build(rows: rows, expansion: expansion, palette: palette,
                                          codeFont: font, lineSpacing: spacing)
        }
    }

    /// Colors the code through `DiffHighlighter` (the editor's Highlightr pipeline
    /// behind a shared actor). Oversized diffs skip coloring rather than stall; a
    /// result that lands after the user has walked on is dropped, not applied.
    private func buildStyledLines(_ rows: [DiffRow]) async {
        let url = URL(fileURLWithPath: request.repoRoot).appendingPathComponent(request.change.path)
        guard let language = FileEditorView.highlightLanguage(for: url) else { return }
        let code = rows.filter { $0.kind != .hunk }
        guard code.count <= 8000, code.reduce(0, { $0 + $1.text.count }) <= 600_000 else { return }

        let styled = await DiffHighlighter.shared.styledLines(
            newSide: code.filter { $0.kind == .context || $0.kind == .addition },
            oldSide: code.filter { $0.kind == .context || $0.kind == .deletion },
            language: language,
            theme: colorScheme == .dark ? "xcode-dark" : "xcode",
            font: settings.resolvedTerminalFont()
        )
        guard !Task.isCancelled else { return }
        styledLines = styled.byRow
    }
}

extension GitDiffRequest {    /// The nearest sibling in `delta`'s direction that has a textual diff —
    /// image/PDF siblings belong to the preview overlay and are skipped. The one
    /// walking rule, shared by the overlay's own ← / → and the Changes list's.
    func neighbor(_ delta: Int) -> GitDiffRequest? {
        guard let index = siblings.firstIndex(where: { $0.path == change.path }) else { return nil }
        var next = index + delta
        while next >= 0, next < siblings.count {
            let candidate = siblings[next]
            let url = URL(fileURLWithPath: repoRoot).appendingPathComponent(candidate.path)
            if !FileActivation.previewsRatherThanDiff(url) {
                return GitDiffRequest(repoRoot: repoRoot, device: device, change: candidate,
                                      commit: commit, range: range, siblings: siblings)
            }
            next += delta
        }
        return nil
    }
}

/// Merging the two columns' find hits into one list of rows. A split diff searches each column on
/// its own, but a context line lives in both and is still one line of the file — so the right
/// column contributes only the rows the left one did not already report. Rows only ever collide
/// when they are the same row: a deletion exists in the left column alone, an addition in the
/// right.
enum DiffFindMerge {
    static func rows(left: [Int], right: [Int]) -> [Int] {
        left + right.filter { !left.contains($0) }
    }
}
