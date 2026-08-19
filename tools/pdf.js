#!/usr/bin/env node
// Export a built deck to PDF.
//   node tools/pdf.js path/to/deck.html [out.pdf]
const path = require('path');
const { chromium } = require('playwright');

const deck = path.resolve(process.argv[2] || 'deck.html');
const out  = path.resolve(process.argv[3] || deck.replace(/\.html$/, '.pdf'));

(async () => {
  const b = await chromium.launch();
  const p = await b.newPage();
  await p.goto('file://' + deck + '?print-pdf', { waitUntil: 'networkidle' });
  await p.waitForTimeout(3000);
  await p.pdf({ path: out, width: '1280px', height: '760px',
                printBackground: true, margin: { top: 0, right: 0, bottom: 0, left: 0 } });
  await b.close();
  console.log('wrote ' + out);
})();
