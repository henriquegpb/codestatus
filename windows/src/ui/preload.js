'use strict';

// The narrow bridge between the HUD and the main process. The renderer gets no
// access to Node: only these operations cross.

const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('codestatus', {
  onState: (handler) => ipcRenderer.on('state', (_e, payload) => handler(payload)),
  focusSession: (id) => ipcRenderer.send('session:focus', id),
  connect: () => ipcRenderer.send('hooks:install'),
  close: () => ipcRenderer.send('hud:close'),
});
