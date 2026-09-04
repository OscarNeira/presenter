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

# Build metadata, shown on Presenter's main list page so "what version made
# this, when, and by what" is answerable without opening the file. Bump
# BUILD_SCRIPT_VERSION whenever this script's HTML/behaviour changes.
BUILD_SCRIPT_VERSION="1.2"
GEN_TIME=$(date '+%Y-%m-%dT%H:%M:%S%z')
GEN_HOST=$(hostname -s)
# Callers that know who/what is building (e.g. build-standup-deck.py, or an
# agent editing slides.md by hand) should export GEN_WHO before calling this.
GEN_WHO="${GEN_WHO:-build.sh, invoked directly}"

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

# A section must hold exactly ONE "Note:" block. Reveal's notes separator is
# ^Note: and it splits on the FIRST match, so a second block stays in the slide
# BODY — speaker notes projected onto the screen, which is the single most
# embarrassing way for this deck to fail and is invisible in source review.
#
# It happens when a new slide is inserted between a slide's content and its
# note, which is exactly what an editor adding a slide "after the table" does.
# Caught on 2026-08-26 only by screenshotting the built deck; a check is cheaper
# than remembering.
secs, fence = [[]], False
for ln in lines:
    if ln.lstrip().startswith('```'):
        fence = not fence
    if not fence and ln.strip() == '---':
        secs.append([]); continue
    secs[-1].append(ln)
problems = []
for i, s in enumerate(secs, 1):
    n = sum(1 for l in s if l.startswith('Note:'))
    if n > 1:
        head = next((l for l in s if l.startswith('#')), '(figure)')[:50]
        problems.append(f"  slide {i}: {n} 'Note:' blocks — {head}")
if problems:
    print(f"{p.name}: a slide has more than one speaker-note block.")
    print("\n".join(problems))
    print("  Reveal splits on the FIRST 'Note:', so the rest is rendered ON the slide.")
    print("  Usually means a new slide was inserted before the previous slide's note.")
    sys.exit(1)
NORM

OUT=deck.html

{
  cat <<HTML_HEAD
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Deck</title>
<meta name="generator" content="presenter build.sh v${BUILD_SCRIPT_VERSION} · built ${GEN_TIME} on ${GEN_HOST} · by ${GEN_WHO}">
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

// This one is ours, not reveal's, so it has to be added to the ? help overlay
// by hand or nobody ever discovers it.
if (Reveal.registerKeyboardShortcut) {
  Reveal.registerKeyboardShortcut('S', 'Speaker view — notes, timers, and a remote');
}

var speakerWin = null;

document.addEventListener('keydown', function (e) {
  if (e.key !== 's' && e.key !== 'S') return;
  if (e.metaKey || e.ctrlKey || e.altKey) return;
  var t = e.target;
  if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.isContentEditable)) return;
  e.preventDefault();
  speakerWin = window.open(location.href.split('?')[0].split('#')[0] + '?notes=1',
                           'speaker', 'width=1060,height=800');
});

// file:// documents have a null origin, so the speaker window cannot read this
// one directly. Push the state to it instead.
function slideSummary(s) {
  var c = s.cloneNode(true);
  var aside = c.querySelector('aside.notes');
  if (aside && aside.parentNode) aside.parentNode.removeChild(aside);
  var t = (c.innerText || '').replace(/\s+/g, ' ').trim();
  return t.length > 320 ? t.slice(0, 320) + '…' : t;
}
function speakerPayload() {
  var all = document.querySelectorAll('.reveal .slides > section');
  return {
    type: 'deck',
    index: Reveal.getIndices().h,
    deckTitle: document.title,
    slides: Array.prototype.map.call(all, function (s) {
      var h = s.querySelector('h1,h2,h3');
      var n = s.querySelector('aside.notes');
      return { title: h ? h.innerText.replace(/\s+/g, ' ') : '(figure)',
               notes: n ? n.innerText.trim() : '',
               text: slideSummary(s) };
    })
  };
}
// The speaker window is also a remote: everything it can do to the deck goes
// through here, so the presenter never has to reach for the other screen.
window.addEventListener('message', function (e) {
  var d = e.data;
  if (d === 'speaker-ready' && e.source) {
    speakerWin = e.source;
    e.source.postMessage(speakerPayload(), '*');
    return;
  }
  if (!d || !d.type) return;
  if (d.type === 'nav')           { d.dir === 'prev' ? Reveal.prev() : Reveal.next(); }
  else if (d.type === 'goto')     { Reveal.slide(d.index, 0); }
  else if (d.type === 'pause')    { Reveal.togglePause(); }
  else if (d.type === 'overview') { Reveal.toggleOverview(); }
  else if (d.type === 'sync' && e.source) { e.source.postMessage(speakerPayload(), '*'); }
});
Reveal.on('slidechanged', function () {
  if (speakerWin && !speakerWin.closed) {
    speakerWin.postMessage({ type: 'index', index: Reveal.getIndices().h }, '*');
  }
});
window.addEventListener('beforeunload', function () {
  if (speakerWin && !speakerWin.closed) speakerWin.close();
});
}

function speakerView() {
  var slides = [], idx = 0, deckTitle = '';
  var runStart = Date.now(), runPaused = false, runAccum = 0;   // whole-talk clock
  var slideStart = Date.now();                                  // this slide only
  var listOpen = false;

  document.documentElement.innerHTML =
    '<head><meta charset="utf-8"><title>Speaker view</title></head><body></body>';
  var s = document.createElement('style');
  s.textContent =
    'body{margin:0;font:15px/1.55 ui-monospace,SFMono-Regular,Menlo,monospace;' +
    'background:#12151c;color:#e8ecf3;display:grid;grid-template-rows:auto 1fr auto auto;height:100vh}' +
    'header{display:flex;gap:16px;align-items:baseline;padding:13px 20px;' +
    'border-bottom:1px solid #2a3040;background:#0c0f15}' +
    '#pos{font-size:22px;font-weight:700}' +
    '#cur{font-size:13px;color:#8b95a8;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;flex:1}' +
    '.clk{font-size:20px;font-variant-numeric:tabular-nums}' +
    '.clk small{display:block;font-size:9px;letter-spacing:.12em;color:#5c6478;text-align:right}' +
    '#slideclk{color:#9fb4d8}#runclk.paused{color:#dfae4a}' +
    'main{padding:22px 26px;overflow:auto;font-size:19px;line-height:1.62;white-space:pre-wrap}' +
    'main:empty::before{content:"No notes on this slide.";color:#5c6478}' +
    'footer{padding:11px 20px;border-top:1px solid #2a3040;background:#0c0f15;color:#8b95a8;' +
    'display:flex;gap:14px;align-items:center}' +
    '#next{flex:1;overflow:hidden}' +
    '#nexttext{display:block;color:#5c6478;font-size:11px;margin-top:3px;' +
    'overflow:hidden;text-overflow:ellipsis;white-space:nowrap}' +
    'button{font:inherit;font-size:12px;background:#1b2130;color:#c8d2e4;border:1px solid #2a3040;' +
    'border-radius:5px;padding:5px 10px;cursor:pointer}' +
    'button:hover{background:#242c3e;color:#fff}' +
    '#bar{height:3px;background:#1b2130}#bar>i{display:block;height:3px;background:#6E9BFF;width:0;' +
    'transition:width .18s}' +
    '#list{position:fixed;inset:0;background:#0c0f15f2;padding:26px;overflow:auto;display:none}' +
    '#list.on{display:block}' +
    '#list h2{margin:0 0 14px;font-size:13px;letter-spacing:.12em;color:#8b95a8;text-transform:uppercase}' +
    '#list ol{margin:0;padding:0;list-style:none}' +
    '#list li{padding:8px 10px;border-radius:5px;cursor:pointer;display:flex;gap:12px}' +
    '#list li:hover{background:#1b2130}#list li.now{background:#1d2a44;color:#fff}' +
    '#list li span{color:#5c6478;min-width:2.4em;text-align:right}' +
    'b{color:#fff}kbd{font:inherit;font-size:11px;color:#5c6478}';
  document.head.appendChild(s);
  document.body.innerHTML =
    '<header><span id="pos">--</span><span id="cur">connecting…</span>' +
    '<span class="clk" id="slideclk">00:00<small>SLIDE</small></span>' +
    '<span class="clk" id="runclk">00:00<small>TALK</small></span>' +
    '<span class="clk" id="wall">--:--<small>NOW</small></span></header>' +
    '<main id="notes"></main>' +
    '<footer><button id="prev">◀</button><button id="next-btn">▶</button>' +
    '<button id="pause">Pause timer</button><button id="reset">Reset</button>' +
    '<button id="all">All slides</button>' +
    '<span id="next"></span><kbd>← → space · B black · O overview</kbd></footer>' +
    '<div id="bar"><i></i></div>' +
    '<div id="list"><h2>All slides — click to jump</h2><ol></ol></div>';

  function mmss(ms) {
    var e = Math.max(0, Math.floor(ms / 1000));
    return String(Math.floor(e / 60)).padStart(2, '0') + ':' + String(e % 60).padStart(2, '0');
  }
  function tick() {
    var run = runAccum + (runPaused ? 0 : Date.now() - runStart);
    document.getElementById('runclk').firstChild.nodeValue = mmss(run);
    document.getElementById('slideclk').firstChild.nodeValue = mmss(Date.now() - slideStart);
    var d = new Date();
    document.getElementById('wall').firstChild.nodeValue =
      String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0');
  }
  tick();
  setInterval(tick, 500);

  function send(m) { if (window.opener && !window.opener.closed) window.opener.postMessage(m, '*'); }

  function paint() {
    if (!slides.length) return;
    var cur = slides[idx] || {}, nxt = slides[idx + 1];
    document.title = 'Speaker view — ' + (deckTitle || '');
    document.getElementById('pos').textContent = (idx + 1) + ' / ' + slides.length;
    document.getElementById('cur').textContent = cur.title || '';
    document.getElementById('notes').innerText = cur.notes || '';
    document.getElementById('next').innerHTML = nxt
      ? 'Next: <b></b><span id="nexttext"></span>'
      : '<b>Last slide.</b>';
    if (nxt) {
      document.querySelector('#next b').textContent = nxt.title || '';
      document.getElementById('nexttext').textContent = nxt.text || '';
    }
    document.querySelector('#bar > i').style.width =
      (slides.length > 1 ? (idx / (slides.length - 1)) * 100 : 100) + '%';
    var here = document.querySelector('#list li.now');
    if (here) here.classList.remove('now');
    var next = document.querySelector('#list li[data-i="' + idx + '"]');
    if (next) { next.classList.add('now'); next.scrollIntoView({ block: 'nearest' }); }
  }

  function buildList() {
    var ol = document.querySelector('#list ol');
    ol.innerHTML = '';
    slides.forEach(function (sl, i) {
      var li = document.createElement('li');
      li.dataset.i = i;
      li.innerHTML = '<span>' + (i + 1) + '</span>';
      li.appendChild(document.createTextNode(sl.title || '(figure)'));
      li.onclick = function () { send({ type: 'goto', index: i }); toggleList(false); };
      ol.appendChild(li);
    });
  }
  function toggleList(on) {
    listOpen = on === undefined ? !listOpen : on;
    document.getElementById('list').classList.toggle('on', listOpen);
    if (listOpen) paint();
  }

  document.getElementById('prev').onclick = function () { send({ type: 'nav', dir: 'prev' }); };
  document.getElementById('next-btn').onclick = function () { send({ type: 'nav', dir: 'next' }); };
  document.getElementById('all').onclick = function () { toggleList(); };
  document.getElementById('reset').onclick = function () {
    runStart = Date.now(); runAccum = 0; slideStart = Date.now();
  };
  document.getElementById('pause').onclick = function () {
    if (runPaused) { runStart = Date.now(); runPaused = false; this.textContent = 'Pause timer'; }
    else { runAccum += Date.now() - runStart; runPaused = true; this.textContent = 'Resume timer'; }
    document.getElementById('runclk').classList.toggle('paused', runPaused);
  };

  // The speaker window is where the presenter's hands are, so it drives the deck.
  document.addEventListener('keydown', function (e) {
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    var k = e.key;
    if (k === 'Escape' && listOpen) { toggleList(false); e.preventDefault(); return; }
    if (k === 'ArrowRight' || k === 'ArrowDown' || k === 'PageDown' || k === ' ' || k === 'n' || k === 'N') {
      send({ type: 'nav', dir: 'next' }); e.preventDefault();
    } else if (k === 'ArrowLeft' || k === 'ArrowUp' || k === 'PageUp' || k === 'p' || k === 'P') {
      send({ type: 'nav', dir: 'prev' }); e.preventDefault();
    } else if (k === 'b' || k === 'B' || k === '.') {
      send({ type: 'pause' }); e.preventDefault();
    } else if (k === 'o' || k === 'O') {
      toggleList(); e.preventDefault();
    } else if (k === 't' || k === 'T') {
      document.getElementById('pause').click(); e.preventDefault();
    }
  });

  window.addEventListener('message', function (e) {
    var d = e.data;
    if (!d || !d.type) return;
    if (d.type === 'deck') {
      slides = d.slides; idx = d.index; deckTitle = d.deckTitle || '';
      buildList(); slideStart = Date.now(); paint();
    }
    if (d.type === 'index') {
      if (d.index !== idx) slideStart = Date.now();
      idx = d.index; paint();
    }
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
