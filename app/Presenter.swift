// Presenter — a small macOS app that lists the decks in ~/Documents/presentations
//
// Author: Oscar Neira
// MIT licensed. See LICENSE.
// and opens them in an embedded browser, with no URL bar and no browser chrome.
//
// Drop a folder containing deck.html into ~/Documents/presentations and it appears
// in the list. Nothing to register, nothing to configure.

import SwiftUI
import WebKit
import AppKit
import PDFKit
import UniformTypeIdentifiers

// MARK: - Model

struct Deck: Identifiable, Hashable {
    let id: String
    let title: String
    let folder: String
    let url: URL
    let modified: Date
    let slideCount: Int?
    let generator: String?
    /// The deck's own markdown, lifted back out of the built file. Kept so the
    /// library can search what a deck *says*, not just what it is called —
    /// which is the question actually being asked ("where did I write that?").
    let body: String

    var dir: URL { url.deletingLastPathComponent() }

    var modifiedText: String {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy"
        return f.string(from: modified)
    }

    /// Same three groups as the mission-control dashboard's Decks tab (kept in
    /// sync by convention, not a shared file): the daily/retro record Oscar
    /// reads to himself each morning, vs. the decks built to stand in front of
    /// other people. Inferred from the folder name, so nothing has to be
    /// registered when a new deck lands.
    var category: DeckCategory {
        // Legacy: the single static "daily-standup" folder that used to be
        // overwritten every day (fixed 3 Sep 2026 — each day now gets its own
        // dated folder, "<date>-daily-standup", so history is never lost).
        if folder == "daily-standup" { return .daily }
        if folder.range(of: #"^\d{4}-\d{2}-\d{2}-daily-standup$"#,
                         options: .regularExpression) != nil {
            return .daily
        }
        if folder.range(of: #"-retro-\d{4}-\d{2}-\d{2}-to-\d{4}-\d{2}-\d{2}$"#,
                         options: .regularExpression) != nil {
            return .sprint
        }
        return .presentation
    }

    /// Where a search matched, with enough either side to recognise it. Titles
    /// and folder names match too, but a body hit is the one that needs proof.
    func snippet(for query: String) -> String? {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2, !body.isEmpty,
              let r = body.range(of: q, options: [.caseInsensitive, .diacriticInsensitive])
        else { return nil }
        let lo = body.index(r.lowerBound, offsetBy: -60, limitedBy: body.startIndex) ?? body.startIndex
        let hi = body.index(r.upperBound, offsetBy: 60, limitedBy: body.endIndex) ?? body.endIndex
        var s = String(body[lo..<hi])
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if lo > body.startIndex { s = "…" + s }
        if hi < body.endIndex { s += "…" }
        return s
    }

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return title.range(of: q, options: opts) != nil
            || folder.range(of: q, options: opts) != nil
            || body.range(of: q, options: opts) != nil
    }
}

enum DeckCategory: String, CaseIterable, Identifiable {
    case daily = "Daily standups"
    case sprint = "Sprints & retros"
    case presentation = "Meetings & presentations"
    var id: String { rawValue }
}

enum Library {
    /// ~/Documents/presentations
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/presentations", isDirectory: true)
    }

    static func scan() -> [Deck] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }

        var decks: [Deck] = []
        for dir in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }

            // a deck is any folder holding deck.html
            let html = dir.appendingPathComponent("deck.html")
            guard fm.fileExists(atPath: html.path) else { continue }

            let head = (try? String(contentsOf: html, encoding: .utf8))?.prefix(400_000) ?? ""
            let title = firstMatch(in: String(head), pattern: "<title>(.*?)</title>")?
                .replacingOccurrences(of: "&amp;", with: "&") ?? dir.lastPathComponent
            let generator = firstMatch(in: String(head),
                                        pattern: #"<meta name="generator" content="(.*?)">"#)?
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&middot;", with: "·")
            let slides = countSlides(in: String(head))
            let mod = (try? html.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast

            decks.append(Deck(id: dir.path, title: title, folder: dir.lastPathComponent,
                              url: html, modified: mod, slideCount: slides, generator: generator,
                              body: markdownBody(in: String(head))))
        }
        return decks.sorted { $0.modified > $1.modified }
    }

    private static func firstMatch(in s: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// reveal decks written as markdown use "\n---\n" between slides
    private static func countSlides(in s: String) -> Int? {
        let n = s.components(separatedBy: "\n---\n").count - 1
        return n > 0 ? n + 1 : nil
    }

    /// build.sh drops slides.md verbatim inside <textarea data-template>, so the
    /// source of every deck is still in the built file. Read it back for search.
    /// The words on the slides, as prose. The markdown is lifted back out of the
    /// deck's own <textarea>, then stripped of the things that are markup rather
    /// than speech — HTML tags, heading hashes, table pipes, list bullets — so a
    /// search result reads like the slide instead of like its source.
    private static func markdownBody(in s: String) -> String {
        guard let a = s.range(of: "<textarea data-template>"),
              let b = s.range(of: "</textarea>", range: a.upperBound..<s.endIndex)
        else { return "" }
        var t = String(s[a.upperBound..<b.lowerBound])
        for (pattern, with) in [
            (#"<!--.*?-->"#, " "),                    // reveal's slide attributes
            (#"```[\s\S]*?```"#, " "),               // fenced code and mermaid
            (#"<[^>]+>"#, " "),                       // inline html
            (#"(?m)^\s*[-*+]\s+"#, ""),                  // list bullets
            (#"(?m)^#{1,6}\s+"#, ""),                     // heading hashes
            (#"(?m)^\s*\|[-: |]+\|\s*$"#, " "),          // table rules
            (#"[|>]"#, " "),                          // table cells, block quotes
            (#"\*\*|__|`"#, ""),                      // emphasis
            (#"&amp;"#, "&"), (#"&lt;"#, "<"), (#"&gt;"#, ">")
        ] {
            t = t.replacingOccurrences(of: pattern, with: with,
                                       options: [.regularExpression, .caseInsensitive])
        }
        return t.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
    }
}

// MARK: - Export to PDF

/// PowerPoint's "Export as PDF", without the dependency tax. reveal.js already
/// ships a print layout — it turns on when the config says `view: 'print'` — so
/// this loads the deck's own HTML with that one setting flipped, waits for the
/// pagination it does, and prints the result straight to a file. Nothing is
/// written back to the deck: the edit happens to a copy of the string in memory.
final class PDFExporter: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private static var live = Set<PDFExporter>()

    private let deck: Deck
    private let out: URL
    private let done: (String?) -> Void

    private var window: NSWindow?
    private var web: WKWebView?
    private var pageSize = NSSize(width: 1356, height: 805)
    private var settled = false

    /// PRESENTER_DEBUG=1 traces the export, because when this fails it fails
    /// silently inside WebKit and there is nothing else to look at.
    private func log(_ m: String) {
        guard ProcessInfo.processInfo.environment["PRESENTER_DEBUG"] != nil else { return }
        FileHandle.standardError.write(Data(("pdf: " + m + "\n").utf8))
    }

    init(deck: Deck, to out: URL, done: @escaping (String?) -> Void) {
        self.deck = deck; self.out = out; self.done = done
    }

    func start() {
        guard var html = try? String(contentsOf: deck.url, encoding: .utf8) else {
            return finish("Could not read \(deck.url.lastPathComponent).")
        }
        guard let call = html.range(of: "Reveal.initialize({") else {
            return finish("This deck was not built by Presenter's build.sh, so its print layout is unknown.")
        }
        html.replaceSubrange(call, with: "Reveal.initialize({ view: 'print', pdfPageHeightOffset: 0,")

        // The page is the slide plus reveal's margin, exactly as its print
        // controller computes it — read the numbers from the deck's own reveal
        // config so a deck with a different geometry still exports square.
        // (Scoped to the config: the inlined CSS is full of `width:` too.)
        let cfg0 = String(html[call.upperBound...].prefix(2000))
        let w = number(in: cfg0, key: "width") ?? 1280
        let h = number(in: cfg0, key: "height") ?? 760
        let m = number(in: cfg0, key: "margin") ?? 0.06
        pageSize = NSSize(width: (w * (1 + m)).rounded(.down), height: (h * (1 + m)).rounded(.down))

        let cfg = WKWebViewConfiguration()
        cfg.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        cfg.userContentController.add(self, name: "printReady")
        cfg.userContentController.addUserScript(WKUserScript(
            source: "document.addEventListener('pdf-ready',function(){"
                  + "window.webkit.messageHandlers.printReady.postMessage(1)});",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))

        let frame = NSRect(origin: .zero, size: pageSize)
        let web = WKWebView(frame: frame, configuration: cfg)
        web.navigationDelegate = self
        self.web = web

        // WebKit throttles requestAnimationFrame to nothing in a window it
        // thinks nobody can see, and reveal's print layout is a chain of rAFs —
        // so the window has to be genuinely on screen. It is transparent and
        // click-through, and it goes away as soon as the PDF is written.
        let win = NSWindow(contentRect: frame, styleMask: [.borderless],
                           backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.isRestorable = false
        win.contentView = web
        win.alphaValue = 0.01
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        win.level = .normal
        win.orderFrontRegardless()
        window = win

        PDFExporter.live.insert(self)
        log("loading \(deck.url.path), page \(Int(pageSize.width))x\(Int(pageSize.height))")
        web.loadHTMLString(html, baseURL: deck.dir)

        // pdf-ready is the happy path; this is the deck that never fires it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in self?.render() }
    }

    private func number(in s: String, key: String) -> CGFloat? {
        guard let re = try? NSRegularExpression(pattern: "\\b\(key):\\s*([0-9.]+)"),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s), let v = Double(s[r]) else { return nil }
        return CGFloat(v)
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        log("pdf-ready")
        // reveal keeps laying out for a beat after pdf-ready; let it finish.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.render() }
    }

    func webView(_ web: WKWebView, didFinish nav: WKNavigation!) {
        log("didFinish")
        waitForLayout(tries: 60)
    }

    /// reveal wraps every slide in a .pdf-page div once its print layout is
    /// done. Counting those is a stronger signal than the pdf-ready event,
    /// which older decks in the library predate.
    private func waitForLayout(tries: Int) {
        guard !settled, let web = web else { return }
        web.evaluateJavaScript("document.querySelectorAll('.pdf-page').length") { [weak self] v, _ in
            guard let self, !self.settled else { return }
            let n = (v as? Int) ?? 0
            if n > 0 {
                self.log("laid out \(n) pages")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.render() }
            } else if tries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.waitForLayout(tries: tries - 1) }
            } else {
                self.log("print layout never appeared; printing what there is")
                self.render()
            }
        }
    }

    func webView(_ web: WKWebView, didFail nav: WKNavigation!, withError e: Error) {
        finish("Could not load the deck: \(e.localizedDescription)")
    }

    private func render() {
        guard !settled, let web = web else { return }
        settled = true
        log("measuring pages")

        let js = """
        (function () {
          var ph = \(Int(pageSize.height)), out = [];
          var pages = document.querySelectorAll('.reveal .slides .pdf-page');
          for (var i = 0; i < pages.length; i++) {
            var r = pages[i].getBoundingClientRect();
            var x = r.left + window.scrollX, y = r.top + window.scrollY;
            var n = Math.max(1, Math.round(r.height / ph));
            for (var k = 0; k < n; k++) out.push([x, y + k * ph, r.width, ph]);
          }
          return JSON.stringify(out);
        })()
        """
        web.evaluateJavaScript(js) { [weak self] v, err in
            guard let self else { return }
            guard let s = v as? String, let data = s.data(using: .utf8),
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [[Double]],
                  !raw.isEmpty else {
                return self.finish("Could not measure the deck's print layout."
                                   + (err.map { " (\($0.localizedDescription))" } ?? ""))
            }
            let rects = raw.map { NSRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
            self.log("capturing \(rects.count) page(s)")
            self.capture(rects, at: 0, into: PDFDocument())
        }
    }

    /// One vector capture per slide, stitched with PDFKit. Deterministic where
    /// handing the whole scroll height to NSPrintOperation is not: the printer
    /// re-paginates a page that is already a page and never stops.
    private func capture(_ rects: [NSRect], at i: Int, into doc: PDFDocument) {
        guard let web = web else { return }
        if i >= rects.count {
            guard doc.pageCount > 0 else { return finish("Nothing was captured.") }
            let ok = doc.write(to: out)
            log("wrote \(doc.pageCount) page(s): \(ok)")
            return finish(ok ? nil : "Could not write \(out.lastPathComponent).")
        }
        let cfg = WKPDFConfiguration()
        cfg.rect = rects[i]
        web.createPDF(configuration: cfg) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let data):
                if let one = PDFDocument(data: data), let page = one.page(at: 0) {
                    doc.insert(page, at: doc.pageCount)
                }
                self.capture(rects, at: i + 1, into: doc)
            case .failure(let e):
                self.finish("Page \(i + 1) failed: \(e.localizedDescription)")
            }
        }
    }

    private func finish(_ error: String?) {
        window?.orderOut(nil)
        web?.configuration.userContentController.removeScriptMessageHandler(forName: "printReady")
        web = nil; window = nil
        done(error)
        PDFExporter.live.remove(self)
    }
}

// MARK: - Deck actions

enum DeckActions {
    static func revealInFinder(_ d: Deck) {
        NSWorkspace.shared.activateFileViewerSelecting([d.url])
    }

    static func openInBrowser(_ d: Deck) {
        NSWorkspace.shared.open(d.url)
    }

    static func editSlides(_ d: Deck) {
        let md = d.dir.appendingPathComponent("slides.md")
        NSWorkspace.shared.open(FileManager.default.fileExists(atPath: md.path) ? md : d.dir)
    }

    static func copyPath(_ d: Deck) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(d.dir.path, forType: .string)
    }

    /// Asks first, synchronously, so the caller knows whether anything is about
    /// to happen before it puts a spinner on screen.
    static func pdfDestination(for d: Deck) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = d.folder + ".pdf"
        panel.directoryURL = d.dir
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.title = "Export “\(d.title)” as PDF"
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// A deck is a folder of small text files plus a symlink to a shared
    /// reveal.js, so "start today's version from last time's" is a copy and a
    /// rebuild — never a touch of the original.
    static func duplicate(_ d: Deck, title newTitle: String) throws -> URL {
        guard !newTitle.trimmingCharacters(in: .whitespaces).isEmpty else { throw Err.cancelled }

        let fm = FileManager.default
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let stem = slug(newTitle)
        var name = "\(df.string(from: Date()))-\(stem)"
        var n = 2
        while fm.fileExists(atPath: Library.root.appendingPathComponent(name).path) {
            name = "\(df.string(from: Date()))-\(stem)-\(n)"; n += 1
        }
        let dest = Library.root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: false)

        for f in ["slides.md", "theme.css", "build.sh", "package.json", "check.js", "render-mermaid.js"] {
            let src = d.dir.appendingPathComponent(f)
            if fm.fileExists(atPath: src.path) {
                try fm.copyItem(at: src, to: dest.appendingPathComponent(f))
            }
        }
        // reveal.js is 30 MB; every deck here already shares one copy by symlink.
        let mods = d.dir.appendingPathComponent("node_modules")
        if fm.fileExists(atPath: mods.path) {
            let target = (try? fm.destinationOfSymbolicLink(atPath: mods.path)) ?? mods.path
            try? fm.createSymbolicLink(atPath: dest.appendingPathComponent("node_modules").path,
                                       withDestinationPath: target)
        }

        // the built <title> lives in build.sh's heredoc, not in slides.md
        let bs = dest.appendingPathComponent("build.sh")
        if var script = try? String(contentsOf: bs, encoding: .utf8) {
            script = script.replacingOccurrences(
                of: "<title>.*?</title>",
                with: "<title>" + escapeHTML(newTitle) + "</title>",
                options: .regularExpression)
            try? script.write(to: bs, atomically: true, encoding: .utf8)
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["build.sh"]
        p.currentDirectoryURL = dest
        var env = ProcessInfo.processInfo.environment
        env["GEN_WHO"] = "Presenter.app, duplicated from \(d.folder)"
        p.environment = env
        let err = Pipe(); p.standardError = err; p.standardOutput = Pipe()
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw Err.build(msg.isEmpty ? "build.sh exited \(p.terminationStatus)" : msg)
        }
        return dest
    }

    enum Err: LocalizedError {
        case cancelled
        case build(String)
        var errorDescription: String? {
            switch self {
            case .cancelled: return nil
            case .build(let m): return "build.sh failed:\n\n" + m
            }
        }
    }

    private static func slug(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive], locale: .current).lowercased()
        let cleaned = folded.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        return cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-")).isEmpty
            ? "deck" : cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func askTitle(for d: Deck) -> String? {
        let a = NSAlert()
        a.messageText = "Duplicate deck"
        a.informativeText = "Title for the copy. Its folder is dated with today automatically, "
                          + "and slides.md comes over unchanged for you to edit."
        a.addButton(withTitle: "Duplicate")
        a.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.stringValue = d.title
        a.accessoryView = field
        a.window.initialFirstResponder = field
        return a.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
}

// MARK: - Web view

struct DeckWebView: NSViewRepresentable {
    let url: URL
    let reloadToken: Int

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true

        let web = WKWebView(frame: .zero, configuration: cfg)
        web.setValue(false, forKey: "drawsBackground")   // no white flash on load
        web.allowsMagnification = true
        web.uiDelegate = context.coordinator
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        DispatchQueue.main.async { web.window?.makeFirstResponder(web) }
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        if context.coordinator.token != reloadToken {
            context.coordinator.token = reloadToken
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        DispatchQueue.main.async { web.window?.makeFirstResponder(web) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(token: reloadToken) }

    /// Without this the speaker view does not exist inside the app. Pressing S
    /// calls window.open, and a WKWebView with no UI delegate answers null and
    /// says nothing — so the deck looked fine in a browser and did nothing here,
    /// which is exactly the wrong way round for the window you present from.
    ///
    /// The second web view has to share the first one's configuration: that is
    /// what makes them the same script world, and the speaker window drives the
    /// deck entirely through window.opener.postMessage.
    final class Coordinator: NSObject, WKUIDelegate {
        var token: Int
        private var popups: [ObjectIdentifier: NSWindow] = [:]
        init(token: Int) { self.token = token }

        func webView(_ web: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            let w = (windowFeatures.width?.doubleValue).map { CGFloat($0) } ?? 1060
            let h = (windowFeatures.height?.doubleValue).map { CGFloat($0) } ?? 800
            let child = WKWebView(frame: NSRect(x: 0, y: 0, width: w, height: h),
                                  configuration: configuration)
            child.uiDelegate = self

            let win = NSWindow(contentRect: child.frame,
                               styleMask: [.titled, .closable, .miniaturizable, .resizable],
                               backing: .buffered, defer: false)
            win.title = "Speaker view"
            win.isReleasedWhenClosed = false
            win.isRestorable = false
            win.contentView = child
            win.center()
            // Not makeKey: the deck window keeps the keyboard, so the arrow keys
            // still drive the slides from the machine the presenter is typing on.
            win.orderFront(nil)
            popups[ObjectIdentifier(child)] = win

            // A speaker window outliving its deck is a stale set of notes and a
            // timer that means nothing, so it goes when the deck goes.
            if let deckWindow = web.window {
                NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification, object: deckWindow, queue: .main
                ) { [weak win] _ in win?.close() }
            }
            return child
        }

        func webViewDidClose(_ web: WKWebView) {
            popups.removeValue(forKey: ObjectIdentifier(web))?.close()
        }
    }
}

// MARK: - Library list

struct LibraryView: View {
    @Binding var decks: [Deck]
    let open: (Deck) -> Void
    let rescan: () -> Void
    let act: (DeckAction, Deck) -> Void
    @State private var filter: DeckCategory? = nil   // nil = All
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var hits: [Deck] { decks.filter { $0.matches(query) } }

    var filteredGroups: [(DeckCategory, [Deck])] {
        let grouped = Dictionary(grouping: hits, by: \.category)
        return DeckCategory.allCases.compactMap { cat in
            guard filter == nil || filter == cat else { return nil }
            guard let items = grouped[cat], !items.isEmpty else { return nil }
            return (cat, items)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Presentations").font(.system(size: 26, weight: .bold))
                    Text(Library.root.path.replacingOccurrences(
                        of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: rescan) { Label("Refresh", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r", modifiers: .command)
            }
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 12)

            // Search reads the slides, not just the names: the question is
            // almost always "which deck did I say that in?".
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                ZStack(alignment: .leading) {
                    if query.isEmpty {
                        Text("Search titles, folders and the words on the slides")
                            .font(.system(size: 13)).foregroundStyle(.tertiary)
                    }
                    TextField("", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($searchFocused)
                        .onSubmit { if let first = hits.first { open(first) } }
                }
                if searching {
                    Text("\(hits.count) of \(decks.count)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Button { query = ""; searchFocused = true } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 24).padding(.bottom, 12)
            .contentShape(Rectangle())
            .onTapGesture { searchFocused = true }
            .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in
                searchFocused = true
            }

            if !decks.isEmpty {
                // The split Oscar asked for: the daily/sprint record on one
                // side, the decks built to present to other people on the
                // other — same grouping as the dashboard's Decks tab.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterPill(label: "All (\(hits.count))", selected: filter == nil) { filter = nil }
                        ForEach(DeckCategory.allCases) { cat in
                            let n = hits.filter { $0.category == cat }.count
                            if n > 0 {
                                FilterPill(label: "\(cat.rawValue) (\(n))", selected: filter == cat) {
                                    filter = cat
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                }
                .padding(.bottom, 12)
            }

            Divider()

            if decks.isEmpty {
                empty(icon: "rectangle.on.rectangle.slash", head: "No decks found",
                      body: "Put a folder containing deck.html into\n~/Documents/presentations")
            } else if filteredGroups.isEmpty {
                empty(icon: "magnifyingglass", head: "Nothing matches “\(query)”",
                      body: "Search covers deck titles, folder names\nand the words on the slides.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredGroups, id: \.0) { cat, items in
                            Text(cat.rawValue)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 4)
                            ForEach(items) { deck in
                                DeckRow(deck: deck,
                                        snippet: searching ? deck.snippet(for: query) : nil,
                                        open: { open(deck) },
                                        act: { act($0, deck) })
                                Divider().padding(.leading, 24)
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 620, minHeight: 420)
        .onAppear {
            // The library is a list you arrive at to find something, so the
            // cursor starts where you would have clicked anyway.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { searchFocused = true }
        }
    }

    private func empty(icon: String, head: String, body: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 34)).foregroundStyle(.tertiary)
            Text(head).font(.headline)
            Text(body)
                .font(.system(size: 12, design: .monospaced))
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FilterPill: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(selected ? Color.accentColor : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

enum DeckAction: String, Identifiable, CaseIterable {
    case present, exportPDF, editSlides, openInBrowser, revealInFinder, duplicate, copyPath
    var id: String { rawValue }
    var label: String {
        switch self {
        case .present:        return "Present"
        case .exportPDF:      return "Export as PDF…"
        case .editSlides:     return "Edit slides.md"
        case .openInBrowser:  return "Open in browser"
        case .revealInFinder: return "Reveal in Finder"
        case .duplicate:      return "Duplicate as today's deck…"
        case .copyPath:       return "Copy folder path"
        }
    }
    var icon: String {
        switch self {
        case .present:        return "play.fill"
        case .exportPDF:      return "arrow.down.doc"
        case .editSlides:     return "square.and.pencil"
        case .openInBrowser:  return "safari"
        case .revealInFinder: return "folder"
        case .duplicate:      return "plus.square.on.square"
        case .copyPath:       return "doc.on.clipboard"
        }
    }
}

struct DeckRow: View {
    let deck: Deck
    var snippet: String? = nil
    let open: () -> Void
    let act: (DeckAction) -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(red: 0.10, green: 0.41, blue: 1.0))
                    .frame(width: 46, height: 30)
                    .overlay(Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 3) {
                    Text(deck.title).font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    HStack(spacing: 8) {
                        Text(deck.folder).font(.system(size: 11, design: .monospaced))
                        if let n = deck.slideCount {
                            Text("·"); Text("\(n) slides").font(.system(size: 11))
                        }
                        Text("·"); Text(deck.modifiedText).font(.system(size: 11))
                    }
                    .foregroundStyle(.secondary)
                    if let s = snippet {
                        Text(s)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .padding(.top, 1)
                    }
                    if let gen = deck.generator {
                        Text(gen)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(gen)
                    }
                }
                Spacer()
                if hovering {
                    Menu {
                        ForEach(DeckAction.allCases) { a in
                            if a == .revealInFinder || a == .duplicate { Divider() }
                            Button { act(a) } label: { Label(a.label, systemImage: a.icon) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.system(size: 14))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 22)
                    .help("Deck actions")
                }
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
            .background(hovering ? Color.primary.opacity(0.06) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            ForEach(DeckAction.allCases) { a in
                if a == .revealInFinder || a == .duplicate { Divider() }
                Button { act(a) } label: { Label(a.label, systemImage: a.icon) }
            }
        }
    }
}

// MARK: - Shortcuts

/// Every key this thing answers to, in one place, because the ones inside the
/// deck belong to reveal and the ones outside it belong to the app, and nobody
/// remembers which is which mid-talk.
struct ShortcutsSheet: View {
    let close: () -> Void

    private let library: [(String, String)] = [
        ("⌘F", "Search the library — titles, folders and slide text"),
        ("↩", "Open the first match"),
        ("⌘R", "Rescan ~/Documents/presentations"),
        ("right-click a deck", "Export PDF, edit slides.md, duplicate, reveal in Finder")
    ]
    private let deck: [(String, String)] = [
        ("→ ←  space", "Next / previous slide"),
        ("S", "Speaker view — notes, talk and slide timers, and a remote"),
        ("O  esc", "Overview of every slide"),
        ("B  .", "Black the screen for a discussion"),
        ("G", "Jump to a slide by number"),
        ("?", "reveal.js's own full key list"),
        ("⌃⌘F", "Full screen"),
        ("⌘E", "Export this deck as a PDF"),
        ("⌘R", "Reload after a rebuild"),
        ("⌘[", "Back to the library")
    ]
    private let speaker: [(String, String)] = [
        ("→ ←  space", "Drives the deck from the speaker window"),
        ("O", "All slides — click one to jump"),
        ("T", "Pause or resume the talk timer"),
        ("B", "Black the audience screen")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard shortcuts").font(.system(size: 17, weight: .bold))
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("In the library", library)
                    section("Presenting a deck", deck)
                    section("In the speaker window", speaker)
                }
                .padding(22)
            }
        }
        .frame(width: 560, height: 640)
    }

    private func section(_ title: String, _ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary).tracking(1)
            ForEach(rows, id: \.0) { key, what in
                HStack(alignment: .top, spacing: 12) {
                    Text(key)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 150, alignment: .leading)
                        .foregroundStyle(.primary)
                    Text(what).font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

// MARK: - Command line

/// `Presenter --export <deck.html|deck folder> [out.pdf]`
/// `Presenter --find <text>`
/// `Presenter --duplicate <deck.html|deck folder> <new title>`
///
/// The same code the windows run, driven from a script. `--export` is what
/// replaces tools/pdf.js — no playwright, no headless Chromium, no node.
enum CLI {
    static func run(_ args: [String]) -> Never {
        if args.contains("--find") { find(args) }
        if args.contains("--duplicate") { duplicate(args) }
        export(args)
    }

    private static func find(_ args: [String]) -> Never {
        guard let i = args.firstIndex(of: "--find"), args.count > i + 1 else {
            fail("usage: Presenter --find <text>")
        }
        let q = args[i + 1]
        let hits = Library.scan().filter { $0.matches(q) }
        for d in hits {
            print("\(d.folder)  —  \(d.title)")
            if let s = d.snippet(for: q) { print("    \(s)") }
        }
        print("\(hits.count) deck(s) match “\(q)”")
        exit(hits.isEmpty ? 1 : 0)
    }

    private static func duplicate(_ args: [String]) -> Never {
        guard let i = args.firstIndex(of: "--duplicate"), args.count > i + 2 else {
            fail("usage: Presenter --duplicate <deck.html|deck folder> <new title>")
        }
        guard let deck = load(args[i + 1]) else { fail("no such deck: \(args[i + 1])") }
        do {
            let dest = try DeckActions.duplicate(deck, title: args[i + 2])
            print("made \(dest.path)")
            exit(0)
        } catch {
            fail(error.localizedDescription)
        }
    }

    private static func load(_ path: String) -> Deck? {
        var src = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardized
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: src.path, isDirectory: &isDir)
        if isDir.boolValue { src.appendPathComponent("deck.html") }
        guard FileManager.default.fileExists(atPath: src.path) else { return nil }
        let html = (try? String(contentsOf: src, encoding: .utf8)) ?? ""
        let title = html.range(of: "<title>").flatMap { a in
            html.range(of: "</title>", range: a.upperBound..<html.endIndex)
                .map { String(html[a.upperBound..<$0.lowerBound]) }
        } ?? src.deletingLastPathComponent().lastPathComponent
        return Deck(id: src.path, title: title,
                    folder: src.deletingLastPathComponent().lastPathComponent,
                    url: src, modified: Date(), slideCount: nil, generator: nil, body: "")
    }

    static func export(_ args: [String]) -> Never {
        guard let i = args.firstIndex(of: "--export"), args.count > i + 1 else {
            fail("usage: Presenter --export <deck.html|deck folder> [out.pdf]")
        }
        guard let deck = load(args[i + 1]) else { fail("no such deck: \(args[i + 1])") }
        let src = deck.url
        let out = args.count > i + 2
            ? URL(fileURLWithPath: (args[i + 2] as NSString).expandingTildeInPath).standardized
            : src.deletingLastPathComponent()
                 .appendingPathComponent(src.deletingLastPathComponent().lastPathComponent + ".pdf")

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        DispatchQueue.main.async {
            PDFExporter(deck: deck, to: out) { err in
                if let err { fail(err) }
                print("wrote \(out.path)")
                exit(0)
            }.start()
        }
        app.run()
        exit(0)
    }

    private static func fail(_ m: String) -> Never {
        FileHandle.standardError.write(Data((m + "\n").utf8))
        exit(1)
    }
}

// MARK: - Root

struct RootView: View {
    // Deliberately empty, then filled in from .task. Scanning here used to
    // happen in init, which runs while AppKit is building the window — and the
    // first read of ~/Documents is where macOS decides whether to ask about
    // file access. Blocking the launch on that question means a window that
    // never appears and an app that looks hung with no error anywhere.
    @State private var decks: [Deck] = []
    @State private var scanned = false
    @State private var showing: Deck?
    @State private var reloadToken = 0
    @State private var busy: String?
    @State private var problem: String?
    @State private var shortcuts = false

    var body: some View {
        Group {
            if let deck = showing {
                DeckWebView(url: deck.url, reloadToken: reloadToken)
                    .ignoresSafeArea()
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            Button { showing = nil } label: {
                                Label("Library", systemImage: "chevron.left")
                            }
                            .keyboardShortcut("[", modifiers: .command)
                        }
                        ToolbarItem(placement: .principal) {
                            Text(deck.title).font(.system(size: 13, weight: .semibold))
                        }
                        ToolbarItem(placement: .primaryAction) {
                            Button { run(.exportPDF, deck) } label: {
                                Label("Export PDF", systemImage: "arrow.down.doc")
                            }
                            .keyboardShortcut("e", modifiers: .command)
                            .help("Export this deck as a PDF, one page per slide")
                        }
                        ToolbarItem(placement: .primaryAction) {
                            Button { reloadToken += 1 } label: {
                                Label("Reload", systemImage: "arrow.clockwise")
                            }
                            .keyboardShortcut("r", modifiers: .command)
                        }
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                NSApp.keyWindow?.toggleFullScreen(nil)
                            } label: {
                                Label("Present", systemImage: "arrow.up.left.and.arrow.down.right")
                            }
                            .keyboardShortcut("f", modifiers: [.command, .control])
                        }
                    }
            } else {
                LibraryView(decks: $decks,
                            open: { showing = $0 },
                            rescan: { reload() },
                            act: run)
            }
        }
        .task { if !scanned { scanned = true; reload() } }
        .overlay {
            if let busy {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(busy).font(.system(size: 12))
                }
                .padding(26)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .shadow(radius: 20)
            }
        }
        .alert("Presenter", isPresented: Binding(get: { problem != nil },
                                                 set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: { Text(problem ?? "") }
        .sheet(isPresented: $shortcuts) { ShortcutsSheet { shortcuts = false } }
        .onReceive(NotificationCenter.default.publisher(for: .showShortcuts)) { _ in
            shortcuts = true
        }
    }

    private func reload() {
        DispatchQueue.global(qos: .userInitiated).async {
            let found = Library.scan()
            DispatchQueue.main.async { decks = found }
        }
    }

    private func run(_ action: DeckAction, _ deck: Deck) {
        switch action {
        case .present:        showing = deck
        case .editSlides:     DeckActions.editSlides(deck)
        case .openInBrowser:  DeckActions.openInBrowser(deck)
        case .revealInFinder: DeckActions.revealInFinder(deck)
        case .copyPath:       DeckActions.copyPath(deck)
        case .exportPDF:
            guard let out = DeckActions.pdfDestination(for: deck) else { return }
            busy = "Exporting “\(deck.title)” to PDF…"
            PDFExporter(deck: deck, to: out) { err in
                busy = nil
                problem = err
                if err == nil { NSWorkspace.shared.activateFileViewerSelecting([out]) }
            }.start()
        case .duplicate:
            guard let title = DeckActions.askTitle(for: deck) else { return }
            busy = "Building the copy…"
            DispatchQueue.global().async {
                do {
                    let dest = try DeckActions.duplicate(deck, title: title)
                    let found = Library.scan()
                    DispatchQueue.main.async {
                        busy = nil
                        decks = found
                        if let made = found.first(where: { $0.id == dest.path }) { showing = made }
                    }
                } catch {
                    DispatchQueue.main.async {
                        busy = nil
                        if case DeckActions.Err.cancelled = error { return }
                        problem = error.localizedDescription
                    }
                }
            }
        }
    }
}

extension Notification.Name {
    static let focusSearch = Notification.Name("fi.oneira.presenter.focusSearch")
    static let showShortcuts = Notification.Name("fi.oneira.presenter.showShortcuts")
}

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--export") || args.contains("--find") || args.contains("--duplicate") {
            CLI.run(args)
        }
        // AppKit's window restoration and SwiftUI's WindowGroup do not agree
        // here: on a relaunch with saved state, AppKit blocks inside the open
        // AppleEvent waiting for SwiftUI to restore a scene, SwiftUI never calls
        // the completion handler back, and the app runs with zero windows and no
        // error. There is nothing worth restoring — the library rescans on every
        // launch — so opt out before AppKit reads the flag.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
        PresenterApp.main()
    }
}

struct PresenterApp: App {
    var body: some Scene {
        WindowGroup {
            RootView().frame(minWidth: 720, minHeight: 480)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("Find in Library") {
                    NotificationCenter.default.post(name: .focusSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") {
                    NotificationCenter.default.post(name: .showShortcuts, object: nil)
                }
                .keyboardShortcut("/", modifiers: .command)
            }
        }
    }
}
