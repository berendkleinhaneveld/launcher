import AppKit

/// Follows a log file, like `tail -f`.
@MainActor
final class LogWindowController: NSWindowController, NSWindowDelegate {
    private let url: URL
    private let textView: NSTextView
    private let scrollView: NSScrollView
    private var timer: Timer?
    private var offset: UInt64 = 0
    /// Bytes after the last newline, held back so a read never splits a character.
    private var pending = Data()

    /// How far back to start reading a long log, and how much to keep on screen.
    private static let backlog: UInt64 = 256 * 1024
    private static let maximumText = 2 * 1024 * 1024

    private static let escapeSequence = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]")

    init(name: String, url: URL) {
        self.url = url
        scrollView = NSTextView.scrollableTextView()
        textView = scrollView.documentView as! NSTextView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: true
        )
        window.title = "\(name) Logs"
        window.minSize = NSSize(width: 420, height: 220)
        window.center()
        super.init(window: window)
        shouldCascadeWindows = true
        window.delegate = self

        textView.isEditable = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 6, height: 6)

        let path = NSTextField(labelWithString: url.path)
        path.isSelectable = true
        path.lineBreakMode = .byTruncatingMiddle
        path.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        path.textColor = .secondaryLabelColor
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        path.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let reveal = NSButton(title: "Show in Finder", target: self, action: #selector(revealInFinder))
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearLog))
        for button in [reveal, clear] {
            button.controlSize = .small
            button.bezelStyle = .rounded
        }

        let bar = NSStackView(views: [path, reveal, clear])
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)

        let stack = NSStackView(views: [scrollView, bar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        window.contentView = stack
        NSLayoutConstraint.activate([
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        poll()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }

    /// Polling copes with a log that doesn't exist yet, is cleared or gets rotated,
    /// all of which a file descriptor watch would have to handle separately.
    private func poll() {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0

        if size < offset {
            reset()
        }
        var isFirstRead = false
        if offset == 0, size > Self.backlog {
            offset = size - Self.backlog
            isFirstRead = true
        }
        guard size > offset, let file = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? file.close() }

        guard (try? file.seek(toOffset: offset)) != nil,
            let data = try? file.readToEnd()
        else { return }
        offset += UInt64(data.count)

        var bytes = pending + data
        if isFirstRead, let newline = bytes.firstIndex(of: 10) {
            bytes = bytes[(newline + 1)...]
        }
        if let newline = bytes.lastIndex(of: 10) {
            pending = Data(bytes[(newline + 1)...])
            append(String(decoding: bytes[...newline], as: UTF8.self))
        } else {
            pending = Data(bytes)
        }
    }

    private func reset() {
        offset = 0
        pending = Data()
        textView.string = ""
    }

    private func append(_ text: String) {
        guard let storage = textView.textStorage else { return }

        let isFollowing = scrollView.documentVisibleRect.maxY >= textView.bounds.maxY - 24
        let plain = Self.escapeSequence.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        )
        storage.append(
            NSAttributedString(
                string: plain,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: NSColor.labelColor,
                ]))
        if storage.length > Self.maximumText {
            storage.deleteCharacters(in: NSRange(location: 0, length: storage.length - Self.maximumText))
        }
        if isFollowing {
            textView.scrollToEndOfDocument(nil)
        }
    }

    @objc private func clearLog() {
        // Safe while the service runs: launchd opens the log in append mode.
        if let file = try? FileHandle(forWritingTo: url) {
            try? file.truncate(atOffset: 0)
            try? file.close()
        }
        reset()
    }

    @objc private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
