'use strict';

// The main process: hosts the daemon, draws the tray and the HUD, and raises
// the notifications. Equivalent to AppDelegate + MenuBarController +
// NotificationCoordinator + SessionDaemon in the original.

const {
  app, Tray, Menu, BrowserWindow, Notification, ipcMain, shell, screen, dialog,
} = require('electron');
const path = require('path');

const { Daemon } = require('./daemon/daemon');
const { buildIcon, buildTooltip } = require('./ui/tray-icon');
const { displayName } = require('./core/session');
const {
  AgentState, LABELS, needsAttention, isTurnCompletion,
} = require('./core/state');
const installer = require('./install/claude');
const prefs = require('./core/prefs');
const { focusProcessWindow } = require('./platform/focus');

let tray = null;
let hud = null;
let daemon = null;
let latest = {
  counts: {
    free: 0, busy: 0, needsYou: 0, indeterminate: 0,
  },
  sessions: [],
  unreportedCount: 0,
};

// One instance only: two daemons would fight over the same named pipe, and the
// second would simply receive nothing.
if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', () => showHUD());
}

// MARK: - HUD

function createHUD() {
  hud = new BrowserWindow({
    width: 380,
    height: 460,
    show: false,
    frame: false,
    resizable: false,
    skipTaskbar: true,
    alwaysOnTop: true,
    transparent: true,
    webPreferences: {
      preload: path.join(__dirname, 'ui', 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });
  hud.loadFile(path.join(__dirname, 'ui', 'hud.html'));
  // Click outside dismisses it, the way a popover does.
  hud.on('blur', () => hud.hide());
}

function showHUD() {
  if (!hud) createHUD();
  const cursor = screen.getCursorScreenPoint();
  const display = screen.getDisplayNearestPoint(cursor);
  const [w, h] = hud.getSize();
  const area = display.workArea;
  // Anchored where the tray normally lives, but clamped to the work area so it
  // never opens off-screen on a secondary display.
  const x = Math.min(Math.max(cursor.x - w / 2, area.x + 8), area.x + area.width - w - 8);
  const y = Math.max(area.y + 8, area.y + area.height - h - 8);
  hud.setPosition(Math.round(x), Math.round(y));
  hud.show();
  hud.focus();
  pushToHUD();
}

function pushToHUD() {
  if (!hud || hud.isDestroyed()) return;
  hud.webContents.send('state', {
    counts: latest.counts,
    unreportedCount: latest.unreportedCount,
    installed: installer.isInstalled(),
    sessions: latest.sessions.map((s) => ({
      id: s.id,
      name: displayName(s),
      state: s.state,
      label: LABELS[s.state] || s.state,
      cwd: s.cwd,
      model: s.model,
      pid: s.pid,
      since: s.stateChangedAt,
      host: s.hostApplication,
    })),
  });
}

// MARK: - Tray

function refreshTray() {
  if (!tray) return;
  tray.setImage(buildIcon(latest.counts));
  tray.setToolTip(buildTooltip(latest.counts, latest.unreportedCount));
}

function buildMenu() {
  const installed = installer.isInstalled();
  return Menu.buildFromTemplate([
    { label: 'Open CodeStatus', click: showHUD },
    { type: 'separator' },
    {
      label: installed ? 'Disconnect Claude Code' : 'Connect Claude Code',
      click: () => (installed ? doUninstall() : doInstall()),
    },
    {
      label: 'Start with Windows',
      type: 'checkbox',
      checked: app.getLoginItemSettings().openAtLogin,
      click: (item) => app.setLoginItemSettings({ openAtLogin: item.checked }),
    },
    { type: 'separator' },
    {
      label: 'Tell me when a turn finishes',
      type: 'checkbox',
      checked: prefs.get('notifyOnCompletion'),
      click: (item) => prefs.set('notifyOnCompletion', item.checked),
    },
    {
      label: 'Tell me when a session needs me',
      type: 'checkbox',
      checked: prefs.get('notifyWhenNeeded'),
      click: (item) => prefs.set('notifyWhenNeeded', item.checked),
    },
    {
      label: 'Play a sound',
      type: 'checkbox',
      checked: prefs.get('soundEnabled'),
      click: (item) => prefs.set('soundEnabled', item.checked),
    },
    { type: 'separator' },
    {
      label: 'Open settings.json',
      click: () => shell.openPath(installer.status().settingsPath),
    },
    { label: 'Quit', click: () => app.quit() },
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
    dialog.showMessageBox({
      type: 'info',
      title: 'CodeStatus',
      message: 'Claude Code disconnected.',
      detail: 'CodeStatus’s entries were removed from settings.json.',
    });
  } catch (err) {
    dialog.showErrorBox('CodeStatus', `Could not remove the hooks.\n\n${err.message}`);
  }
}

// MARK: - Notifications

// One notification per transition. The registry's deduplicator already keeps a
// repeated event from reaching here, so a turn can never announce twice.
//
// Two categories, each with its own switch: the session started needing you, or
// the session finished what it was doing.
function notifyTransition(transition, session) {
  if (!Notification.isSupported()) return;

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
    // How long the turn took answers the question you ask when you come back to
    // a session that has been working on its own.
    const seconds = Math.max(0, Math.round((transition.occurredAt - session.startedAt) / 1000));
    body = seconds > 0 ? `Finished. ${formatDuration(seconds)} in this session.` : 'Finished.';
  } else {
    return;
  }

  const notification = new Notification({ title: name, body, silent });
  notification.on('click', () => {
    if (session) openSession(session);
    else showHUD();
  });
  notification.show();
}

function formatDuration(seconds) {
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
  return `${Math.floor(seconds / 3600)}h${String(Math.floor((seconds % 3600) / 60)).padStart(2, '0')}`;
}

// MARK: - Returning to a session

function openSession(session) {
  if (!session) return;
  focusProcessWindow(session.pid, (found) => {
    if (!found && session.cwd) shell.openPath(session.cwd);
  });
}

// MARK: - Lifecycle

app.whenReady().then(() => {
  daemon = new Daemon();

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
  tray.on('click', showHUD);

  createHUD();

  // Time in each state is shown in the HUD, so it needs a tick of its own even
  // when nothing happens.
  setInterval(() => { if (hud && hud.isVisible()) pushToHUD(); }, 1000);
});

ipcMain.on('session:focus', (_event, id) => {
  const session = daemon && daemon.registry.get(id);
  if (session) openSession(session);
  if (hud) hud.hide();
});

ipcMain.on('hooks:install', () => doInstall());
ipcMain.on('hud:close', () => { if (hud) hud.hide(); });

app.on('window-all-closed', (e) => e.preventDefault());
app.on('before-quit', () => { if (daemon) daemon.stop(); });
