'use strict';

// Renderiza o HUD com dados falsos e salva um PNG, para conferir o layout sem
// precisar clicar no icone da bandeja.

const { app, BrowserWindow, ipcMain } = require('electron');
const path = require('path');
const fs = require('fs');

const AGORA = Date.now();

const ESTADO = {
  counts: { free: 1, busy: 2, needsYou: 1, indeterminate: 0 },
  unreported: 1,
  installed: true,
  sessions: [
    {
      id: 'a', name: 'safra-research', state: 'waitingForApproval', label: 'aguardando aprovacao', model: 'opus', since: AGORA - 42000,
    },
    {
      id: 'b', name: 'codestatus-win', state: 'busy', label: 'trabalhando', model: 'opus', since: AGORA - 8000,
    },
    {
      id: 'c', name: 'nav-model-abra', state: 'busy', label: 'trabalhando', model: 'sonnet', since: AGORA - 195000,
    },
    {
      id: 'd', name: 'dotfiles', state: 'free', label: 'livre', model: 'opus', since: AGORA - 3720000,
    },
  ],
};

app.whenReady().then(async () => {
  const win = new BrowserWindow({
    width: 380,
    height: 460,
    // Visivel de proposito: capturePage numa janela nunca pintada trava
    // esperando um frame que o compositor nao vai produzir.
    show: true,
    frame: false,
    transparent: false,
    backgroundColor: '#16181d',
    webPreferences: {
      preload: path.join(__dirname, '..', 'src', 'ui', 'preload.js'),
      contextIsolation: true,
    },
  });

  await win.loadFile(path.join(__dirname, '..', 'src', 'ui', 'hud.html'));
  win.webContents.send('state', ESTADO);
  await new Promise((r) => setTimeout(r, 900));

  const image = await win.webContents.capturePage();
  const out = path.join(__dirname, 'icons', 'hud.png');
  fs.writeFileSync(out, image.toPNG());
  console.log(`HUD salvo em ${out}`);
  app.quit();
});

ipcMain.on('focus-session', () => {});
ipcMain.on('install-hooks', () => {});
ipcMain.on('close-hud', () => {});
