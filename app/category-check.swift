#!/usr/bin/env swift
// Standalone check for Deck.category's folder-name rules. Presenter is one
// swiftc-compiled file with no test target, so rather than duplicate the
// patterns here (and let them drift), this lifts them straight out of
// Presenter.swift and runs the same table of folder names past them.
//
//     swift app/category-check.swift
//
// Exits non-zero on the first disagreement.

import Foundation

let here = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let source = here.appendingPathComponent("Presenter.swift")
guard let swift = try? String(contentsOf: source, encoding: .utf8) else {
    FileHandle.standardError.write("cannot read \(source.path)\n".data(using: .utf8)!)
    exit(1)
}

/// Every `#"…"#` raw-string literal on the lines of Deck.category, in order:
/// the daily pattern first, then the sprint/retro one.
func patterns(in text: String) -> [String] {
    guard let body = text.range(of: "var category: DeckCategory {"),
          let end = text.range(of: "return .presentation", range: body.upperBound..<text.endIndex)
    else { return [] }
    let scope = String(text[body.upperBound..<end.lowerBound])
    var found: [String] = []
    var rest = scope[...]
    while let open = rest.range(of: "#\""), let close = rest.range(of: "\"#", range: open.upperBound..<rest.endIndex) {
        found.append(String(rest[open.upperBound..<close.lowerBound]))
        rest = rest[close.upperBound...]
    }
    return found
}

let found = patterns(in: swift)
guard found.count == 2 else {
    FileHandle.standardError.write("expected 2 regexes in Deck.category, found \(found.count)\n".data(using: .utf8)!)
    exit(1)
}
let dailyPattern = found[0], sprintPattern = found[1]

/// The same decision Deck.category makes, over the patterns it actually holds.
func category(_ folder: String) -> String {
    if folder == "daily-standup" { return "daily" }
    if folder.range(of: dailyPattern, options: .regularExpression) != nil { return "daily" }
    if folder.range(of: sprintPattern, options: .regularExpression) != nil { return "sprint" }
    return "presentation"
}

let cases: [(String, String)] = [
    // The bug: --retro-v2 names its folder with a trailing -v2, which used to
    // break the end anchor and drop the deck into "Meetings & presentations".
    ("2026-09-04-retro-2026-08-22-to-2026-09-04",     "sprint"),
    ("2026-09-04-retro-2026-08-22-to-2026-09-04-v2",  "sprint"),
    ("2026-09-04-retro-2026-08-22-to-2026-09-04-v3",  "sprint"),
    ("2026-09-04-retro-2026-08-22-to-2026-09-04-v10", "sprint"),
    ("daily-standup",                                 "daily"),
    ("2026-09-04-daily-standup",                      "daily"),
    ("2026-09-02-wave-2-kickoff",                     "presentation"),
    ("2026-09-04-automations-inventory",              "presentation"),
    // -vN loosens the anchor; it must not loosen it into anything else.
    ("2026-09-04-retro-2026-08-22-to-2026-09-04-v2-notes", "presentation"),
    ("2026-09-04-retro-2026-08-22-to-2026-09-04-final",    "presentation"),
    ("2026-09-04-retro-2026-08-22-to-2026-09",             "presentation"),
]

var failures = 0
for (folder, want) in cases {
    let got = category(folder)
    if got == want {
        print("ok    \(folder) → \(got)")
    } else {
        print("FAIL  \(folder) → \(got), expected \(want)")
        failures += 1
    }
}
print("")
print(failures == 0 ? "\(cases.count) passed" : "\(failures) of \(cases.count) failed")
exit(failures == 0 ? 0 : 1)
