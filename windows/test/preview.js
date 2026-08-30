'use strict';

// Opens the popover and the settings window filled with made-up sessions, with
// no daemon and no agent running.
//
// Every interesting state of this UI needs a real Claude Code session sitting in
// it — a failed turn, a session blocked on approval, an agent running with no
// hooks installed. Waiting for those to happen naturally is not a way to check
// a layout, and it is not a way to check it on a fresh Windows VM either.
//
//   npm run preview              open the windows and leave them up
//   npm run preview -- --shots   write PNGs of both, in both themes, then quit
//
// The --shots mode runs anywhere Electron runs, which includes a Mac. It cannot
// show the acrylic (that is DWM, and Windows 11 only) or the real Segoe metrics,
// so it renders what Windows 10 would — but layout, spacing, hierarchy and both
// palettes are all checkable without booting a VM, which is most of what goes
// wrong.
//
// Buttons are wired to log rather than act: these windows have no daemon.

const {
  app, BrowserWindow, ipcMain, nativeTheme, systemPreferences,
} = require('electron');
const fs = require('fs');
const path = require('path');
const os = require('os');

const SHOTS = process.argv.includes('--shots');
const SHOT_DIR = path.join(__dirname, 'shots');

const SUPPORTS_MATERIAL = process.platform === 'win32'
  && Number(os.release().split('.')[2] || 0) >= 22000;

const NOW = Date.now();

const STATE = {
  counts: {
    free: 1, busy: 2, needsYou: 2, indeterminate: 1,
  },
  unreportedCount: 2,
  installed: true,
  scanFailed: false,
  diagnosis: { notConnected: {}, predatesHooks: 2, unexplained: 0 },
  sessions: [
    {
      id: '1',
      name: 'codestatus',
      provider: 'claudeCode',
      state: 'waitingForApproval',
      label: 'Needs approval',
      host: 'Terminal',
      since: NOW - 42 * 1000,
    },
    {
      id: '2',
      name: 'nora-api',
      provider: 'claudeCode',
      state: 'waitingForInput',
      label: 'Needs a reply',
      host: 'VS Code',
      since: NOW - 3 * 60 * 1000,
    },
    {
      id: '3',
      name: 'a-project-with-a-very-long-directory-name',
      provider: 'claudeCode',
      state: 'busy',
      label: 'Busy',
      host: 'Terminal',
      since: NOW - 71 * 60 * 1000,
    },
    {
      id: '4',
      name: 'drainrate',
      provider: 'claudeCode',
      state: 'busy',
      label: 'Busy',
      host: 'PowerShell',
      since: NOW - 8 * 1000,
    },
    {
      id: '5',
      name: 'website',
      provider: 'claudeCode',
      state: 'free',
      label: 'Free',
      host: 'Terminal',
      since: NOW - 26 * 60 * 1000,
    },
    {
      id: '6',
      name: 'experiments',
      provider: 'claudeCode',
      state: 'reconnecting',
      label: 'Reconnecting',
      host: '',
      since: NOW - 2 * 1000,
    },
  ],
};

const SETTINGS_STATE = {
  prefs: {
    notifyWhenNeeded: true,
    notifyOnCompletion: false,
    soundEnabled: true,
    scanForUnreported: true,
  },
  openAtLogin: false,
  hooks: {
    installed: true,
    settingsPath: path.join(os.homedir(), '.claude', 'settings.json'),
    hookScript: 'C:\\Program Files\\CodeStatus\\resources\\hook\\hook.js',
    runtime: 'C:\\Program Files\\CodeStatus\\CodeStatus.exe',
    shim: 'C:\\Users\\you\\AppData\\Local\\CodeStatus\\bin\\hook.cmd',
    events: 14,
    problems: [],
  },
  version: '0.4.0-preview',
};

// Forced when capturing, so both palettes are produced in one run instead of
// whichever one the machine happens to be set to.
let forcedTheme = null;

function theme() {
  let accent = null;
  // Only the real thing on Windows. Elsewhere this returns the host system's
  // accent, and a preview tinted with a Mac's colour is a preview of something
  // nobody will see — so it falls back to the Windows 11 default.
  if (process.platform === 'win32') {
    try {
      const raw = systemPreferences.getAccentColor();
      if (raw) accent = `#${raw.slice(0, 6)}`;
    } catch { /* no accent available */ }
  }
  return {
    theme: forcedTheme || (nativeTheme.shouldUseDarkColors ? 'dark' : 'light'),
    accent: accent || (forcedTheme === 'light' ? '#005FB8' : '#4CC2FF'),
    acrylic: SUPPORTS_MATERIAL,
  };
}

function materialOptions() {
  if (SUPPORTS_MATERIAL) {
    return { backgroundMaterial: 'acrylic', backgroundColor: '#00000000' };
  }
  return { backgroundColor: nativeTheme.shouldUseDarkColors ? '#2B2B2B' : '#F3F3F3' };
}

let hud;

app.whenReady().then(() => {
  hud = new BrowserWindow({
    width: 380,
    height: 460,
    x: 60,
    y: 60,
    frame: false,
    resizable: true,
    ...materialOptions(),
    webPreferences: {
      preload: path.join(__dirname, '..', 'src', 'ui', 'preload.js'),
      contextIsolation: true,
      sandbox: true,
    },
  });
  hud.loadFile(path.join(__dirname, '..', 'src', 'ui', 'hud.html'));
  hud.once('ready-to-show', () => {
    hud.webContents.send('theme', theme());
    hud.webContents.send('state', STATE);
  });

  const settings = new BrowserWindow({
    width: 560,
    height: 660,
    x: 480,
    y: 60,
    frame: false,
    ...materialOptions(),
    webPreferences: {
      preload: path.join(__dirname, '..', 'src', 'ui', 'settings-preload.js'),
      contextIsolation: true,
      sandbox: true,
    },
  });
  settings.loadFile(path.join(__dirname, '..', 'src', 'ui', 'settings.html'));
  settings.once('ready-to-show', () => {
    settings.webContents.send('theme', theme());
    settings.webContents.send('settings:state', SETTINGS_STATE);
  });

  nativeTheme.on('updated', () => {
    for (const win of [hud, settings]) {
      if (win && !win.isDestroyed()) win.webContents.send('theme', theme());
    }
  });

  if (SHOTS) {
    captureAll(hud, settings);
    return;
  }

  console.log('Preview windows open. Switch Windows between light and dark to');
  console.log('check both themes; the pages follow the system immediately.');
});

const wait = (ms) => new Promise((resolve) => { setTimeout(resolve, ms); });

// Resolves once the page has loaded and had a chance to lay out.
//
// whenReady fires before either window has painted, and capturing then gets the
// popover at its opening height rather than the height it asks to be — which is
// how the first version of this produced one screenshot of a 120px sliver.
function whenPainted(win) {
  return new Promise((resolve) => {
    if (!win.webContents.isLoading()) {
      resolve();
      return;
    }
    win.webContents.once('did-finish-load', resolve);
  });
}

async function captureAll(hudWindow, settingsWindow) {
  fs.mkdirSync(SHOT_DIR, { recursive: true });
  await Promise.all([whenPainted(hudWindow), whenPainted(settingsWindow)]);
  await wait(500);

  for (const mode of ['dark', 'light']) {
    forcedTheme = mode;
    for (const [name, win] of [['popover', hudWindow], ['settings', settingsWindow]]) {
      win.webContents.send('theme', theme());
      // Long enough for the theme swap, the resize the popover asks for, and
      // the paint that follows it.
      // eslint-disable-next-line no-await-in-loop
      await wait(500);
      // eslint-disable-next-line no-await-in-loop
      const image = await win.webContents.capturePage();
      fs.writeFileSync(path.join(SHOT_DIR, `${name}-${mode}.png`), image.toPNG());
      const { height } = win.getBounds();
      console.log(`  wrote ${name}-${mode}.png (${win.getBounds().width}x${height})`);
    }
  }

  console.log(`\nScreenshots in ${SHOT_DIR}`);
  app.quit();
}

// The popover still resizes itself here — that behaviour is worth previewing too.
ipcMain.on('hud:height', (_e, height) => {
  if (!hud || hud.isDestroyed()) return;
  const bounds = hud.getBounds();
  hud.setBounds({ ...bounds, height: Math.max(120, Math.min(Math.round(height), 640)) });
});

for (const channel of [
  'session:focus', 'session:dismiss', 'app:refresh', 'app:settings', 'app:quit',
  'hooks:install', 'hooks:uninstall', 'hooks:openFile', 'hud:close',
  'settings:pref', 'settings:openAtLogin', 'settings:close',
]) {
  ipcMain.on(channel, (_e, payload) => {
    console.log(`  ${channel}`, payload === undefined ? '' : payload);
  });
}

app.on('window-all-closed', () => app.quit());
