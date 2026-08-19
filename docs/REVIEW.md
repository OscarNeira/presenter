# Presenter — pre-push review

Reviewed at commit `e0f4e23`, **plus one uncommitted change in the working tree** — see
finding 0. Everything below was verified by building and running the code on macOS 26.6.1 /
arm64, Swift 6.3.3, node 26.6.0, reveal.js 5.2.1 resolved from `^5.1.0`. Anything reasoned
rather than executed is marked **(inferred)**.

> **Note on the working tree.** `template/build.sh` was clean at 95 lines when this review
> started and gained an uncommitted 12-line block partway through (`template/build.sh:26-36`).
> It is reviewed here as finding 0. Nothing in this repo was modified by the review itself;
> `git status` should show only `template/build.sh` and this `docs/` directory.
>
> **Line numbers in this document refer to `HEAD` (`e0f4e23`)**, except inside finding 0 and
> rows 0a–0c of the table, which refer to the working tree. In the dirty tree everything in
> `template/build.sh` below line 25 is shifted by +12 — so `:49` reads as `:61`, `:70` as
> `:82`, `:86` as `:98`, and so on.

---

## Verdict

The committed code is ready to push. The design is right, the parts that are hard to get right
— the one-file output, the build-time mermaid pre-render, the viewBox checker — are the parts
done well, and `app/Presenter.swift` compiles with zero warnings under `-swift-version 6` with
`-strict-concurrency=complete`, which is more than most SwiftUI code manages.

**The uncommitted change is not ready and should not be pushed as written.** It rewrites the
author's `slides.md` in place during an ordinary build, and on a deck containing a fenced code
block with `---` in it, it manufactures slide separators inside the fence — verified: a
two-slide deck came out as four, with the code block split across three of them, and
`check.js` reported "All fit… no errors". The bug it is fixing is real; the fix is destructive.

Beyond that, the recurring theme across the repo is one class of problem: **the tool reports
success while silently producing something wrong.** `README.md:61` and `:115` document speaker
notes (**S**) that cannot work, because `template/build.sh:70` never loads the plugin that
binds the key. `template/build.sh:20` falls back to unrendered mermaid fences and still exits
0. And the mermaid theme mapping covers flowcharts only, so sequence and gantt diagrams ship
with hard-coded off-theme colours and no warning. A projector, in front of people, is a bad
place to discover any of those.

Nothing here is a security problem in any meaningful sense, but two lines of WebKit private
API (`app/Presenter.swift:88` and `:92`) are load-bearing and one of them is provably
unnecessary — the built deck makes exactly one network request, itself.

---

## Fix before pushing

### 0. The separator normaliser rewrites your source and corrupts decks — `template/build.sh:26-36` (uncommitted)

```sh
python3 - "$SRC" <<'NORM'
p = pathlib.Path(sys.argv[1]); t = p.read_text(encoding='utf-8')
n = re.sub(r'\n+---\n+', '\n\n---\n\n', t).strip() + '\n'
if n != t:
    p.write_text(n, encoding='utf-8')
NORM
```

The premise is correct. reveal compiles `data-separator="^\n---\n"` (`template/build.sh:49`)
multiline, so a blank line before `---` genuinely is required, and a deck missing one silently
merges two slides. Worth fixing. This is not the way.

Two defects, both verified end to end:

**It edits `slides.md` in place.** When there are no mermaid blocks `SRC=slides.md`
(`:16`), so `p.write_text` overwrites the author's source. Verified — `md5 slides.md` changed
from `a03abfd…` to `8df4045…` across a single `./build.sh`. A build script must not mutate its
input, and `.strip()` at `:32` silently trims the file on top of that. If the deck is not in
git — and `new-deck.sh` does not `git init` one — the original is gone.

**`\n+---\n+` has no idea what a code fence is.** Given this two-slide source:

````markdown
# Slide one

A yaml example:

```yaml
---
title: x
---
```

---

# Slide two
````

`./build.sh` printed `normalised slide separators`, inserted blank lines around the two `---`
inside the fence, and thereby *created* two new separators where none existed. Verified result:
**`4 slides. All fit, every SVG inside its viewBox, no errors.`** The code block is now split
across three slides, and the checker signs it off. The same hazard applies to any `---` inside
an inline `<svg>` or HTML block, which `README.md:103` already warns is fragile.

Patch — normalise into the temp file that already exists in this pipeline, never in place, and
skip fenced regions:

```sh
NORM_SRC=.slides.normalised.md
python3 - "$SRC" "$NORM_SRC" <<'NORM'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding='utf-8').read()
out, fenced = [], False
for line in text.split('\n'):
    if re.match(r'^\s*(```|~~~)', line):
        fenced = not fenced
    if not fenced and line.strip() == '---':
        out.append('')          # guarantee a blank line before
        out.append('---')
        out.append('')          # and after
    else:
        out.append(line)
normalised = re.sub(r'\n{3,}', '\n\n', '\n'.join(out))
open(dst, 'w', encoding='utf-8').write(normalised)
NORM
SRC="$NORM_SRC"
```

and add `.slides.normalised.md` to the `rm -f` at `:88` and to `.gitignore`. Guard `python3`
with `command -v` while you are there — as written it is now an unconditional hard dependency
of every deck build, and `set -e` aborts if it is absent.

Better still: do not rewrite anything. Detect the problem and refuse, which is the same
principle as findings 2 and 7. This needs no python and no temp file:

```sh
awk '
/^[ \t]*(```|~~~)/          { fence = !fence }
!fence && $0 == "---" && prev != "" {
    printf "  line %d: \047---\047 needs a blank line before it\n", NR; bad = 1
}
                            { prev = $0 }
END                         { exit bad ? 1 : 0 }
' "$SRC" || { echo "slides.md: fix the separators above, then rebuild" >&2; exit 1; }
```

Verified against three inputs: it flags the offending line, ignores `---` inside fenced code
blocks, and exits 0 on the real `template/slides.md`.

The author writes these files by hand. A build that tells them to add a blank line is better
than a build that edits their prose.

### 1. The **S** key does nothing. The README says it does. — `README.md:61`, `README.md:115`, `template/build.sh:70`

Verified: loading a built deck and inspecting the runtime gives
`Reveal.getPlugins() == ["markdown"]`, `hasPlugin("notes") == false`. In reveal.js 5.2.1 the
`S` binding lives only in `plugin/notes/notes.js`
(`addKeyBinding({keyCode:83,key:"S",description:"Speaker notes view"}...)`) — reveal core does
not bind 83. The notes themselves *are* in the file: `data-separator-notes="^Note:"`
(`template/build.sh:49`) correctly moves them into three `<aside class="notes">` elements,
computed `display: none`. So they are hidden, not leaked — but they are unreachable.

`template/slides.md:9-11` and `README.md:61` both teach the `Note:` convention, so the author
is writing notes they cannot read.

There is a second half to this, and it matters for the fix **(inferred, not executed)**: the
notes plugin in 5.2.1 uses `window.open` and writes the popup inline (no `notes.html` on disk,
confirmed by inspecting the bundle), which is fine over `file://` in a browser — but inside
`Presenter.app` a `WKWebView` with no `WKUIDelegate` **silently drops `window.open`**. So
adding the plugin fixes the browser case and not the app case until a `WKUIDelegate` exists.

Patch — `template/build.sh`, inline the plugin alongside the markdown one:

```sh
  cat "$R/dist/reveal.js"
  cat "$R/plugin/markdown/markdown.js"
  cat "$R/plugin/notes/notes.js"          # binds S; without it S does nothing
```
```js
  plugins: [ RevealMarkdown, RevealNotes ],
```

Then either implement `WKUIDelegate.webView(_:createWebViewWith:for:windowFeatures:)` in
`app/Presenter.swift` to open the popup in a real `NSWindow`, or — cheaper and honest —
change `README.md:115` to say the speaker view works in a browser, not in Presenter.

If you would rather not carry the plugin, delete the claim from `README.md:61` and `:115` and
drop `data-separator-notes` from `template/build.sh:49`. What is not acceptable is the
current state, where the README promises a presenting feature the build removes.

### 2. A failed mermaid render silently ships raw code fences — `template/build.sh:20`

```sh
node render-mermaid.js slides.md .slides.rendered.md && SRC=.slides.rendered.md
```

`render-mermaid.js:97-98` sets `process.exitCode = 1` on a bad diagram and *continues*, so a
single malformed block makes node exit 1. Under `set -euo pipefail` a failing command that is
not the last in an `&&` list does **not** abort — verified:

```
$ bash -c 'set -euo pipefail; SRC=orig; false && SRC=new; echo "SRC=$SRC"'
SRC=orig            # and rc=0
```

So `SRC` stays `slides.md`, `template/build.sh:86` writes a deck where every mermaid diagram
is a literal ```` ```mermaid ```` code block, and the script prints `Built deck.html (220K)`
and exits 0. `check.js` will not catch it either — a code block is not a clipped slide.

Patch:

```sh
if grep -q '```mermaid' slides.md 2>/dev/null; then
  if [ -d node_modules/mermaid ] && [ -d node_modules/playwright ]; then
    if node render-mermaid.js slides.md .slides.rendered.md; then
      SRC=.slides.rendered.md
    else
      echo "mermaid render failed — refusing to build a deck with unrendered diagrams" >&2
      exit 1
    fi
  else
    echo "slides.md has mermaid blocks but mermaid is not installed. Run: npm install" >&2
    exit 1
  fi
fi
```

The `else` branch at `template/build.sh:22` has the same shape: it warns and builds anyway.
A deck that is missing its diagrams should not build.

### 3. Two lines of WebKit private API; one is dead, the other has a supported replacement — `app/Presenter.swift:88`, `:92`

Both keys resolve today on macOS 26.6.1 — verified by calling them in a standalone binary.
The risk is not that they are undocumented, it is the failure mode when they stop resolving.
`setValue:forKey:` on an unknown key raises `NSUnknownKeyException`, which is an `NSException`
and therefore uncatchable from Swift. Verified:

```
*** Terminating app due to uncaught exception 'NSUnknownKeyException', reason:
    '[<WKWebView 0x...> setValue:forUndefinedKey:] ... not key value coding-compliant'
exit=134
```

Both calls are in `makeNSView`, so the failure is not a degraded appearance — the app launches,
shows the library, and hard-crashes the instant a deck is opened.

**`allowFileAccessFromFileURLs` (`:88`) is not needed at all.** Instrumented the built deck:
it issues exactly **one** request, `file://…/deck.html`. Zero subresources. The whole point of
`template/build.sh` is that reveal, the CSS, the slides and the SVGs are inlined, and the
header comment at `template/build.sh:6-8` says as much. The pref grants a capability the page
never exercises. Delete the line.

**`drawsBackground` (`:92`) has a supported equivalent** since macOS 12:
`web.underPageBackgroundColor` (verified present, returns opaque white by default). Setting it
to `.clear` or `.windowBackgroundColor` removes the white flash without KVC.

Patch:

```swift
let cfg = WKWebViewConfiguration()
cfg.defaultWebpagePreferences.allowsContentJavaScript = true

let web = WKWebView(frame: .zero, configuration: cfg)
web.underPageBackgroundColor = .clear      // no white flash, no private API
web.allowsMagnification = true
web.loadFileURL(url, allowingReadAccessTo: url)   // the file, not its folder
```

Note the third change: `app/Presenter.swift:94` currently passes
`url.deletingLastPathComponent()`, granting the page read access to the entire deck folder —
which, after `new-deck.sh`, contains a 176 MB `node_modules`. Passing the file itself scopes
WebKit to exactly that one file, which is all the deck needs.

### 4. `Library.scan()` runs twice at launch, on the main actor, reading every byte of every deck — `app/Presenter.swift:53`, `:202`, `:242`

`app/Presenter.swift:53` reads the whole file and *then* truncates:

```swift
let head = (try? String(contentsOf: html, encoding: .utf8))?.prefix(400_000) ?? ""
```

Then `String(head)` at `:54` and `:56` materialises it twice more, an `NSRegularExpression`
runs over it at `:68`, and `components(separatedBy: "\n---\n")` at `:75` allocates an array of
every fragment. Per deck.

Measured, 30 decks × 222 KB, warm page cache, against a straight port of the current code:

```
current  (whole-file read + prefix):  110.4 ms/scan
bounded  (first 96 KB via FileHandle): 44.3 ms/scan
```

It also runs twice on every launch. `@State private var decks: [Deck] = Library.scan()`
(`:202`) is evaluated whenever the `RootView` struct is constructed, and `.onAppear { decks =
Library.scan() }` (`:242`) throws that result away and does it again. That is ~220 ms of
blocked main thread before the window is usable, and 110 ms every ⌘R. SwiftUI reconstructs
view structs freely, so the `:202` initialiser can fire more than once **(inferred — the
double-evaluation at launch is confirmed by inspection; how many extra times SwiftUI
reconstructs `RootView` is not)**.

For scale: the slides in a built deck sit between byte 64090 and 66955 — everything the scan
wants is in the first ~67 KB, and reveal.js is inlined *after* it. 400 KB was already generous;
the whole file is 3× more than that.

Patch — drop the `:202` initialiser, read a bounded prefix, and get it off the main actor:

```swift
enum Library {
    static func scan() async -> [Deck] {
        await Task.detached(priority: .userInitiated) { scanSync() }.value
    }

    private static func scanSync() -> [Deck] {
        // …
        guard let fh = try? FileHandle(forReadingFrom: html) else { continue }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: 128 * 1024),
              let head = String(data: data, encoding: .utf8) else { continue }
        // …
    }
}
```

```swift
@State private var decks: [Deck] = []          // was Library.scan()
// …
.task { decks = await Library.scan() }         // was .onAppear
```

and `rescan: { Task { decks = await Library.scan() } }` at `:239`.

While in there: `Deck.modifiedText` (`:24-28`) builds a fresh `DateFormatter` on every read,
and it is read inside a `LazyVStack` row body (`:182`). Hoist it to a `static let`. Its
`dateFormat = "d MMM yyyy"` (`:26`) is also a fixed pattern that ignores the user's locale —
`dateStyle = .medium` is one word shorter and correct everywhere.

### 5. Mermaid theming covers flowcharts only — `template/render-mermaid.js:33-40`, `:66-82`, `:102-104`

The sentinel-hex trick is sound *as a mechanism*: `TOKENS` (`:33-40`) uses values with no
regex metacharacters, the ids are unique per block (`'mmd' + i`, `:94`) so the injected
`<style>` blocks do not collide, and `htmlLabels: false` (`:63`) keeps labels as real `<text>`.
The header comment at `:10-13` explains it honestly.

What it does not survive is mermaid *deriving* colours from the ones you set. Every derived or
defaulted value stays a hard-coded hex, and the swap never sees it. Rendered one flowchart,
one sequenceDiagram and one gantt through the actual renderer and counted the survivors:

| diagram | leftover hard-coded colours | live examples |
|---|---|---|
| `flowchart` | 5 hex + 2 rgb() | `.labelBkg{background-color:rgba(255,255,254,0.5)}` — the rest are dead `.error-icon` / marker selectors |
| `sequenceDiagram` | 10 hex + 3 rgb() | `.actor{stroke:#9370DB}` (purple), `rect.note{fill:#fff5ad}` (yellow), inline `fill="#eaeaea" stroke="#666"` |
| `gantt` | 10 hex + 2 rgb() | `.task0…3{fill:#8a90dd;stroke:#534fbc}`, `.section2{fill:#fff400}` |

A sequence diagram with a `Note right of` renders a pale-yellow box on a dark deck. A gantt
chart renders in mermaid's default periwinkle regardless of the theme. Neither is caught by
`check.js`, which has no opinion about colour.

Note the flowchart row too: `rgba(255, 255, 254, 0.5)` is the `--paper` sentinel that mermaid
re-emitted in `rgba()` form, so it escaped the hex-only replace at `:102-104`. Any flowchart
with an edge label (`a -->|label| b`) gets a near-white halo behind that label on a dark deck.

Two patches, both cheap. First, catch the `rgb()` form:

```js
for (const [hex, token] of Object.entries(TOKENS)) {
  svg = svg.replace(new RegExp(hex, 'gi'), token);
}
// mermaid re-emits some sentinels as rgb()/rgba() — catch those too
const rgbOf = h => [1,3,5].map(i => parseInt(h.slice(i, i+2), 16)).join(',\\s*');
for (const [hex, token] of Object.entries(TOKENS)) {
  svg = svg.replace(new RegExp(`rgba?\\(\\s*${rgbOf(hex)}[^)]*\\)`, 'gi'), token);
}
```

Second — and this is the one worth having — make the invisible failure visible:

```js
const leftovers = [...new Set(
  (cleaned.match(/#[0-9a-fA-F]{3,8}\b|rgba?\([^)]*\)/g) || [])
)].filter(c => !/error|marker/i.test(c));
if (leftovers.length) {
  console.warn(`diagram ${i + 1}: ${leftovers.length} colour(s) not bound to the theme: ` +
               leftovers.slice(0, 8).join(' '));
}
```

Then extend `themeVariables` (`:66-82`) with the sequence and gantt keys as you actually use
those diagram types, guided by the warning, rather than guessing at the full list now.

**`securityLevel: 'strict'` (`:61`) is doing the right thing** and is worth keeping even
though it is mermaid's default: it disables `click` directives and escapes HTML in labels, and
combined with `htmlLabels: false` (`:63`) every label lands as an escaped `<text>` node. Since
the SVG is then inlined verbatim into `deck.html`, that is exactly the property you want. No
change needed — documented here so it does not get "simplified" away later.

### 6. `new-deck.sh` can produce an empty slug, and drops non-ASCII titles — `new-deck.sh:11`, `:14`

Verified against the actual pipeline:

```
title="Café plan"   -> dir 2026-08-19-caf-plan     # é dropped
title="計画 2026"     -> dir 2026-08-19-2026        # title gone entirely
title="-n"          -> dir 2026-08-19-             # echo ate it
title="  "          -> dir 2026-08-19-             # [ -n ] passes on whitespace
```

Two separate bugs: `echo "$TITLE"` (`:14`) interprets `-n` as a flag, and `tr`/`sed` are
byte-oriented so any non-ASCII title collapses to nothing. An empty slug gives a directory
named `2026-08-19-`, and a second one the same day trips the `already exists` guard at `:17`
with a confusing message.

Patch:

```sh
[ -n "${TITLE//[[:space:]]/}" ] || { echo "usage: ./new-deck.sh \"Deck title\" [parent-dir]"; exit 1; }

SLUG=$(printf '%s' "$TITLE" \
  | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null || printf '%s' "$TITLE")
SLUG=$(printf '%s' "$SLUG" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
[ -n "$SLUG" ] || SLUG=deck
```

`printf` instead of `echo`, `iconv //TRANSLIT` so `Café` becomes `cafe`, and a fallback so the
directory is never just a date and a dash.

### 7. `deck.html` is written by a truncating redirect — `template/build.sh:28`, `:86`

`{ … } > "$OUT"` truncates `deck.html` the moment the block starts. If any `cat` inside fails
— `theme.css` deleted, `$R/dist/reveal.js` missing after a botched `npm install` — `set -e`
aborts partway and leaves a half-written `deck.html` on disk with a plausible size. The next
thing that happens is somebody opens it in front of a room.

One-line fix:

```sh
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
```

Same treatment is worth giving `rm -f .slides.rendered.md` at `:88`, which currently runs
before the size is reported and after the output is committed — order is fine, just move it
after the `mv`.

### 8. `tools/pdf.js` cannot run the way the README documents it — `tools/pdf.js:5`, `README.md:125`

`README.md:125` says `node tools/pdf.js path/to/deck.html out.pdf`, run from the repo root.
`tools/pdf.js:5` does `require('playwright')`, and there is no `package.json` or `node_modules`
at the repo root — playwright only exists inside a deck directory created by `new-deck.sh`.
Node's resolution walks up from `tools/`, finds nothing, and throws `MODULE_NOT_FOUND`.

Either add a minimal root `package.json` declaring playwright, or — simpler, and consistent
with everything else being per-deck — move `pdf.js` into `template/`, add
`"pdf": "node pdf.js"` to `template/package.json:8-12`, and change `README.md:125` to:

```bash
cd ~/Documents/presentations/<deck> && npm run pdf
```

Also worth wrapping the body in `try/finally { await b.close() }`: `tools/pdf.js:10-19` has no
error handling at all, so a bad path prints a raw unhandled-rejection stack.

---

## Worth doing later

**A literal `</textarea>` in `slides.md` silently truncates the deck.** The comment at
`template/build.sh:53` says "slides.md goes inside a `<textarea>`, so nothing in it is parsed
as HTML" — that is true of everything except the one string that closes the element. Verified:
a two-slide deck whose first slide contains the text `` `</textarea>` `` builds without
complaint, and `check.js` reports "1 slides. All fit… no errors." The second slide is gone.
Fix by escaping on the way in — `sed 's#</textarea#\&lt;/textarea#g' "$SRC"` at
`template/build.sh:54` — or accept it and let `check.js` catch it (below). Low priority
because you only write slides about HTML occasionally, but the failure is invisible when it
happens.

**`check.js` should assert the slide count against the source.** It is the one check that
would have caught both the `</textarea>` truncation *and* a mermaid fallback, and it is three
lines: count `\n---\n` in `slides.md`, compare to `total` at `check.js:33-34`, fail on
mismatch. Right now `check.js` validates the deck it was given without any notion of what the
deck was supposed to contain.

**`check.js` exits with a raw stack trace on a bad path.** `check.js:22-105` has no
`try/finally`; `node check.js does-not-exist.html` prints
`node:internal/process/promises:324 triggerUncaughtException` and a Playwright call log.
Wrap it the way `render-mermaid.js:115-121` already does — that file gets it right, this one
does not.

**`getBBox()` ignores stroke width.** `check.js:56-59` compares the geometric bounding box
against the viewBox. A path sitting exactly on `y=0` with `stroke-width="6"` renders 3px above
the box and is clipped, and the check passes. Widening the comparison by the largest
`stroke-width` in the SVG would close it. Worth knowing about; probably not worth the code.

**Links in a deck hijack the presenter view.** `app/Presenter.swift:82-109` sets no
`WKNavigationDelegate`, so an `<a href="https://…">` clicked mid-presentation navigates the
web view away from the deck, in-app, with no URL bar and no back button — ⌘[ returns to the
library and ⌘R reloads, so it is recoverable, but not obviously **(inferred — reasoned from
the absence of a delegate, not clicked through)**. One small delegate class solves this plus
two other items on this list:

```swift
final class Coordinator: NSObject, WKNavigationDelegate {
    var token: Int
    init(token: Int) { self.token = token }

    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction,
                 decisionHandler d: @escaping (WKNavigationActionPolicy) -> Void) {
        if a.navigationType == .linkActivated, let u = a.request.url, !u.isFileURL {
            NSWorkspace.shared.open(u); d(.cancel); return
        }
        d(.allow)
    }

    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!,
                 withError e: Error) {
        NSLog("deck failed to load: \(e.localizedDescription)")
    }
}
```

**Nothing surfaces a load failure.** With no navigation delegate, an unreadable or corrupt
`deck.html` opens as a blank view with no message. Upstream of that, `Library.scan()` also
lists a deck it could not read: `app/Presenter.swift:53` falls back to `""`, `:55` falls back
to the folder name, and the row appears normally. The delegate above covers it.

**`makeFirstResponder` is called on every SwiftUI update.** `app/Presenter.swift:104` schedules
a focus grab inside `updateNSView`, which runs on every invalidation of any ancestor state —
so any toolbar interaction yanks focus back to the web view on the next update. The dispatch in
`makeNSView` (`:95`) is legitimate (the view has no `window` yet), but the right shape is to
put it where the window actually arrives:

```swift
final class DeckWeb: WKWebView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }
}
```

Then both `DispatchQueue.main.async` blocks go away.

**`updateNSView` ignores `url` changes.** `app/Presenter.swift:99-105` only reloads when
`reloadToken` moves. Today this is unreachable — `RootView.body` (`:207-241`) routes every
deck change through `showing = nil`, which switches the `_ConditionalContent` branch and
destroys the view — but it is a latent trap for whoever adds a deck switcher. Compare
`web.url != url` as well; it is one clause.

**Per-deck `node_modules` is 176 MB, of which 83 MB is mermaid.** Measured on a template
install. reveal.js itself is 5.8 MB, and only `dist/reveal.js`, `dist/reveal.css`,
`dist/reset.css` and the markdown plugin are ever read. Keeping reveal per-deck is correct
(see *Deliberately fine*), but mermaid and playwright are pure build-time tooling and could
live once at the repo root, with `template/build.sh` and `check.js` resolving upward. Ten
decks currently cost 1.7 GB plus a shared 554 MB playwright browser cache.

**No lockfile, so an old deck does not rebuild the same way.** `.gitignore:13` ignores
`package-lock.json` and `template/package.json:14` pins `^5.1.0`, which resolved to 5.2.1
today. A deck rebuilt in three years gets whatever reveal 5.x is current. Since the whole
premise is "this file still works on a borrowed laptop", commit a `package-lock.json` in
`template/` and copy it in `new-deck.sh:20`. That is the one dependency-management change that
earns its keep.

**A deck folder has no `.gitignore`.** `README.md:14` sells "the whole deck diffs in git like
anything else", but `new-deck.sh:20` copies six files and none of them stop a `git init` in
the deck folder from committing 176 MB of `node_modules` and a 222 KB generated `deck.html`.
Ship `template/deck.gitignore` and copy it as `.gitignore`.

**`Info.plist` is missing `NSDocumentsFolderUsageDescription`** — `app/build.sh:13-32`. The
app reads `~/Documents/presentations`, which is TCC-protected on macOS 13+. Without the usage
string the consent prompt shows a generic message **(inferred — the plist omission is
confirmed, the prompt text is not, since this machine has already granted access)**. Worse is
the failure path: if consent is denied, `contentsOfDirectory` fails, `Library.scan()` returns
`[]` at `app/Presenter.swift:42`, and the user sees "No decks found — put a folder containing
deck.html into ~/Documents/presentations" (`:141`) forever, with no hint that it is a
permissions problem. Add the string, and distinguish "directory unreadable" from "directory
empty" in the empty state. Related: because the bundle is ad-hoc signed
(`app/build.sh:77`, verified `Signature=adhoc`, `TeamIdentifier=not set`), the TCC grant is
keyed to the binary hash, so every rebuild is likely to re-prompt **(inferred)**.

**The build is arm64-only** — `app/build.sh:36` hardcodes `-target arm64-apple-macosx13.0`,
verified: `Mach-O 64-bit executable arm64`. For a repo about to be shared, `-target
"$(uname -m)-apple-macosx13.0"` costs nothing and lets it build on Intel. `README.md:38` says
"macOS 13+" without mentioning Apple silicon.

**`codesign` failures are invisible** — `app/build.sh:77` is
`codesign … >/dev/null 2>&1 || true`. Drop `--deep` (deprecated by Apple) and drop the
suppression; a signing failure should be loud. Same at `:70` and `:72`, where `sips` and
`iconutil` errors are swallowed and you get an app with no icon and no explanation.

**The library path is hardcoded** — `app/Presenter.swift:33-36`. Not worth a preferences
window; worth two lines reading a `UserDefaults` key so it can be pointed elsewhere without a
recompile.

**The header comment is spliced mid-sentence** — `app/Presenter.swift:1-8`. Line 2 ends "…lists
the decks in ~/Documents/presentations", then the author and licence lines, then line 5
resumes "and opens them in an embedded browser". It is the first thing a reader sees. Move
lines 3-4 to the bottom of the block.

---

## Deliberately fine — do not "fix" these

**The one-file build is the right call.** Measured: 222 KB for a six-slide deck, of which
112 KB is `reveal.js`, 54 KB `reveal.css`. That is smaller than a single slide's worth of
stock photography in any other tool, it needs no server, no CDN, no `npx serve`, and it
survives being emailed. The usual objections do not apply here: caching is irrelevant on
`file://`; diffing is irrelevant because `deck.html` is a build artifact and `.gitignore:2`
correctly excludes it (you diff `slides.md`); and "upgrades" are a feature, not a cost — each
deck freezes the reveal version it was built with, so a talk from 2024 still renders in 2030.
The only real cost is the per-deck `node_modules`, which is a separate problem with a separate
fix.

**`[ -e "$DIR" ] && { echo …; exit 1; }` under `set -e`** — `new-deck.sh:17`. This looks like
the classic `set -e` foot-gun and is not: a failing command that is not the last in an `&&`
list does not trigger the exit. Verified — the script reaches the next line with `rc=0` when
the directory does not exist.

**The slug neutralises path traversal** — `new-deck.sh:14`. `s/[^a-z0-9]+/-/g` turns
`a/b/../../etc` into `a-b-etc`. Verified. The `$TITLE` also passes through `python3` via
`sys.argv` (`new-deck.sh:24-26`), not through the shell, and the heredocs in both `build.sh`
files are quoted (`<<'PLIST'`, `<<'HTML_HEAD'`), so nothing in a title or a slide is ever
shell-expanded. The quoting throughout both scripts is correct — spaces and unicode in
`$PARENT` and `$DIR` are handled.

**No symlink-loop risk.** `app/Presenter.swift:40` uses `contentsOfDirectory`, which is not
recursive. There is nothing to loop. A symlink *to* a deck folder works fine, because
`fileExists(atPath:isDirectory:)` at `:47` follows it.

**`<textarea>` for the slide payload is the right container**, aside from the one escape noted
above. Verified that `reveal.js`, `markdown.js` and the three CSS files contain zero `</script`
and zero `</style` sequences, so the inline assembly at `template/build.sh:60-67` is safe.

**No vertical slides, so `check.js` enumerating only `.slides > section` is complete.**
`template/build.sh:49` sets `data-separator` but not `data-separator-vertical`, so the markdown
plugin cannot produce nested stacks. `check.js:33-34` is not missing anything.

**`check.js`'s fixed 2000 ms / 450 ms waits** (`:31`, `:47`) are fine for a smoke test that
runs once per rebuild. Don't replace them with polling.

**Ad-hoc signing** (`app/build.sh:77`) is correct for a locally-built tool. A locally-compiled
app carries no quarantine attribute, so Gatekeeper never prompts. Do not go near notarisation
for this.

**The Swift is clean.** Compiles with zero warnings under `-swift-version 6
-strict-concurrency=complete` — verified, exit 0. The `Coordinator`/`reloadToken` pattern
(`app/Presenter.swift:100-108`) is the idiomatic way to trigger an imperative action from a
value-type representable, and the token is correctly seeded in `makeCoordinator` (`:107`) so
the first `updateNSView` does not double-load. `check.js`'s overflow detection genuinely works
— fed it a 40-item slide and it reported `SLIDES CLIPPED BY THE FRAME` and exited 1; a clean
deck exits 0.

---

## README accuracy

Checked every claim. Most hold:

- "A 320 KB native app" (`README.md:24`) — measured 320 KB, 300512-byte binary. Accurate.
- "One file output… no server, no localhost, no network" (`:21-23`) — accurate, one request.
- "`npm run check` fails on a slide clipped by the frame and an SVG outside its viewBox"
  (`:25-27`) — both verified working.
- "Mermaid colours are bound to the theme's CSS variables" (`:95-96`) — true for flowcharts,
  false for sequence and gantt. See finding 5.
- Speaker notes / **S** (`:61`, `:115`) — false. See finding 1.
- `node tools/pdf.js` (`:125`) — cannot run as written. See finding 8.
- `docs/  conventions and notes` (`:135`) — the directory did not exist before this review.

Missing for someone cloning it:

1. **node and npm are prerequisites.** `README.md:38` names macOS 13+ and the Xcode command
   line tools; `new-deck.sh:35` needs npm and neither script checks for it.
2. **Apple silicon only**, until `app/build.sh:36` is changed.
3. **Each deck costs ~176 MB of `node_modules`**, plus a shared ~554 MB playwright browser
   cache on first install.
4. **The install snippet leaves you in `app/`** (`README.md:33`), then `:43` says
   `./new-deck.sh`, which lives one directory up. Add the `cd ..`.
5. **The library path is hardcoded** to `~/Documents/presentations` and cannot be changed
   without recompiling.
6. **No uninstall path.** Three lines: `rm -rf /Applications/Presenter.app`, note that the
   decks in `~/Documents/presentations` are yours to keep, and mention revoking the Documents
   permission in System Settings → Privacy & Security → Files and Folders.

**On "an AI can draft one" (`README.md:16-17`)** — as written this is an assertion with
nothing behind it. Nothing in the repo is addressed to a model: no `AGENTS.md`, no prompt,
no machine-readable statement of the conventions anywhere. What *is* true is
that the conventions are unusually well specified — the markup table at `README.md:63-74`, the
two SVG rules at `:101-106`, and `template/slides.md` as a worked example are already the
whole spec. The gap is packaging, not substance.

Make it concrete with one file, `docs/CONVENTIONS.md`, that is the thing you paste or point a
model at: the markup table, the two SVG rules, the mermaid fence syntax, the "one idea per
slide" rule from `template/slides.md:17`, and an explicit statement of the output contract
(*edit `slides.md` only; run `./build.sh` then `npm run check`; a deck is not done until check
exits 0*). Then `README.md:16-17` can point at it and the claim is demonstrably true instead of
aspirational. Until then, soften the sentence.

---

## What is genuinely missing for a real project

Pragmatic read: this is a personal tool that may be shared, so most of the usual checklist is
overhead. Ranked by whether it earns its keep.

**Worth adding:**

- **`docs/CONVENTIONS.md`** — see above. Highest value per line in this whole document. It
  makes the README's central claim true and doubles as your own reference.
- **A lockfile in `template/`** — the only thing standing between "this deck still opens in
  2030" and "this deck rebuilds into something else in 2030".
- **`template/deck.gitignore`** — one file, prevents committing 176 MB by accident.
- **Uninstall lines in the README** — three lines, and the TCC grant is not obvious.
- **A version somewhere real.** `app/build.sh:24-25` hardcodes `1.0` / `1` in the plist, and
  `template/package.json:3` says `1.0.0` for something that is never published. Pick one
  source of truth — a `VERSION` file read by `app/build.sh` — and tag releases. Cheap, and it
  makes "which build is on this laptop" answerable.

**Not worth adding:**

- **CI.** There is one platform, one user, and a `swiftc` invocation that takes seconds. A
  GitHub Actions runner cannot exercise the interesting part (the app, WebKit, the projector).
  If you ever want a guard, the useful one is a smoke script — `new-deck.sh` a throwaway deck
  into `$TMPDIR`, build it, run `check.js`, assert exit 0 — run locally before pushing. That
  would have caught findings 2, 6 and 7.
- **Unit tests.** There is almost nothing unit-testable here that is not better covered by the
  smoke script. `check.js` *is* the test suite, and it tests the thing that actually matters.
- **CONTRIBUTING.md.** For a private repo with one author, this is ceremony. Add it the day
  someone else opens a PR.
- **Cross-platform support.** The launcher is the macOS-specific part and it is 250 lines; the
  deck pipeline is already portable (bash + node). A note in the README saying "decks build
  anywhere node runs; the launcher is macOS only" is the whole cross-platform story, and it is
  accurate as written.

---

## Findings table

| # | Location | Severity | Issue | Fix |
|---|---|---|---|---|
| 0a | `template/build.sh:29-36` (uncommitted) | **Critical** | Rewrites `slides.md` in place during a normal build — verified md5 change across one `./build.sh`; `.strip()` trims the file too | Normalise into a temp file, or detect and refuse |
| 0b | `template/build.sh:32` (uncommitted) | **Critical** | `\n+---\n+` matches inside fenced code blocks and HTML/SVG blocks, manufacturing separators. Verified: 2-slide deck → 4 slides, code block split across three, `check.js` reports no errors | Track fence state; see the awk detector above |
| 0c | `template/build.sh:29` (uncommitted) | Medium | `python3` is now an unguarded hard dependency of every deck build; `set -e` aborts if absent | `command -v python3` guard, or drop python for awk |
| 1 | `README.md:61`, `README.md:115`, `template/build.sh:70` | High | **S** speaker-notes key is documented but unbound — verified `Reveal.getPlugins() == ["markdown"]`. Notes exist as hidden `aside.notes` and are unreachable | Inline `plugin/notes/notes.js` and add `RevealNotes`; add a `WKUIDelegate` for the popup inside the app, or drop the claim |
| 2 | `template/build.sh:20` | High | A failing mermaid render leaves `SRC=slides.md`; the build prints success and ships literal ```` ```mermaid ```` fences | Use an `if node …; then … else exit 1; fi` |
| 3 | `template/build.sh:22` | Medium | Missing mermaid warns and builds a deck without its diagrams | `exit 1` |
| 4 | `app/Presenter.swift:88` | Medium | `allowFileAccessFromFileURLs` private KVC; the deck makes zero subresource requests, so it grants nothing. Crashes with `NSUnknownKeyException` if the key ever goes | Delete the line |
| 5 | `app/Presenter.swift:92` | Medium | `drawsBackground` private KVC, same crash mode (verified exit 134) | `web.underPageBackgroundColor = .clear` |
| 6 | `app/Presenter.swift:94` | Low | `allowingReadAccessTo:` scopes WebKit to the whole deck folder, incl. 176 MB `node_modules` | Pass `url` itself |
| 7 | `app/Presenter.swift:53` | Medium | Reads the entire 222 KB file then `.prefix(400_000)`; 110 ms/scan for 30 decks vs 44 ms bounded | `FileHandle.read(upToCount: 128 * 1024)` |
| 8 | `app/Presenter.swift:202` + `:242` | Medium | `scan()` runs twice at launch, both on the main actor (~220 ms measured, 30 decks) | `@State private var decks: [Deck] = []` + `.task { decks = await Library.scan() }` |
| 9 | `app/Presenter.swift:24-28` | Low | New `DateFormatter` per row render inside a `LazyVStack` | `static let`; use `dateStyle = .medium` for locale correctness |
| 10 | `template/render-mermaid.js:66-82` | Medium | `themeVariables` covers flowchart keys only; sequence leaks `#9370DB`/`#fff5ad`/`#eaeaea`, gantt leaks `#8a90dd`/`#534fbc`/`#fff400` — all live, all off-theme | Extend `themeVariables`; add a leftover-colour warning |
| 11 | `template/render-mermaid.js:102-104` | Medium | Hex-only replace misses mermaid's `rgba()` re-emission — `.labelBkg{rgba(255,255,254,0.5)}` survives on every flowchart with an edge label | Add an `rgba?()` pass over the same sentinels |
| 12 | `template/render-mermaid.js:110` | Low | `out.replace(full, cleaned)` — string replacement interprets `$&`, `` $` ``, `$1` in the SVG; and two byte-identical fences mis-target if the first one failed to render | Use a replacer function: `out.replace(full, () => …)` |
| 13 | `new-deck.sh:14` | Medium | `echo "$TITLE"` eats `-n`; `tr`/`sed` drop non-ASCII → empty slug, directory named `2026-08-19-`. Verified | `printf` + `iconv //TRANSLIT` + a `deck` fallback |
| 14 | `new-deck.sh:11` | Low | `[ -n "$TITLE" ]` passes on a whitespace-only title | `[ -n "${TITLE//[[:space:]]/}" ]` |
| 15 | `new-deck.sh:30` | Low | Title is injected into `<title>` unescaped; `<` or `&` in a deck name produces malformed HTML. `app/Presenter.swift:55` only ever un-escapes `&amp;` | `html.escape(title)` in the python block |
| 16 | `new-deck.sh:35-36` | Low | `npm install` and `./build.sh` output fully suppressed; a 176 MB install shows nothing after "installing reveal.js…", and build warnings are hidden | Drop `>/dev/null` on `build.sh`; keep npm quiet with `--loglevel=warn` |
| 17 | `template/build.sh:28`, `:86` | Medium | `> "$OUT"` truncates immediately; a mid-build failure leaves a corrupt but plausible `deck.html` | `> "$OUT.tmp" && mv "$OUT.tmp" "$OUT"` |
| 18 | `template/build.sh:53-54` | Low | A literal `</textarea>` in `slides.md` truncates the deck; verified 2 slides → 1, build and `check.js` both report success | Escape it, or assert the slide count in `check.js` |
| 19 | `tools/pdf.js:5`, `README.md:125` | Medium | `require('playwright')` with no `node_modules` at the repo root — documented invocation cannot run | Move to `template/` + `npm run pdf`, or add a root `package.json` |
| 20 | `tools/pdf.js:10-19` | Low | No error handling; browser not closed on failure | `try/finally` |
| 21 | `check.js:22-105` | Low | No `try/finally`; a bad path prints a raw unhandled-rejection stack | Wrap, close the browser, print a one-line message |
| 22 | `check.js:33-34` | Medium | Never compares the slide count to `slides.md`, so silent slide loss (findings 2 and 18) passes | Count `\n---\n` in the source and assert |
| 23 | `check.js:56-59` | Low | `getBBox()` is the geometry box; stroke width is not counted, so a stroked path on the viewBox edge passes and is clipped | Pad the comparison by the max `stroke-width` |
| 24 | `app/Presenter.swift:82-109` | Medium | No `WKNavigationDelegate`: external links navigate the presenter view away from the deck, and load failures are silent | Add the delegate shown above |
| 25 | `app/Presenter.swift:104` | Low | `makeFirstResponder` on every SwiftUI update steals focus back from any other control | Subclass `WKWebView`, override `viewDidMoveToWindow()` |
| 26 | `app/Presenter.swift:99-105` | Low | `updateNSView` ignores `url` changes — latent, currently unreachable via `RootView.body` | Also compare `web.url != url` |
| 27 | `app/build.sh:13-32` | Medium | `Info.plist` has no `NSDocumentsFolderUsageDescription`; a denied TCC prompt is indistinguishable from an empty folder (`app/Presenter.swift:42` → `:141`) | Add the key; distinguish unreadable from empty in the empty state |
| 28 | `app/build.sh:36` | Medium | `-target arm64-apple-macosx13.0` hardcoded — verified Mach-O thin arm64; will not build usefully on Intel | `-target "$(uname -m)-apple-macosx13.0"` |
| 29 | `app/build.sh:77` | Low | `codesign --deep … >/dev/null 2>&1 \|\| true` hides failures; `--deep` is deprecated | Drop `--deep` and the suppression |
| 30 | `app/build.sh:70`, `:72` | Low | `sips` / `iconutil` failures swallowed → silently no icon | Report on failure |
| 31 | `.gitignore:13`, `template/package.json:14` | Medium | No lockfile + `^5.1.0` → rebuilding an old deck is not reproducible (resolved to 5.2.1 today) | Commit `template/package-lock.json`, copy it in `new-deck.sh:20` |
| 32 | `template/` | Low | No `.gitignore` ships with a deck; `git init` in a deck folder commits 176 MB | Add `template/deck.gitignore`, copy as `.gitignore` |
| 33 | `README.md:16-17` | Medium | "an AI can draft one" is unsupported by anything in the repo | Add `docs/CONVENTIONS.md` and point at it |
| 34 | `README.md:33` → `:43` | Low | Install leaves you in `app/`; the next command lives one level up | Add `cd ..` |
| 35 | `README.md:135` | Low | Lists `docs/` as "conventions and notes"; it did not exist | Create it (finding 33) |
| 36 | `README.md:38` | Low | No mention of node/npm, Apple silicon, per-deck disk cost, or how to uninstall | Add four lines |
| 37 | `app/Presenter.swift:33-36` | Low | Library path hardcoded; no way to relocate without recompiling | Read a `UserDefaults` key |
| 38 | `app/build.sh:24-25`, `template/package.json:3` | Low | Two unrelated hardcoded `1.0` versions, neither maintained | One `VERSION` file; tag releases |
| 39 | `app/Presenter.swift:1-8` | Cosmetic | Header comment split mid-sentence by the author/licence lines | Move lines 3-4 to the end of the block |
