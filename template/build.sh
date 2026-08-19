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
