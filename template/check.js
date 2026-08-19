#!/usr/bin/env node
// Check a built deck before you stand up in front of people.
//
// Catches the two failures that do not show up in source review and that a
// human will not notice until the projector is on:
//
//   1. A slide whose content overflows the frame (clipped headline or kicker).
//   2. An SVG whose drawn content falls outside its own viewBox, which the
//      browser silently crops. An arc apex above y=0 is the classic one.
//
// Also reports console errors and any horizontal page scroll.
//
//   node check.js            # checks ./deck.html
//   node check.js other.html

const path = require('path');
const { chromium } = require('playwright');

const file = path.resolve(process.argv[2] || 'deck.html');
const url = 'file://' + file;

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });

  const errors = [];
  page.on('pageerror', e => errors.push('pageerror: ' + e.message));
  page.on('console', m => { if (m.type() === 'error') errors.push('console: ' + m.text()); });

  await page.goto(url);
  await page.waitForTimeout(2000);

  const total = await page.evaluate(
    () => document.querySelectorAll('.reveal .slides > section').length);

  if (!total) {
    console.error('No slides found. Did you run ./build.sh?');
    process.exit(1);
  }

  const clipped = [];
  const outside = [];
  const wide = [];

  for (let i = 0; i < total; i++) {
    await page.goto(url + '#/' + i);
    await page.waitForTimeout(450);

    const r = await page.evaluate(() => {
      const s = document.querySelector('.reveal .slides section.present');
      const box = s.getBoundingClientRect();
      const svgs = [];
      s.querySelectorAll('svg').forEach(svg => {
        const vb = svg.viewBox.baseVal;
        if (!vb || !vb.width) return;
        const bb = svg.getBBox();
        if (bb.x < vb.x - 1 || bb.y < vb.y - 1 ||
            bb.x + bb.width  > vb.x + vb.width  + 1 ||
            bb.y + bb.height > vb.y + vb.height + 1) {
          svgs.push({
            viewBox: [vb.x, vb.y, vb.width, vb.height].map(Math.round).join(' '),
            content: [bb.x, bb.y, bb.width, bb.height].map(Math.round).join(' ')
          });
        }
      });
      const heading = s.querySelector('h1,h2,h3');
      return {
        clipped: box.top < -1 || box.bottom > window.innerHeight + 2,
        svgs,
        hScroll: document.documentElement.scrollWidth > window.innerWidth + 1,
        label: heading ? heading.innerText.replace(/\s+/g, ' ').slice(0, 44) : '(figure)'
      };
    });

    if (r.clipped) clipped.push(`${i + 1}  ${r.label}`);
    if (r.hScroll) wide.push(`${i + 1}  ${r.label}`);
    for (const s of r.svgs) {
      outside.push(`${i + 1}  ${r.label}\n      viewBox ${s.viewBox}  content ${s.content}`);
    }
  }

  await browser.close();

  const report = (title, list, hint) => {
    if (!list.length) return 0;
    console.log(`\n${title}`);
    list.forEach(l => console.log('   ' + l));
    if (hint) console.log('   → ' + hint);
    return list.length;
  };

  let bad = 0;
  bad += report('SLIDES CLIPPED BY THE FRAME', clipped,
    'add `dense` to the slide, or cut words');
  bad += report('SVG CONTENT OUTSIDE ITS VIEWBOX', outside,
    'widen the viewBox; content outside it is silently cropped');
  bad += report('HORIZONTAL SCROLL', wide,
    'wrap wide content in a container with overflow-x: auto');
  bad += report('CONSOLE ERRORS', errors);

  if (!bad) console.log(`\n${total} slides. All fit, every SVG inside its viewBox, no errors.`);
  else console.log(`\n${bad} problem(s) across ${total} slides.`);

  process.exit(bad ? 1 : 0);
})();
