#!/usr/bin/env node
// Turn ```mermaid fences in slides.md into inline SVG, themed to match the deck.
//
// Why pre-render instead of shipping mermaid in the page:
//   - deck.html stays one self-contained file, and stays small (mermaid is ~1 MB)
//   - no runtime JS means nothing to fail on a borrowed laptop or a locked-down VM
//   - check.js can validate the result like any other SVG
//
// Mermaid colours are bound to the deck's CSS custom properties, so a diagram
// follows the theme in both light and dark without being re-rendered.
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

let chromium, mermaidPath;
try {
  ({ chromium } = require('playwright'));
  mermaidPath = require.resolve('mermaid/dist/mermaid.min.js');
} catch {
  console.error('mermaid blocks found but mermaid/playwright are not installed.');
  console.error('Run:  npm install');
  process.exit(1);
}

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  await page.setContent('<!doctype html><body><div id="out"></div></body>');
  await page.addScriptTag({ path: mermaidPath });

  // Bind mermaid's palette to the deck's tokens. currentColor and var() survive
  // in the emitted SVG, so the diagram re-themes with the page.
  await page.evaluate(() => {
    window.mermaid.initialize({
      startOnLoad: false,
      securityLevel: 'strict',
      fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
      themeVariables: {
        background: 'transparent',
        primaryColor: 'transparent',
        primaryTextColor: 'var(--ink)',
        primaryBorderColor: 'var(--ink)',
        secondaryColor: 'transparent',
        tertiaryColor: 'transparent',
        lineColor: 'var(--stroke)',
        textColor: 'var(--ink-soft)',
        mainBkg: 'transparent',
        nodeBorder: 'var(--ink)',
        clusterBkg: 'transparent',
        clusterBorder: 'var(--rule)',
        edgeLabelBackground: 'var(--paper)',
        fontSize: '15px'
      }
    });
  });

  let out = src;
  for (let i = 0; i < blocks.length; i++) {
    const [full, code] = blocks[i];
    const svg = await page.evaluate(async ([def, id]) => {
      const { svg } = await window.mermaid.render(id, def);
      return svg;
    }, [code.trim(), 'm' + i]);

    // strip the fixed max-width mermaid injects so the figure scales with the slide
    const cleaned = svg
      .replace(/style="max-width:[^"]*"/g, '')
      .replace(/<style>[\s\S]*?<\/style>/g, m => m.replace(/#\w+\s*\{[^}]*background[^}]*\}/g, ''))
      .replace(/\n\s*\n/g, '\n');            // blank lines would break the markdown block

    out = out.replace(full, `<div class="fig fig-lg mermaid-fig">\n${cleaned}\n</div>`);
  }

  await browser.close();
  fs.writeFileSync(outFile, out);
  console.log(`rendered ${blocks.length} mermaid diagram(s)`);
})();
