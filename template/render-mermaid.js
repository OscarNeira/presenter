#!/usr/bin/env node
// Turn ```mermaid fences in slides.md into inline SVG, themed to match the deck.
//
// Why pre-render instead of shipping mermaid in the page:
//   - deck.html stays one self-contained file, and stays small (mermaid is ~1 MB)
//   - no runtime JS means nothing to fail on a borrowed laptop or a locked-down VM
//   - check.js can validate the result like any other SVG
//
// Mermaid cannot take `var(--token)` as a colour: it derives shades internally and
// needs something it can parse. So we render with sentinel hex values and swap them
// for the deck's CSS variables afterwards. The emitted SVG then follows the theme in
// both light and dark without being re-rendered.
//
//   node render-mermaid.js            # slides.md -> .slides.rendered.md
//   node render-mermaid.js in.md out.md

const fs = require('fs');
const path = require('path');

const inFile  = path.resolve(process.argv[2] || 'slides.md');
const outFile = path.resolve(process.argv[3] || '.slides.rendered.md');

const src = fs.readFileSync(inFile, 'utf8');
const FENCE = /```mermaid\s*\n([\s\S]*?)```/g;
const blocks = [...src.matchAll(FENCE)];

if (!blocks.length) {
  fs.writeFileSync(outFile, src);
  process.exit(0);
}

// sentinel hex -> theme token. Values are arbitrary but must be unique.
const TOKENS = {
  '#0b1220': 'var(--ink)',
  '#334155': 'var(--ink-soft)',
  '#94a3b8': 'var(--stroke)',
  '#e2e8f0': 'var(--rule)',
  '#fffffe': 'var(--paper)',      // not pure white, so we do not catch stray #fff
  '#2b5fd9': 'var(--accent)'
};

let chromium, mermaidPath;
try {
  ({ chromium } = require('playwright'));
  mermaidPath = require.resolve('mermaid/dist/mermaid.min.js');
} catch {
  console.error('slides.md contains mermaid blocks but mermaid/playwright are not installed.');
  console.error('Run:  npm install');
  process.exit(1);
}

(async () => {
  const browser = await chromium.launch();
  try {
    const page = await browser.newPage();
    await page.setContent('<!doctype html><body><div id="out"></div></body>');
    await page.addScriptTag({ path: mermaidPath });

    await page.evaluate(() => {
      window.mermaid.initialize({
        startOnLoad: false,
        securityLevel: 'strict',
        htmlLabels: false,            // real SVG <text>, so it scales and prints
        flowchart: { htmlLabels: false, curve: 'basis', padding: 14 },
        fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
        themeVariables: {
          background:        '#fffffe',
          primaryColor:      '#fffffe',
          secondaryColor:    '#fffffe',
          tertiaryColor:     '#fffffe',
          mainBkg:           '#fffffe',
          clusterBkg:        '#fffffe',
          edgeLabelBackground:'#fffffe',
          primaryTextColor:  '#0b1220',
          textColor:         '#334155',
          nodeTextColor:     '#0b1220',
          primaryBorderColor:'#0b1220',
          nodeBorder:        '#0b1220',
          clusterBorder:     '#e2e8f0',
          lineColor:         '#94a3b8',
          fontSize:          '15px'
        }
      });
    });

    let out = src;
    for (let i = 0; i < blocks.length; i++) {
      const [full, code] = blocks[i];
      let svg;
      try {
        svg = await page.evaluate(async ([def, id]) => {
          const { svg } = await window.mermaid.render(id, def);
          return svg;
        }, [code.trim(), 'mmd' + i]);
      } catch (e) {
        console.error(`\nmermaid block ${i + 1} failed to render:\n${code.trim()}\n\n${e.message}\n`);
        process.exitCode = 1;
        continue;
      }

      // sentinels -> theme tokens
      for (const [hex, token] of Object.entries(TOKENS)) {
        svg = svg.replace(new RegExp(hex, 'gi'), token);
      }

      const cleaned = svg
        .replace(/style="max-width:[^"]*"/g, '')   // let it scale with the slide
        .replace(/\n\s*\n/g, '\n');                // blank lines break the markdown block

      out = out.replace(full, `<div class="fig fig-lg">\n${cleaned}\n</div>`);
    }

    fs.writeFileSync(outFile, out);
    console.log(`rendered ${blocks.length} mermaid diagram(s)`);
  } finally {
    await browser.close();
  }
})().catch(e => {
  console.error('mermaid render failed:', e.message);
  process.exit(1);
});
