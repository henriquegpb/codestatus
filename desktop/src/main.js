'use strict';

// The main process: hosts the daemon, draws the tray and the popover, and
// raises the notifications. Equivalent to AppDelegate + MenuBarController +
// NotificationCoordinator + SessionDaemon in the macOS app.

const electron = require('electron');

// Claude Code is itself an Electron app and exports ELECTRON_RUN_AS_NODE to the
// processes it spawns. If that leaks in here, electron.exe runs as plain Node,
// `require('electron')` yields a path string instead of the API, and the app
// dies on a property of undefined. Cheap to detect, and the message saves the
// half hour it otherwise costs. See scripts/start.cmd, which clears it.
if (typeof electron === 'string' || !electron.app) {
  process.stderr.write(
    'CodeStatus: this was launched as plain Node, not as Electron.\n'
    + 'ELECTRON_RUN_AS_NODE is set in this environment — clear it and try again.\n',
  );
  process.exit(1);
}

const {
  app, Tray, Menu, BrowserWindow, Notification, ipcMain, shell, screen, dialog,
  nativeTheme, systemPreferences,
} = electron;
const path = require('path');
const os = require('os');

const { Daemon } = require('./daemon/daemon');
const { buildIcon, buildTooltip } = require('./ui/tray-icon');
const {
  displayName, primaryLabel, secondaryLabel, announcement,
} = require('./core/session');
const {
  AgentState, LABELS, needsAttention, isTurnCompletion,
} = require('./core/state');
const { hostDisplayName } = require('./core/events');
const installer = require('./install/claude');
const prefs = require('./core/prefs');
const { focusProcessWindow, focusCapability } = require('./platform/focus');
const autostart = require('./platform/autostart');

const ON_WINDOWS = process.platform === 'win32';

// Notifications on Windows are addressed to an application identity, not a
// process. Without this the toast is attributed to "electron.app.Electron" and
// clicking it goes nowhere. On Linux the equivalent job is done by the
// .desktop file the package installs, and this call is a no-op.
const APP_ID = 'com.codestatus.windows';

// The Windows uninstaller runs this before deleting anything, so the hook
// entries do not outlive the app they point at. Handled before anything else is
// set up: there is no tray, no daemon and no window to build for it, and the
// process has five seconds before the uninstaller stops waiting.
//
// Linux packages deliberately do not call it. `apt remove` runs its scripts as
// root, and the entries are in each user's ~/.claude/settings.json — a root
// script cannot know which users have them and has no business rewriting the
// configuration files of the ones it guesses. So on Linux this is the user's
// own Disconnect, and an orphaned entry is handled the way the design already
// handles one: the hook finds a stale heartbeat and drops the event.
if (process.argv.includes('--uninstall-hooks')) {
  try {
    // eslint-disable-next-line global-require
    require('./install/claude').uninstall();
  } catch { /* an uninstall must not fail because a JSON file was locked */ }
  app.exit(0);
}

const HUD_WIDTH = 380;
const HUD_MIN_HEIGHT = 120;
const HUD_MAX_HEIGHT = 640;
// Gap between the popover and the taskbar, matching the inset Windows flyouts use.
const HUD_MARGIN = 12;

// Mica and acrylic are DWM materials introduced in Windows 11 (build 22000).
// Asking for one on Windows 10 leaves the window painted with backgroundColor,
// which is why the fallback is a real colour rather than transparent.
//
// Linux has no equivalent to ask for. A blurred background is the compositor's
// to grant — KWin will do it for a window that sets a KDE-specific X11 property,
// GNOME will not do it at all — and Electron exposes no way to request one. So
// every Linux window paints a solid surface, the same as Windows 10.
const SUPPORTS_MATERIAL = ON_WINDOWS
  && Number(os.release().split('.')[2] || 0) >= 22000;

let tray = null;
let hud = null;
let settingsWindow = null;
let daemon = null;
let latest = {
  counts: {
    free: 0, busy: 0, needsYou: 0, indeterminate: 0,
  },
  sessions: [],
  unreportedCount: 0,
  diagnosis: { notConnected: {}, predatesHooks: 0, unexplained: 0 },
  scanFailed: false,
};

// One instance only: two daemons would fight over the same endpoint, and the
// second would simply receive nothing. It is also what makes it safe for the
// Linux transport to clear a socket file left behind by a crash without first
// checking whether something is listening on it.
if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', () => showHUD());
}

app.setAppUserModelId(APP_ID);

// MARK: - Theme

function currentTheme() {
  let accent = null;
  try {
    // Windows returns RRGGBBAA without a leading hash.
    const raw = systemPreferences.getAccentColor();
    if (raw) accent = `#${raw.slice(0, 6)}`;
  } catch { /* no accent available; the stylesheet default stands */ }

  return {
    theme: nativeTheme.shouldUseDarkColors ? 'dark' : 'light',
    accent,
    acrylic: SUPPORTS_MATERIAL,
  };
}

function pushTheme() {
  const theme = currentTheme();
  for (const win of [hud, settingsWindow]) {
    if (win && !win.isDestroyed()) win.webContents.send('theme', theme);
  }
}

nativeTheme.on('updated', () => {
  pushTheme();
  refreshTray();
});

// Shared by both windows. Transparency is deliberately not used: a transparent
// frameless window on Windows loses its shadow and picks up corner artefacts,
// and the DWM material gives the same effect without either.
function materialOptions(opaqueDark = '#2B2B2B', opaqueLight = '#F3F3F3') {
  if (SUPPORTS_MATERIAL) {
    return { backgroundMaterial: 'acrylic', backgroundColor: '#00000000' };
  }
  return { backgroundColor: nativeTheme.shouldUseDarkColors ? opaqueDark : opaqueLight };
}

// MARK: - Popover

function createHUD() {
  hud = new BrowserWindow({
    width: HUD_WIDTH,
    height: HUD_MIN_HEIGHT,
    show: false,
    frame: false,
    resizable: false,
    minimizable: false,
    maximizable: false,
    fullscreenable: false,
    skipTaskbar: true,
    alwaysOnTop: true,
    ...materialOptions(),
    webPreferences: {
      preload: path.join(__dirname, 'ui', 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });

  hud.loadFile(path.join(__dirname, 'ui', 'hud.html'));
  hud.once('ready-to-show', () => {
    pushTheme();
    pushToHUD();
  });

  // Click outside dismisses it, the way a flyout does.
  hud.on('blur', () => { if (hud && !hud.webContents.isDevToolsOpened()) hud.hide(); });
}

// Where to put the popover when the platform will not say where its tray icon
// is.
//
// tray.getBounds() is documented as macOS and Windows only, and on Linux it
// returns zeros: StatusNotifierItem is a D-Bus protocol in which the host panel
// draws the icon and never tells the application where. There is no API to add,
// on any desktop — the icon genuinely does not have a position we can be told.
//
// So the corner is inferred from the one thing the display does report. A panel
// reserves space, and the difference between the display's full bounds and its
// work area is exactly where that panel is: a gap at the top means a top panel,
// which is where GNOME and most Ubuntu setups put the indicator area, and
// otherwise the bottom, which is KDE's and XFCE's default. Right-hand side
// either way, because every desktop that has a tray puts it at the end of the
// panel.
function inferredAnchor() {
  const display = screen.getPrimaryDisplay();
  const { bounds, workArea } = display;
  const panelAtTop = workArea.y > bounds.y;
  const x = workArea.x + workArea.width;
  const y = panelAtTop ? workArea.y : workArea.y + workArea.height;
  return {
    x, y, width: 0, height: 0,
  };
}

// Anchors the popover to the tray icon.
//
// macOS gives a popover the status item to hang off. Windows does not, but it
// does tell us where the icon was drawn — including inside the overflow flyout,
// which is where a new icon lives until the user drags it out. Clamped to the
// work area so it can never open off-screen on a secondary display, and the
// side is chosen from where the taskbar actually is rather than assumed to be
// the bottom.
function positionHUD(height) {
  const bounds = ON_WINDOWS && tray ? tray.getBounds() : null;
  const anchor = bounds && bounds.width > 0 ? bounds : inferredAnchor();

  const display = screen.getDisplayNearestPoint({ x: anchor.x, y: anchor.y });
  const area = display.workArea;

  const x = Math.round(Math.min(
    Math.max(anchor.x + anchor.width / 2 - HUD_WIDTH / 2, area.x + HUD_MARGIN),
    area.x + area.width - HUD_WIDTH - HUD_MARGIN,
  ));

  // Above the icon when the taskbar is at the bottom, below it when at the top.
  const trayIsAtTop = anchor.y + anchor.height / 2 < area.y + area.height / 2;
  const y = trayIsAtTop
    ? Math.round(Math.max(anchor.y + anchor.height + HUD_MARGIN, area.y + HUD_MARGIN))
    : Math.round(Math.min(
      anchor.y - height - HUD_MARGIN,
      area.y + area.height - height - HUD_MARGIN,
    ));

  hud.setBounds({
    x, y, width: HUD_WIDTH, height,
  });
}

function showHUD() {
  if (!hud) createHUD();
  if (hud.isVisible()) {
    hud.hide();
    return;
  }
  pushToHUD();
  positionHUD(hud.getBounds().height);
  hud.show();
  hud.focus();
}

function sessionForRenderer(session) {
  return {
    id: session.id,
    name: primaryLabel(session),
    // The agent's own name for the session, sent only when it has one. It
    // qualifies the row beside the location rather than replacing it.
    agentTitle: secondaryLabel(session),
    provider: session.provider,
    state: session.state,
    label: LABELS[session.state] || session.state,
    cwd: session.cwd,
    model: session.model,
    pid: session.pid,
    since: session.stateChangedAt,
    host: hostDisplayName(session.hostApplication),
  };
}

function pushToHUD() {
  if (!hud || hud.isDestroyed()) return;
  hud.webContents.send('state', {
    counts: latest.counts,
    unreportedCount: latest.unreportedCount,
    diagnosis: latest.diagnosis,
    scanFailed: latest.scanFailed,
    installed: installer.isInstalled(),
    sessions: latest.sessions.map(sessionForRenderer),
  });
}

// MARK: - Settings

function showSettings() {
  if (settingsWindow && !settingsWindow.isDestroyed()) {
    settingsWindow.show();
    settingsWindow.focus();
    return;
  }

  settingsWindow = new BrowserWindow({
    width: 560,
    height: 720,
    frame: false,
    resizable: true,
    minWidth: 460,
    minHeight: 420,
    show: false,
    ...materialOptions(),
    webPreferences: {
      preload: path.join(__dirname, 'ui', 'settings-preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });

  settingsWindow.loadFile(path.join(__dirname, 'ui', 'settings.html'));
  settingsWindow.once('ready-to-show', () => {
    pushTheme();
    pushSettings();
    settingsWindow.show();
  });
  settingsWindow.on('closed', () => { settingsWindow = null; });
}

function pushSettings() {
  if (!settingsWindow || settingsWindow.isDestroyed()) return;
  settingsWindow.webContents.send('settings:state', {
    prefs: prefs.all(),
    // The renderer is sandboxed and has no process of its own to ask.
    platform: process.platform,
    openAtLogin: autostart.isEnabled(),
    hooks: installer.status(),
    // Why clicking a row may open a folder instead of raising a terminal. Null
    // on Windows, and on a Linux session that can do it — the screen says
    // nothing rather than reassuring anyone about a thing that just works.
    focusLimitation: focusCapability().reason,
    version: app.getVersion(),
  });
}

// MARK: - Tray

function refreshTray() {
  if (!tray) return;
  tray.setImage(buildIcon(latest.counts));
  tray.setToolTip(buildTooltip(latest.counts, latest.unreportedCount, latest.diagnosis));
}

function buildMenu() {
  const installed = installer.isInstalled();
  return Menu.buildFromTemplate([
    { label: 'Open CodeStatus', click: () => showHUD() },
    { type: 'separator' },
    {
      label: installed ? 'Disconnect Claude Code' : 'Connect Claude Code',
      click: () => (installed ? doUninstall() : doInstall()),
    },
    { label: 'Settings…', click: () => showSettings() },
    { type: 'separator' },
    { label: 'Quit CodeStatus', click: () => app.quit() },
  ]);
}

function refreshMenu() {
  if (tray) tray.setContextMenu(buildMenu());
}

// MARK: - Install

function doInstall() {
  try {
    const receipt = installer.install();
    refreshMenu();
    pushToHUD();
    pushSettings();
    dialog.showMessageBox({
      type: 'info',
      title: 'CodeStatus',
      message: 'Claude Code connected.',
      detail: `Hooks were written to ${receipt.targetPath}.\n`
        + `Backup: ${receipt.backupPath || 'there was no previous file'}\n\n`
        + 'Sessions that were already open will not be seen: Claude Code reads '
        + 'its hook configuration once, at session start. Open a new session to '
        + 'test it.',
    });
  } catch (err) {
    dialog.showErrorBox('CodeStatus', `Could not install the hooks.\n\n${err.message}`);
  }
}

function doUninstall() {
  try {
    installer.uninstall();
    refreshMenu();
    pushToHUD();
    pushSettings();
    dialog.showMessageBox({
      type: 'info',
      title: 'CodeStatus',
      message: 'Claude Code disconnected.',
      detail: 'CodeStatus’s entries were removed from settings.json. Your own '
        + 'hooks were left alone.',
    });
  } catch (err) {
    dialog.showErrorBox('CodeStatus', `Could not remove the hooks.\n\n${err.message}`);
  }
}

// MARK: - Notifications

function formatDuration(seconds) {
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  return minutes > 0 ? `${hours}h ${minutes}m` : `${hours}h`;
}

// One notification per transition. The registry's deduplicator already keeps a
// repeated event from reaching here, so a turn can never announce twice.
//
// Two categories, each with its own switch: the session started needing you, or
// the session finished what it was doing.
function notifyTransition(transition, session) {
  if (!Notification.isSupported()) return;

  // The toast leads with the repository and the body names the session, which
  // is the split announcement() exists to make: three sessions in one
  // repository would otherwise send three identical toasts.
  const name = session ? displayName(session) : 'Session';
  const silent = !prefs.get('soundEnabled');
  let body = null;

  if (needsAttention(transition.to)) {
    if (!prefs.get('notifyWhenNeeded')) return;
    body = {
      [AgentState.waitingForApproval]: 'Waiting for your approval.',
      [AgentState.waitingForInput]: 'Waiting for your reply.',
      [AgentState.failed]: 'The turn ended in an error.',
    }[transition.to] || 'Needs you.';
  } else if (isTurnCompletion(transition.from, transition.to)) {
    if (!prefs.get('notifyOnCompletion')) return;
    const seconds = Math.max(0, Math.round((transition.occurredAt - session.startedAt) / 1000));
    body = seconds > 0 ? `Finished. ${formatDuration(seconds)} in this session.` : 'Finished.';
  } else {
    return;
  }

  if (session) body = announcement(session, body);

  const notification = new Notification({ title: name, body, silent });
  notification.on('click', () => {
    if (session) openSession(session);
    else showHUD();
  });
  notification.show();
}

// MARK: - Returning to a session

function openSession(session) {
  if (!session) return;
  focusProcessWindow(session.pid, (found) => {
    // No window in the tree: opening the folder is the consolation, and it still
    // puts the user in the right place.
    if (!found && session.cwd) shell.openPath(session.cwd);
  });
}

// MARK: - Lifecycle

app.whenReady().then(() => {
  daemon = new Daemon();
  // Set rather than toggled: setScanEnabled kicks off a scan, and start() is
  // about to run one anyway once the runtime directories exist.
  daemon.scanEnabled = Boolean(prefs.get('scanForUnreported'));

  daemon.on('effects', (effects, snapshot) => {
    latest = snapshot;
    refreshTray();
    pushToHUD();
    for (const effect of effects) {
      if (effect.type === 'sessionChanged') {
        const session = daemon.registry.get(effect.transition.sessionID);
        notifyTransition(effect.transition, session);
      }
    }
  });

  daemon.on('error', (err) => {
    dialog.showErrorBox(
      'CodeStatus',
      `The event transport failed.\n\n${err.message}\n\n`
      + 'If another copy of CodeStatus is running, close it first.',
    );
  });

  daemon.start();

  tray = new Tray(buildIcon(latest.counts));
  refreshTray();
  refreshMenu();

  // On Windows a left click opens the popover and the menu is the right-click
  // alternative. On Linux there is no left click to bind: the tray is
  // StatusNotifierItem through libappindicator, where the panel owns the icon
  // and a click opens the menu the application supplied — Electron documents
  // the `click` event as not emitted there, and it is not a gap we can fill.
  //
  // Which is why "Open CodeStatus" is the first item of that menu rather than a
  // convenience: on this platform it is the only way in.
  if (ON_WINDOWS) tray.on('click', () => showHUD());

  createHUD();
});

// MARK: - IPC

ipcMain.on('session:focus', (_e, id) => {
  const session = daemon && daemon.registry.get(id);
  if (session) openSession(session);
  if (hud) hud.hide();
});

ipcMain.on('session:dismiss', (_e, id) => {
  if (daemon) daemon.forget(id);
});

ipcMain.on('app:refresh', () => { if (daemon) daemon.refresh(); });
ipcMain.on('app:settings', () => { if (hud) hud.hide(); showSettings(); });
ipcMain.on('app:quit', () => app.quit());

ipcMain.on('hooks:install', () => doInstall());
ipcMain.on('hooks:uninstall', () => doUninstall());
ipcMain.on('hooks:openFile', () => shell.openPath(installer.status().settingsPath));

// The popover hugs its content: the renderer measures, the main process resizes
// and re-anchors, because the window grows upward from the taskbar.
ipcMain.on('hud:height', (_e, height) => {
  if (!hud || hud.isDestroyed()) return;
  const clamped = Math.max(HUD_MIN_HEIGHT, Math.min(Math.round(height), HUD_MAX_HEIGHT));
  if (hud.getBounds().height === clamped) return;
  positionHUD(clamped);
});

ipcMain.on('hud:close', () => { if (hud) hud.hide(); });

ipcMain.on('settings:pref', (_e, { key, value }) => {
  prefs.set(key, value);
  if (key === 'scanForUnreported' && daemon) daemon.setScanEnabled(value);
  pushSettings();
});

ipcMain.on('settings:openAtLogin', (_e, value) => {
  try {
    autostart.setEnabled(value);
  } catch (err) {
    // Only Linux refuses, and only from an AppImage mount whose path will not
    // exist at the next login. Saying so beats a switch that flips back.
    dialog.showErrorBox('CodeStatus', `Could not change this.\n\n${err.message}`);
  }
  pushSettings();
});

ipcMain.on('settings:close', () => {
  if (settingsWindow && !settingsWindow.isDestroyed()) settingsWindow.close();
});

// A tray app has no windows most of the time; closing the last one must not
// quit it.
app.on('window-all-closed', (e) => e.preventDefault());
app.on('before-quit', () => { if (daemon) daemon.stop(); });
