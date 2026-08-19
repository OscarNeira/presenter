#!/usr/bin/env bash
# Scaffold a new deck from the template into ~/Documents/presentations,
# where Presenter.app will pick it up.
#
#   ./new-deck.sh "Q3 planning"
#   ./new-deck.sh "Q3 planning" ~/somewhere/else
set -euo pipefail
cd "$(dirname "$0")"

TITLE="${1:-}"
[ -n "$TITLE" ] || { echo "usage: ./new-deck.sh \"Deck title\" [parent-dir]"; exit 1; }

PARENT="${2:-$HOME/Documents/presentations}"
SLUG=$(echo "$TITLE" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
DIR="$PARENT/$(date +%Y-%m-%d)-$SLUG"

[ -e "$DIR" ] && { echo "$DIR already exists"; exit 1; }

mkdir -p "$DIR"
cp template/{slides.md,theme.css,build.sh,check.js,render-mermaid.js,package.json} "$DIR/"
chmod +x "$DIR/build.sh"

# put the real title into the deck and the page
python3 - "$DIR" "$TITLE" <<'PY'
import pathlib, sys
d, title = pathlib.Path(sys.argv[1]), sys.argv[2]
s = d / 'slides.md'
s.write_text(s.read_text(encoding='utf-8').replace('# Deck title goes here', f'# {title}'), encoding='utf-8')
b = d / 'build.sh'
b.write_text(b.read_text(encoding='utf-8').replace('<title>Deck</title>', f'<title>{title}</title>'), encoding='utf-8')
PY

cd "$DIR"
echo "installing reveal.js…"
npm install --no-audit --no-fund >/dev/null 2>&1 || { echo "npm install failed — run it yourself in $DIR"; exit 1; }
./build.sh >/dev/null

echo
echo "Created  $DIR"
echo "Edit     $DIR/slides.md"
echo "Rebuild  cd '$DIR' && ./build.sh"
echo "Check    npm run check"
echo
echo "It is now in Presenter.app — press ⌘R there to see it."
