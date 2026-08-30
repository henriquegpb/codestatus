'use strict';

// Gera os icones da bandeja em PNG para inspecao visual. Nao faz parte da suite:
// existe para conferir com o olho o que o usuario vai ver no canto da tela.

const { app } = require('electron');
const fs = require('fs');
const path = require('path');
const { buildIcon } = require('../src/ui/icon');

app.whenReady().then(() => {
  const cases = [
    ['1-vazio', { free: 0, busy: 0, needsYou: 0, indeterminate: 0 }],
    ['2-livre', { free: 2, busy: 0, needsYou: 0, indeterminate: 0 }],
    ['3-trabalhando', { free: 1, busy: 3, needsYou: 0, indeterminate: 0 }],
    ['4-precisa-de-voce', { free: 0, busy: 2, needsYou: 1, indeterminate: 0 }],
    ['5-muitos', { free: 0, busy: 0, needsYou: 12, indeterminate: 0 }],
  ];
  const out = path.join(__dirname, 'icons');
  fs.mkdirSync(out, { recursive: true });
  for (const [name, counts] of cases) {
    fs.writeFileSync(path.join(out, `${name}.png`), buildIcon(counts).toPNG());
  }
  console.log(`icones gerados em ${out}`);
  app.quit();
});
