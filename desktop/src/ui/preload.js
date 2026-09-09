'use strict';

// The narrow bridge between the renderer and the main process. The renderer
// gets no access to Node: only these calls cross.

const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('codestatus', {
  onState: (handler) => ipcRenderer.on('state', (_e, payload) => handler(payload)),
  onTheme: (handler) => ipcRenderer.on('theme', (_e, payload) => handler(payload)),

  // Session actions
  focusSession: (id) => ipcRenderer.send('session:focus', id),
  dismissSession: (id) => ipcRenderer.send('session:dismiss', id),

  // Footer actions
  refresh: () => ipcRenderer.send('app:refresh'),
  openSettings: () => ipcRenderer.send('app:settings'),
  quit: () => ipcRenderer.send('app:quit'),

  // Setup
  connect: () => ipcRenderer.send('hooks:install'),

  // The popover sizes itself to its content, the way the macOS one does. The
  // renderer is the only side that knows how tall the content actually is.
  reportHeight: (height) => ipcRenderer.send('hud:height', height),
  close: () => ipcRenderer.send('hud:close'),
});
