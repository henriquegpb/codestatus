'use strict';

// Renderiza o painel e o icone da bandeja com o estado REAL que o app esta
// acompanhando agora, lido do snapshot que o daemon persiste. Serve para olhar
// o que o app esta vendo sem precisar clicar no icone.

const { app, BrowserWindow, ipcMain } = require('electron');
const path = require('path');
const fs = require('fs');

const { paths } = require('../src/core/paths');
const { displayName } = require('../src/core/session');
const { LABELS_PT, bucketOf, isActive } = require('../src/core/state');
const { buildIcon, buildTooltip } = require('../src/ui/icon');

function lerEstadoVivo() {
  const snap = JSON.parse(fs.readFileSync(paths.sessionsSnapshot, 'utf8'));
  const vivas = snap.sessions.filter((s) => isActive(s.state) && s.hasHookEvidence);

  const counts = {
    free: 0, busy: 0, needsYou: 0, indeterminate: 0,
  };
  for (const s of vivas) {
    const b = bucketOf(s.state);
    if (b !== 'gone') counts[b] += 1;
  }

  return {
    counts,
    unreported: snap.sessions.filter((s) => isActive(s.state) && !s.hasHookEvidence).length,
    installed: true,
    sessions: vivas
      .sort((a, b) => b.stateChangedAt - a.stateChangedAt)
      .map((s) => ({
        id: s.id,
        name: displayName(s),
        state: s.state,
        label: LABELS_PT[s.state] || s.state,
        cwd: s.cwd,
        model: s.model,
        since: s.stateChangedAt,
      })),
  };
}

app.whenReady().then(async () => {
  const estado = lerEstadoVivo();
  const out = path.join(__dirname, 'icons');
  fs.mkdirSync(out, { recursive: true });

  console.log('estado real que o app esta acompanhando:');
  console.log(`  contagens: ${JSON.stringify(estado.counts)}`);
  for (const s of estado.sessions) {
    console.log(`  - ${s.name} | ${s.label} | ${s.cwd}`);
  }
  console.log(`  tooltip: ${buildTooltip(estado.counts, estado.unreported)}`);

  fs.writeFileSync(path.join(out, 'bandeja-agora.png'), buildIcon(estado.counts).toPNG());

  const win = new BrowserWindow({
    width: 380,
    height: 460,
    show: true,
    frame: false,
    backgroundColor: '#16181d',
    webPreferences: {
      preload: path.join(__dirname, '..', 'src', 'ui', 'preload.js'),
      contextIsolation: true,
    },
  });
  await win.loadFile(path.join(__dirname, '..', 'src', 'ui', 'hud.html'));
  win.webContents.send('state', estado);
  await new Promise((r) => setTimeout(r, 900));

  const image = await win.webContents.capturePage();
  fs.writeFileSync(path.join(out, 'painel-agora.png'), image.toPNG());
  console.log(`\nsalvos em ${out}`);
  app.quit();
});

ipcMain.on('focus-session', () => {});
ipcMain.on('install-hooks', () => {});
ipcMain.on('close-hud', () => {});
