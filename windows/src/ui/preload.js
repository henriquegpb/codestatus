'use strict';

// Ponte estreita entre o HUD e o processo principal. O renderer nao recebe
// acesso a Node: so estas quatro operacoes atravessam.

const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('codestatus', {
  onState: (handler) => ipcRenderer.on('state', (_e, payload) => handler(payload)),
  focusSession: (id) => ipcRenderer.send('focus-session', id),
  installHooks: () => ipcRenderer.send('install-hooks'),
  close: () => ipcRenderer.send('close-hud'),
});
