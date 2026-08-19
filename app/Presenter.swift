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

// MARK: - Model

struct Deck: Identifiable, Hashable {
    let id: String
    let title: String
    let folder: String
    let url: URL
    let modified: Date
    let slideCount: Int?

    var modifiedText: String {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy"
        return f.string(from: modified)
    }
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
            let slides = countSlides(in: String(head))
            let mod = (try? html.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast

            decks.append(Deck(id: dir.path, title: title, folder: dir.lastPathComponent,
                              url: html, modified: mod, slideCount: slides))
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
    final class Coordinator { var token: Int; init(token: Int) { self.token = token } }
}

// MARK: - Library list

struct LibraryView: View {
    @Binding var decks: [Deck]
    let open: (Deck) -> Void
    let rescan: () -> Void

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
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 16)

            Divider()

            if decks.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.on.rectangle.slash")
                        .font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text("No decks found").font(.headline)
                    Text("Put a folder containing deck.html into\n~/Documents/presentations")
                        .font(.system(size: 12, design: .monospaced))
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(decks) { deck in
                            DeckRow(deck: deck) { open(deck) }
                            Divider().padding(.leading, 24)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 620, minHeight: 420)
    }
}

struct DeckRow: View {
    let deck: Deck
    let open: () -> Void
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
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
            .background(hovering ? Color.primary.opacity(0.06) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Root

struct RootView: View {
    @State private var decks: [Deck] = Library.scan()
    @State private var showing: Deck?
    @State private var reloadToken = 0

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
                            rescan: { decks = Library.scan() })
            }
        }
        .onAppear { decks = Library.scan() }
    }
}

@main
struct PresenterApp: App {
    var body: some Scene {
        WindowGroup {
            RootView().frame(minWidth: 720, minHeight: 480)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1180, height: 760)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}
