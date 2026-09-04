#!/usr/bin/env bash
# Push template/build.sh out to every deck in ~/Documents/presentations and
# rebuild them.
#
# A deck's build.sh is the template with one line changed — its <title> — so
# propagating is: copy the template, put that deck's title back, rebuild, and
# show what moved in the built file. slides.md is never read, never written.
#
#   ./tools/propagate-template.sh --dry-run     # say what would happen
#   ./tools/propagate-template.sh               # do it
#
# Every deck.html is copied to deck.html.bak first. If a rebuild goes wrong,
# `mv deck.html.bak deck.html` puts it back exactly as it was.
set -euo pipefail
cd "$(dirname "$0")/.."

TEMPLATE="$PWD/template/build.sh"
ROOT="${PRESENTATIONS:-$HOME/Documents/presentations}"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

[ -f "$TEMPLATE" ] || { echo "no template at $TEMPLATE"; exit 1; }
VER=$(grep -o 'BUILD_SCRIPT_VERSION="[^"]*"' "$TEMPLATE" | head -1 | cut -d'"' -f2)
echo "template build.sh v${VER}"
echo "library: $ROOT"
echo

changed=0 skipped=0 failed=0

for deck in "$ROOT"/*/; do
  name=$(basename "$deck")
  # A deck is a folder with slides.md AND build.sh. Anything else in here —
  # the app's own source folder, for instance — is not a deck.
  [ -f "$deck/slides.md" ] && [ -f "$deck/build.sh" ] || { skipped=$((skipped+1)); continue; }

  title=$(grep -o '<title>.*</title>' "$deck/build.sh" | head -1 || true)
  [ -n "$title" ] || { echo "!! $name: no <title> in build.sh, skipping"; skipped=$((skipped+1)); continue; }

  have=$(grep -o 'BUILD_SCRIPT_VERSION="[^"]*"' "$deck/build.sh" | head -1 | cut -d'"' -f2 || echo "?")
  if [ "$DRY" = "1" ]; then
    echo "would update $name (v${have} -> v${VER}, keeping ${title})"
    continue
  fi

  python3 - "$TEMPLATE" "$deck/build.sh" "$title" <<'PY'
import pathlib, sys
tpl, dest, title = sys.argv[1], pathlib.Path(sys.argv[2]), sys.argv[3]
dest.write_text(pathlib.Path(tpl).read_text().replace('<title>Deck</title>', title))
PY
  chmod +x "$deck/build.sh"

  [ -f "$deck/deck.html" ] && cp "$deck/deck.html" "$deck/deck.html.bak"

  if GEN_WHO="template v${VER} rollout, tools/propagate-template.sh" \
     bash -c "cd '$deck' && ./build.sh" >/dev/null 2>"$deck/.build.err"; then
    if [ -f "$deck/deck.html.bak" ]; then
      # every line that moved, ignoring the build stamp that always moves
      n=$(diff "$deck/deck.html.bak" "$deck/deck.html" \
          | grep -E '^[<>]' | grep -vc 'name="generator"' || true)
      echo "ok  $name  (v${have} -> v${VER}, ${n} changed lines besides the build stamp)"
    else
      echo "ok  $name  (built fresh)"
    fi
    changed=$((changed+1))
    rm -f "$deck/.build.err"
  else
    echo "!!  $name FAILED:"; sed 's/^/      /' "$deck/.build.err"
    [ -f "$deck/deck.html.bak" ] && mv "$deck/deck.html.bak" "$deck/deck.html" && echo "      rolled back deck.html"
    failed=$((failed+1))
  fi
done

echo
echo "rebuilt ${changed}, skipped ${skipped}, failed ${failed}"
[ "$DRY" = "1" ] || echo "backups left as deck.html.bak — delete them with:
  find '$ROOT' -maxdepth 2 -name deck.html.bak -delete"
