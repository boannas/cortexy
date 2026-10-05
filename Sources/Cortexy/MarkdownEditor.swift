import AppKit
import SwiftUI

// The editor in SwiftUI (the text view, its scroll view and delegate), and the small views it floats over the
// text: the formatting bar over a selection and the suggestion list under the caret.

struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var style: TextStyle
    let store: Store
    var onLink: (URL) -> Bool = { _ in false } // cortexy:// links (tags, [[notes]]); others open normally
    var complete: (MarkdownTextView.Completion, String) -> [String] = { _, _ in [] }
    var caretKey: UUID? // the note: its caret is remembered for next time
    var onFit: ((_ content: CGFloat, _ room: CGFloat) -> Void)? // how tall the text wants to be, and the room it has, after each change
    var measureTick = 0             // changes when it should say so again (the panel came to rest)

    /// Where the caret was in each note this session.
    static var carets: [UUID: Int] = [:]

    func makeNSView(context: Context) -> NSScrollView {
        let tv = MarkdownTextView(usingTextLayoutManager: false) // TextKit 1: stable glyph geometry for drawn checkboxes
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.importsGraphics = false
        tv.isAutomaticQuoteSubstitutionEnabled = false // keep Markdown characters literal
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.textContainerInset = NSSize(width: 10, height: 8)
        tv.linkTextAttributes = [.cursor: NSCursor.pointingHand] // colors come from the styling: links blue, tags accent
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        configure(tv)
        tv.noteID = caretKey // the note's own say on fetching its web images
        let remembered = caretKey.flatMap { Self.carets[$0] } // read first: loading moves the caret (and reports it)
        tv.load(text)
        // Back where you were in this note, else at its end.
        let end = (tv.string as NSString).length
        tv.setSelectedRange(NSRange(location: min(remembered ?? end, end), length: 0))
        MarkdownTextView.active = tv

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = tv
        tv.usesFindBar = true // ⌘F finds in this note
        tv.isIncrementalSearchingEnabled = true
        DispatchQueue.main.async {
            tv.window?.makeFirstResponder(tv)
            tv.scrollRangeToVisible(tv.selectedRange()) // so you see where typing goes
            context.coordinator.fit(tv)
        }
        tv.didResize = { [weak tv, weak coordinator = context.coordinator] in if let tv { coordinator?.fit(tv) } }
        return scroll
    }

    private func configure(_ tv: MarkdownTextView) {
        tv.style = style
        tv.isContinuousSpellCheckingEnabled = !style.code
        tv.isEditable = !style.readOnly
        tv.resolve = { [store] in store.resolve($0) }
        tv.importFile = { [store] in store.markdown(forFile: $0) }
        tv.importImage = { [store] in store.markdown(forImage: $0) }
        tv.completionSource = complete
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? MarkdownTextView else { return }
        if context.coordinator.measured != measureTick {
            context.coordinator.measured = measureTick
            DispatchQueue.main.async { context.coordinator.fit(tv) }
        }
        if tv.style != style {
            configure(tv)
            tv.load(tv.markdown()) // fonts change the size of everything, attachments included
        }
        // Usually `text` is what the editor just sent; only rebuild the Markdown to compare when it isn't.
        if text != context.coordinator.pushed, tv.markdown() != text {
            let caret = tv.selectedRange()
            tv.load(text)
            tv.setSelectedRange(NSRange(location: min(caret.location, (tv.string as NSString).length), length: 0))
        }
        context.coordinator.pushed = text
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        var pushed: String? // the text last sent to the store
        /// This editor's own undo history: not the window's, which every note opened in it would share (⌘Z in
        /// one note undoing another), and which kept closed notes' text alive. It goes when the editor does.
        let undo = UndoManager()
        var measured = 0 // the measureTick last answered
        var reported = false // told the panel its height yet
        init(_ parent: MarkdownEditor) { self.parent = parent }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        /// Tells the panel how tall the text wants to be and the room it has. Past a screenful the answer is
        /// "more than fits" either way, so long notes aren't laid out in full.
        func fit(_ tv: MarkdownTextView) {
            guard let onFit = parent.onFit, let lm = tv.layoutManager, let tc = tv.textContainer, let scroll = tv.enclosingScrollView else { return }
            let room = scroll.contentSize.height
            if (tv.string as NSString).length >= 20_000 { return onFit(100_000, room) }
            lm.ensureLayout(for: tc)
            // Room to type in, grown a few lines at a time before the caret gets to the bottom: Return never has
            // to scroll the text while the card springs, and the card doesn't spring for every line.
            let line = tv.style.size * 1.6, text = lm.usedRect(for: tc).height + tv.textContainerInset.height * 2 + 12
            if text + line > room || text + 5 * line < room || !reported {
                reported = true
                onFit(text + 3 * line, room)
            }
        }

        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? MarkdownTextView else { return }
            tv.convertTypedAttachments()
            let md = tv.markdown()
            pushed = md
            parent.text = md
            tv.restyle()
            tv.suggestCompletions()
            fit(tv)
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return false }
            return parent.onLink(url)
        }

        func textViewDidChangeSelection(_ n: Notification) {
            guard let tv = n.object as? MarkdownTextView else { return }
            tv.restyle()
            tv.caretMovedForSuggestions()
            // Only while it's on screen: an editor being taken away (the note left) moves its caret too, and that
            // overwrote where you'd been, so the note reopened somewhere else.
            if let key = parent.caretKey, tv.window != nil { MarkdownEditor.carets[key] = tv.selectedRange().location }
        }

        func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            guard let tv = textView as? MarkdownTextView else { return false }
            if tv.handleSuggestionKey(sel) { return true }
            return sel == #selector(NSResponder.insertNewline(_:)) && tv.continueList()
        }

        /// Typing right after an attachment must not inherit its attachment attributes.
        func textView(_ textView: NSTextView, shouldChangeTypingAttributes old: [String: Any], toAttributes new: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
            new.filter { ![.attachment, .cxSource, .cxOpen, .link].contains($0.key) }
        }
    }
}

/// Formatting for the selected words, floating just above them.
struct SelectionBar: View {
    var body: some View {
        HStack(spacing: 2) {
            ForEach([("bold", "cxBold:", "Bold (⌘B)"), ("italic", "cxItalic:", "Italic (⌘I)"), ("strikethrough", "cxStrike:", "Strikethrough (⇧⌘X)"),
                     ("chevron.left.forwardslash.chevron.right", "cxCode:", "Code (⌘E)"), ("highlighter", "cxHighlight:", "Highlight (⇧⌘H)"),
                     ("link", "cxLink:", "Link (⌘K)")], id: \.1) { symbol, action, help in
                Button { NSApp.sendAction(Selector(action), to: nil, from: nil) } label: {
                    Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 26, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(help)
                .accessibilityLabel(help)
            }
        }
        .padding(.horizontal, 4)
        .glassEffect(.regular, in: .capsule)
        .padding(2)
    }
}

/// The suggestions under the caret: note titles after `[[`, tags after `#`, commands after `/`. It scrolls when
/// they don't fit, keeping the row picked with the arrows in view.
struct SuggestionList: View {
    let items: [String]
    let highlighted: Int?
    let kind: MarkdownTextView.Completion
    let maxHeight: CGFloat
    let pick: (String) -> Void

    static let width: CGFloat = 260, row: CGFloat = 25
    private var hint: Bool { highlighted == nil }
    /// Its height: every row if they fit, else what the room allows.
    var height: CGFloat { min(CGFloat(items.count) * Self.row + (hint ? 18 : 0) + 8, maxHeight) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                        Button { pick(item) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: kind == .link ? "doc.text" : kind == .tag ? "number" : "command").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
                                Text(kind == .tag ? "#" + item : item).font(.system(size: 13)).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: Self.row - 1)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(i == highlighted ? Color.cortexyAccent.opacity(0.25) : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(i)
                    }
                }
                .scrollTargetLayout()
            }
            // The row picked with the arrows stays in view (set as the list is drawn, not by a later scroll).
            .scrollPosition(id: Binding(get: { highlighted }, set: { _ in }), anchor: .center)
            if hint {
                Text("↓ to choose · ⇥ takes the first · \(items.count) found").font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 8).frame(height: 18)
            }
        }
        .padding(4)
        .frame(width: Self.width, height: height, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.1)))
    }
}
