<p class="eyebrow">Team · 1 January 2026</p>

# Deck title goes here

One line under it. Say what this is, not what it covers.

<p class="note">Who is in the room</p>

Note:
Speaker notes go after `Note:` and are only visible in the presenter view (press S).
Keep the slide short; put the words you will actually say down here.

---

<p class="eyebrow">Ground rule · before anything else</p>

## One idea per slide. Say the rest out loud.

Text on a slide competes with you. It always wins, and then nobody hears the point.

<p class="kicker">The kicker is the one line worth saying out loud. Use it sparingly.</p>

---

<!-- .slide: class="visual" -->

<div class="fig fig-lg">
<svg viewBox="0 0 900 300" role="img" aria-label="Describe the drawing here for anyone who cannot see it">
  <rect x="60" y="70" width="220" height="120" fill="none" stroke="var(--ink)" stroke-width="3"/>
  <rect x="620" y="70" width="220" height="120" fill="var(--accent)"/>
  <path d="M290 130 L610 130" stroke="var(--stroke)" stroke-width="2"/>
  <g font-family="ui-monospace, monospace" font-size="15" letter-spacing="1.5" fill="var(--steel)">
  <text x="60" y="228">WHAT WE HAVE</text>
  <text x="620" y="228">WHAT THEY SEE</text>
  </g>
</svg>
</div>

<p class="kicker">A drawing that carries the idea beats a bullet list describing it.</p>

Note:
Inline SVG only, so the deck stays one file and works offline.

TWO RULES, both learned the hard way:
1. No blank lines inside the <svg> block. Markdown exits HTML mode and renders the rest
   as a code block.
2. Keep every drawn coordinate inside the viewBox. An arc or a label that falls outside
   is silently clipped. `npm run check` catches both.

---

<p class="eyebrow">The quoted voice</p>

> "A sentence from a brief, a PRD, or somebody senior."

Blockquote renders as serif italic. That is the aspirational voice.

Inline `code` renders in mono, which is the working voice. The typeface change carries the
argument, so you do not have to explain it.

---

<!-- .slide: class="dense map" -->

<p class="eyebrow">A table where the first column is the subject</p>

### Three things

| Thing | Ref | Owner |
|---|---|---|
| First item | 1234 | Team A |
| Second item | 5678 | Team B |
| Third item | 9012 | Team C |

<p class="kicker">Add <code>map</code> to a slide when column one is the subject rather than an index. Add <code>dense</code> when a slide would otherwise overflow.</p>

---

<p class="eyebrow">Before we leave</p>

### Three things

1. The first action, with a date
2. The second action, with an owner
3. The third action, <span class="accent">with something concrete</span>

<p class="kicker">End on what people should do, not on a summary of what you said.</p>

Note:
A deck that ends on a slogan gets nodded at. A deck that ends on three actions with names
against them gets done.
