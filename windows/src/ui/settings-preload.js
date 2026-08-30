'use strict';

const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('codestatus', {
  onState: (handler) => ipcRenderer.on('settings:state', (_e, payload) => handler(payload)),
  onTheme: (handler) => ipcRenderer.on('theme', (_e, payload) => handler(payload)),

  setPref: (key, value) => ipcRenderer.send('settings:pref', { key, value }),
  setOpenAtLogin: (value) => ipcRenderer.send('settings:openAtLogin', value),

  connect: () => ipcRenderer.send('hooks:install'),
  disconnect: () => ipcRenderer.send('hooks:uninstall'),
  openSettingsFile: () => ipcRenderer.send('hooks:openFile'),

  close: () => ipcRenderer.send('settings:close'),
});
