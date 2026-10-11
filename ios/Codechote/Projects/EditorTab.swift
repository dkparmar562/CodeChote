import SwiftUI
import UIKit

/// A native text editor for one file on the host.
struct EditorTab: View {
    @Environment(AppModel.self) private var model
    let tab: AppTab
    let tabs: TabsModel
    let path: String

    enum LoadState { case loading, text, image(UIImage), binary(Int), failed(String) }

    @State private var state: LoadState = .loading
    @State private var text = ""
    @State private var original = ""
    @State private var truncated = false
    @State private var saving = false
    @State private var errorText: String?
    @State private var find = FindCommand()

    private var name: String { (path as NSString).lastPathComponent }
    private var dirty: Bool { text != original }

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case .loading:
                    ProgressView()
                case .text:
                    CodeTextView(text: $text, fileName: name, editable: !truncated, find: find)
                        .ignoresSafeArea(.container, edges: .bottom)
                case .image(let image):
                    ZoomableImage(image: image)
                case .binary(let size):
                    ContentUnavailableView("Binary file", systemImage: "doc.fill", description: Text("\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)). This can't be shown as text."))
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Couldn't open file", systemImage: "exclamationmark.triangle")
                    } description: { Text(message) } actions: { Button("Try Again") { Task { await load() } } }
                }
            }
            .navigationTitle("\(dirty ? "● " : "")\(name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if case .text = state {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { find.show() } label: { Image(systemName: "magnifyingglass") }.accessibilityLabel("Find")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { Task { await save() } } label: {
                            if saving { ProgressView() } else { Text("Save").fontWeight(.semibold) }
                        }
                        .disabled(!dirty || saving || truncated)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Open in VS Code", systemImage: "chevron.left.forwardslash.chevron.right") { model.openInWorkbench(path, isFolder: false, tabs: tabs) }
                            Button("Copy Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = path }
                            Button("Revert Changes", systemImage: "arrow.uturn.backward") { text = original }.disabled(!dirty)
                            Button("Reload from Host", systemImage: "arrow.clockwise") { Task { await load() } }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if truncated { banner("Large file: showing the first 2 MB, read-only.") }
                else if let errorText { banner(errorText, error: true) }
            }
        }
        .task(id: path) { await load() }
        // A search result for a file that is already open.
        .onChange(of: tabs.pendingLines[path]) { _, line in if line != nil { showPendingLine() } }
    }

    private func showPendingLine() {
        guard case .text = state, let line = tabs.pendingLines.removeValue(forKey: path) else { return }
        // Once the text view has laid the text out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { find.goToLine?(line) }
    }

    private func banner(_ message: String, error: Bool = false) -> some View {
        Text(message).font(.footnote).padding(8).frame(maxWidth: .infinity)
            .background(error ? Color.red.opacity(0.15) : Color.yellow.opacity(0.2))
    }

    private func load() async {
        state = .loading
        errorText = nil
        guard let session = model.session else { state = .failed("Not connected."); return }
        do {
            let (data, wasTruncated) = try await session.readFile(path)
            if FileKind.isImage(name), let image = UIImage(data: data) { state = .image(image); return }
            if data.prefix(8000).contains(0) { state = .binary(data.count); return }
            let string = String(decoding: data, as: UTF8.self)
            text = string
            original = string
            truncated = wasTruncated
            state = .text
            tabs.update(tab.id, title: name, detail: path)
            showPendingLine()
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    private func save() async {
        guard let session = model.session else { return }
        saving = true
        errorText = nil
        do {
            try await session.writeFile(path, data: Data(text.utf8))
            original = text
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            errorText = "Couldn't save: " + ((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        saving = false
    }
}

/// Lets SwiftUI ask the text view to show its find bar.
final class FindCommand {
    var handler: (() -> Void)?
    /// Scrolls to a line (1-based) and marks it for a moment.
    var goToLine: ((Int) -> Void)?
    func show() { handler?() }
}

struct CodeTextView: UIViewRepresentable {
    @Binding var text: String
    let fileName: String
    let editable: Bool
    let find: FindCommand

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = Coordinator.font
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartDashesType = .no
        view.smartQuotesType = .no
        view.smartInsertDeleteType = .no
        view.spellCheckingType = .no
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.isFindInteractionEnabled = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 80, right: 8)
        view.inputAccessoryView = context.coordinator.makeAccessory(for: view)
        find.handler = { [weak view] in view?.findInteraction?.presentFindNavigator(showingReplace: false) }
        find.goToLine = { [weak view] line in
            guard let view else { return }
            let range = Self.range(ofLine: line, in: view.text as NSString)
            // A third of the way down the screen, clear of the bars at the top and bottom.
            if let start = view.position(from: view.beginningOfDocument, offset: range.location),
               let end = view.position(from: start, offset: range.length),
               let textRange = view.textRange(from: start, to: end) {
                let rect = view.firstRect(for: textRange)
                let maxOffset = max(0, view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom)
                let target = min(max(rect.minY - view.bounds.height / 3, -view.adjustedContentInset.top), maxOffset)
                view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
            }
            view.selectedRange = NSRange(location: range.location, length: 0)
            view.textStorage.addAttribute(.backgroundColor, value: UIColor.systemYellow.withAlphaComponent(0.35), range: range)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak view] in
                guard let view, NSMaxRange(range) <= view.textStorage.length else { return }
                view.textStorage.removeAttribute(.backgroundColor, range: range)
            }
        }
        view.text = text
        context.coordinator.highlight(view)
        return view
    }

    /// The range of a line (1-based); the last line if there are fewer.
    nonisolated static func range(ofLine line: Int, in text: NSString) -> NSRange {
        var start = 0, current = 1
        while current < line, start < text.length {
            let next = text.range(of: "\n", range: NSRange(location: start, length: text.length - start))
            guard next.location != NSNotFound else { break }
            start = next.location + 1
            current += 1
        }
        let end = text.range(of: "\n", range: NSRange(location: start, length: text.length - start))
        return NSRange(location: start, length: (end.location == NSNotFound ? text.length : end.location) - start)
    }

    func updateUIView(_ view: UITextView, context: Context) {
        view.isEditable = editable
        context.coordinator.parent = self
        if view.text != text {
            let selection = view.selectedRange
            view.text = text
            view.selectedRange = NSRange(location: min(selection.location, (text as NSString).length), length: 0)
            context.coordinator.highlight(view)
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        static let font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        var parent: CodeTextView
        private var pending: DispatchWorkItem?

        init(_ parent: CodeTextView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            pending?.cancel()
            let work = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.highlight(textView)
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }

        func highlight(_ view: UITextView) {
            let selection = view.selectedRange
            SyntaxHighlighter.apply(to: view.textStorage, language: SyntaxHighlighter.language(for: parent.fileName), fileName: parent.fileName, font: Self.font)
            view.selectedRange = selection
        }

        /// Keys a phone keyboard lacks.
        func makeAccessory(for view: UITextView) -> UIView {
            let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
            bar.barStyle = .default
            func insert(_ text: String, label: String) -> UIBarButtonItem {
                UIBarButtonItem(title: label, image: nil, primaryAction: UIAction { [weak view] _ in view?.insertText(text) })
            }
            let undo = UIBarButtonItem(image: UIImage(systemName: "arrow.uturn.backward"), primaryAction: UIAction { [weak view] _ in view?.undoManager?.undo() })
            let redo = UIBarButtonItem(image: UIImage(systemName: "arrow.uturn.forward"), primaryAction: UIAction { [weak view] _ in view?.undoManager?.redo() })
            let done = UIBarButtonItem(image: UIImage(systemName: "keyboard.chevron.compact.down"), primaryAction: UIAction { [weak view] _ in view?.resignFirstResponder() })
            let space = UIBarButtonItem.flexibleSpace()
            bar.items = [undo, redo, space, insert("\t", label: "⇥"), insert("{}", label: "{ }"), insert("()", label: "( )"), insert("[]", label: "[ ]"), insert("\"\"", label: "\" \""), insert(";", label: ";"), insert("/", label: "/"), space, done]
            bar.sizeToFit()
            return bar
        }
    }
}
