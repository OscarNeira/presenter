#!/usr/bin/env bash
# Build deck.html — ONE self-contained file. No server, no terminal, no npm at runtime.
# Double-click it and it opens in your browser.
#
# It inlines reveal.js, the markdown plugin, all CSS, and slides.md, and uses the
# classic (non-module) reveal build, because browsers refuse to load ES modules
# and fetch() markdown over file:// URLs.
#
# Run this again after editing slides.md.
set -euo pipefail
cd "$(dirname "$0")"

R=node_modules/reveal.js
[ -d "$R" ] || { echo "reveal.js missing. Run:  npm install"; exit 1; }

SRC=slides.md
# ```mermaid fences become inline SVG first, so the deck ships without mermaid
if grep -q '```mermaid' slides.md 2>/dev/null; then
  if [ -d node_modules/mermaid ] && [ -d node_modules/playwright ]; then
    node render-mermaid.js slides.md .slides.rendered.md && SRC=.slides.rendered.md
  else
    echo "note: slides.md has mermaid blocks but mermaid is not installed (npm install)"
  fi
fi

# reveal splits slides on /^\n---\n/, which needs a BLANK line before the ---.
# A single newline silently merges two slides and drops the first one's speaker
# notes into the body of the merged slide. Refuse rather than rewrite: an
# automatic fix cannot tell a separator from a --- inside a fenced code block.
python3 - "$SRC" <<'NORM' || exit 1
import pathlib, re, sys
p = pathlib.Path(sys.argv[1]); lines = p.read_text(encoding='utf-8').split('\n')
fence, bad = False, []
for i, ln in enumerate(lines):
    if ln.lstrip().startswith('```'):
        fence = not fence
        continue
    if fence or ln.strip() != '---':
        continue
    before_ok = i > 0 and lines[i-1].strip() == ''
    after_ok  = i + 1 < len(lines) and lines[i+1].strip() == ''
    if not (before_ok and after_ok):
        bad.append(i + 1)
if bad:
    print(f"{p.name}: slide separators need a blank line before and after.")
    print("  line(s): " + ", ".join(map(str, bad)))
    print("  Without it reveal merges the slides and the speaker notes leak onto the slide.")
    sys.exit(1)
NORM

OUT=deck.html

{
  cat <<'HTML_HEAD'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Deck</title>
<link rel="icon" href="data:,">
<style>
HTML_HEAD

  cat "$R/dist/reset.css"
  cat "$R/dist/reveal.css"
  cat theme.css

  cat <<'HTML_MID'
</style>
</head>
<body>
<div class="reveal"><div class="slides">
<section data-markdown data-separator="^\n---\n" data-separator-notes="^Note:">
<textarea data-template>
HTML_MID

  # slides.md goes inside a <textarea>, so nothing in it is parsed as HTML.
  cat "$SRC"

  cat <<'HTML_TAIL'
</textarea>
</section>
</div></div>
<script>
HTML_TAIL

  cat "$R/dist/reveal.js"
  cat "$R/plugin/markdown/markdown.js"

  cat <<'HTML_END'
</script>
<script>
// Speaker view lives in this same file: pressing S opens it as ?notes=1.
// The stock notes plugin fetches a separate speaker-view.html over HTTP, which
// a one-file file:// deck cannot do, so this reads the opener's Reveal directly.
if (/[?&]notes=1/.test(location.search)) { speakerView(); } else {
Reveal.initialize({
  plugins: [ RevealMarkdown ],
  hash: true,
  slideNumber: 'c/t',
  controls: true,
  progress: true,
  center: true,
  transition: 'fade',
  transitionSpeed: 'fast',
  backgroundTransition: 'none',
  width: 1280, height: 760, margin: 0.06,
  minScale: 0.2, maxScale: 1.6
});

var speakerWin = null;

document.addEventListener('keydown', function (e) {
  if (e.key !== 's' && e.key !== 'S') return;
  if (e.metaKey || e.ctrlKey || e.altKey) return;
  var t = e.target;
  if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.isContentEditable)) return;
  e.preventDefault();
  speakerWin = window.open(location.href.split('?')[0].split('#')[0] + '?notes=1',
                           'speaker', 'width=1000,height=760');
});

// file:// documents have a null origin, so the speaker window cannot read this
// one directly. Push the state to it instead.
function speakerPayload() {
  var all = document.querySelectorAll('.reveal .slides > section');
  return {
    type: 'deck',
    index: Reveal.getIndices().h,
    slides: Array.prototype.map.call(all, function (s) {
      var h = s.querySelector('h1,h2,h3');
      var n = s.querySelector('aside.notes');
      return { title: h ? h.innerText.replace(/\s+/g, ' ') : '(figure)',
               notes: n ? n.innerText.trim() : '' };
    })
  };
}
window.addEventListener('message', function (e) {
  if (e.data === 'speaker-ready' && e.source) e.source.postMessage(speakerPayload(), '*');
});
Reveal.on('slidechanged', function () {
  if (speakerWin && !speakerWin.closed) {
    speakerWin.postMessage({ type: 'index', index: Reveal.getIndices().h }, '*');
  }
});
}

function speakerView() {
  var start = Date.now(), slides = [], idx = 0;
  document.documentElement.innerHTML =
    '<head><meta charset="utf-8"><title>Speaker view</title></head><body></body>';
  var s = document.createElement('style');
  s.textContent =
    'body{margin:0;font:15px/1.55 ui-monospace,SFMono-Regular,Menlo,monospace;' +
    'background:#12151c;color:#e8ecf3;display:grid;grid-template-rows:auto 1fr auto;height:100vh}' +
    'header{display:flex;gap:18px;align-items:baseline;padding:14px 20px;' +
    'border-bottom:1px solid #2a3040;background:#0c0f15}' +
    '#pos{font-size:22px;font-weight:700}' +
    '#clock{margin-left:auto;font-size:22px;font-variant-numeric:tabular-nums}' +
    '#cur{font-size:13px;color:#8b95a8;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}' +
    'main{padding:22px 26px;overflow:auto;font-size:18px;line-height:1.62;white-space:pre-wrap}' +
    'main:empty::before{content:"No notes on this slide.";color:#5c6478}' +
    'footer{padding:12px 20px;border-top:1px solid #2a3040;background:#0c0f15;color:#8b95a8}' +
    'b{color:#fff}';
  document.head.appendChild(s);
  document.body.innerHTML =
    '<header><span id="pos">--</span><span id="cur">connecting…</span><span id="clock">00:00</span></header>' +
    '<main id="notes"></main><footer id="next"></footer>';

  setInterval(function () {
    var e = Math.floor((Date.now() - start) / 1000);
    document.getElementById('clock').textContent =
      String(Math.floor(e / 60)).padStart(2, '0') + ':' + String(e % 60).padStart(2, '0');
  }, 1000);

  function paint() {
    if (!slides.length) return;
    var cur = slides[idx] || {}, nxt = slides[idx + 1];
    document.getElementById('pos').textContent = (idx + 1) + ' / ' + slides.length;
    document.getElementById('cur').textContent = cur.title || '';
    document.getElementById('notes').innerText = cur.notes || '';
    document.getElementById('next').innerHTML =
      nxt ? 'Next: <b>' + nxt.title + '</b>' : '<b>Last slide.</b>';
  }

  window.addEventListener('message', function (e) {
    var d = e.data;
    if (!d || !d.type) return;
    if (d.type === 'deck') { slides = d.slides; idx = d.index; paint(); }
    if (d.type === 'index') { idx = d.index; paint(); }
  });

  function hello() { if (window.opener && !window.opener.closed) window.opener.postMessage('speaker-ready', '*'); }
  hello();
  var tries = setInterval(function () { if (slides.length) clearInterval(tries); else hello(); }, 400);
}
</script>
</body>
</html>
HTML_END
} > "$OUT"

rm -f .slides.rendered.md
SIZE=$(du -h "$OUT" | cut -f1)
echo "Built ${OUT} (${SIZE})"
echo
echo "Open it by double-clicking:"
echo "  $(pwd)/${OUT}"
echo
echo "Re-run ./build.sh after you edit slides.md."
