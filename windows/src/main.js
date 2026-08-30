'use strict';

// Processo principal: hospeda o daemon, desenha a bandeja e o HUD, e dispara
// as notificacoes. Equivalente a AppDelegate + MenuBarController +
// NotificationCoordinator + SessionDaemon do original.

const {
  app, Tray, Menu, BrowserWindow, Notification, ipcMain, shell, screen, dialog,
} = require('electron');
const path = require('path');
const { execFile } = require('child_process');

const { Daemon } = require('./daemon/daemon');
const { buildIcon, buildTooltip } = require('./ui/icon');
const { displayName } = require('./core/session');
const {
  AgentState, LABELS_PT, needsAttention, isTurnCompletion,
} = require('./core/state');
const installer = require('./core/installer');
const prefs = require('./core/prefs');

let tray = null;
let hud = null;
let daemon = null;
let latest = { counts: { free: 0, busy: 0, needsYou: 0, indeterminate: 0 }, sessions: [], unreported: 0 };

// Uma instancia so: dois daemons brigariam pelo mesmo named pipe e o segundo
// simplesmente nao receberia evento nenhum.
if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', () => showHUD());
}

// Sem isso o app aparece na barra de tarefas e o Alt+Tab, o que nao e o que se
// espera de um monitor que vive na bandeja.
if (app.dock) app.dock.hide();

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
  // Clicar fora fecha, como um popover.
  hud.on('blur', () => hud.hide());
}

function showHUD() {
  if (!hud) createHUD();
  const cursor = screen.getCursorScreenPoint();
  const display = screen.getDisplayNearestPoint(cursor);
  const [w, h] = hud.getSize();
  const area = display.workArea;
  // Ancorado no canto onde a bandeja normalmente vive, mas preso a area util
  // para nunca abrir fora da tela em monitor secundario.
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
    unreported: latest.unreported,
    installed: installer.isInstalled(),
    sessions: latest.sessions.map((s) => ({
      id: s.id,
      name: displayName(s),
      state: s.state,
      label: LABELS_PT[s.state] || s.state,
      cwd: s.cwd,
      model: s.model,
      pid: s.pid,
      since: s.stateChangedAt,
      host: s.hostApplication,
    })),
  });
}

// MARK: - Bandeja

function refreshTray() {
  if (!tray) return;
  tray.setImage(buildIcon(latest.counts));
  tray.setToolTip(buildTooltip(latest.counts, latest.unreported));
}

function buildMenu() {
  const installed = installer.isInstalled();
  return Menu.buildFromTemplate([
    { label: 'Abrir painel', click: showHUD },
    { type: 'separator' },
    {
      label: installed ? 'Desconectar Claude Code' : 'Conectar Claude Code',
      click: () => (installed ? doUninstall() : doInstall()),
    },
    {
      label: 'Iniciar com o Windows',
      type: 'checkbox',
      checked: app.getLoginItemSettings().openAtLogin,
      click: (item) => app.setLoginItemSettings({ openAtLogin: item.checked }),
    },
    { type: 'separator' },
    {
      label: 'Avisar quando terminar',
      type: 'checkbox',
      checked: prefs.get('avisarAoTerminar'),
      click: (item) => prefs.set('avisarAoTerminar', item.checked),
    },
    {
      label: 'Avisar quando precisar de voce',
      type: 'checkbox',
      checked: prefs.get('avisarQuandoPrecisa'),
      click: (item) => prefs.set('avisarQuandoPrecisa', item.checked),
    },
    {
      label: 'Som nas notificacoes',
      type: 'checkbox',
      checked: prefs.get('som'),
      click: (item) => prefs.set('som', item.checked),
    },
    { type: 'separator' },
    {
      label: 'Abrir settings.json',
      click: () => shell.openPath(installer.status().settingsPath),
    },
    { label: 'Sair', click: () => app.quit() },
  ]);
}

function refreshMenu() {
  if (tray) tray.setContextMenu(buildMenu());
}

// MARK: - Instalacao

function doInstall() {
  try {
    const receipt = installer.install();
    refreshMenu();
    pushToHUD();
    dialog.showMessageBox({
      type: 'info',
      title: 'CodeStatus',
      message: 'Claude Code conectado.',
      detail: `Os hooks foram gravados em ${receipt.targetPath}.\n`
        + `Backup: ${receipt.backupPath || 'nao havia arquivo anterior'}\n\n`
        + 'Sessoes que ja estavam abertas nao serao vistas: o Claude Code le a '
        + 'configuracao de hooks uma vez, no inicio da sessao. Abra uma sessao '
        + 'nova para testar.',
    });
  } catch (err) {
    dialog.showErrorBox('CodeStatus', `Nao foi possivel instalar os hooks.\n\n${err.message}`);
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
      message: 'Claude Code desconectado.',
      detail: 'As entradas do CodeStatus foram removidas do settings.json.',
    });
  } catch (err) {
    dialog.showErrorBox('CodeStatus', `Nao foi possivel remover os hooks.\n\n${err.message}`);
  }
}

// MARK: - Notificacoes

// Uma notificacao por transicao. O deduplicador do registry ja garante que um
// evento repetido nao chega aqui, entao um turno nunca avisa duas vezes.
//
// Duas categorias, cada uma com o seu interruptor: a sessao passou a precisar de
// voce, ou a sessao terminou o que estava fazendo.
function notifyTransition(transition, session) {
  if (!Notification.isSupported()) return;

  const name = session ? displayName(session) : 'Sessao';
  const silent = !prefs.get('som');
  let body = null;

  if (needsAttention(transition.to)) {
    if (!prefs.get('avisarQuandoPrecisa')) return;
    body = {
      [AgentState.waitingForApproval]: 'Esta aguardando sua aprovacao.',
      [AgentState.waitingForInput]: 'Esta esperando sua resposta.',
      [AgentState.failed]: 'O turno terminou com erro.',
    }[transition.to] || 'Precisa de voce.';
  } else if (isTurnCompletion(transition.from, transition.to)) {
    if (!prefs.get('avisarAoTerminar')) return;
    // Quanto tempo o turno levou responde a pergunta que se faz ao voltar para
    // uma sessao que ficou trabalhando sozinha.
    const segundos = Math.max(0, Math.round((transition.occurredAt - session.startedAt) / 1000));
    body = segundos > 0 ? `Terminou. ${formatarDuracao(segundos)} nesta sessao.` : 'Terminou.';
  } else {
    return;
  }

  const n = new Notification({ title: name, body, silent });
  n.on('click', () => {
    if (session) focusSession(session);
    else showHUD();
  });
  n.show();
}

function formatarDuracao(segundos) {
  if (segundos < 60) return `${segundos}s`;
  if (segundos < 3600) return `${Math.floor(segundos / 60)}min`;
  return `${Math.floor(segundos / 3600)}h${String(Math.floor((segundos % 3600) / 60)).padStart(2, '0')}`;
}

// MARK: - Voltar para a sessao

// No macOS o original usa AppleScript para selecionar a aba exata do terminal.
// O Windows nao expoe abas individualmente - nem o Windows Terminal - entao o
// melhor honesto e trazer para frente a janela que hospeda o processo do agente,
// subindo a arvore de processos ate achar uma que tenha janela.
function focusSession(session) {
  if (!session || !session.pid) return;
  const script = `
    $ErrorActionPreference = 'SilentlyContinue'
    Add-Type -Namespace W -Name U -MemberDefinition '
      [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
      [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);'
    $pid_ = ${session.pid}
    for ($i = 0; $i -lt 12 -and $pid_; $i++) {
      $p = Get-Process -Id $pid_
      if ($p -and $p.MainWindowHandle -ne 0) {
        [W.U]::ShowWindow($p.MainWindowHandle, 9) | Out-Null
        [W.U]::SetForegroundWindow($p.MainWindowHandle) | Out-Null
        exit 0
      }
      $pid_ = (Get-CimInstance Win32_Process -Filter "ProcessId=$pid_").ParentProcessId
    }
    exit 1`;
  execFile('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', script], (err) => {
    // Nenhuma janela encontrada: abrir a pasta e o consolo possivel, e ainda
    // leva o usuario ao lugar certo.
    if (err && session.cwd) shell.openPath(session.cwd);
  });
}

// MARK: - Ciclo de vida

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
      `O transporte de eventos falhou.\n\n${err.message}\n\n`
      + 'Se outra copia do CodeStatus estiver rodando, feche-a.',
    );
  });

  daemon.start();

  tray = new Tray(buildIcon(latest.counts));
  refreshTray();
  refreshMenu();
  tray.on('click', showHUD);

  createHUD();

  // O tempo em cada estado e mostrado no HUD, entao ele precisa de um tique
  // proprio mesmo quando nada acontece.
  setInterval(() => { if (hud && hud.isVisible()) pushToHUD(); }, 1000);
});

ipcMain.on('focus-session', (_event, id) => {
  const session = daemon && daemon.registry.get(id);
  if (session) focusSession(session);
  if (hud) hud.hide();
});

ipcMain.on('install-hooks', () => doInstall());
ipcMain.on('close-hud', () => { if (hud) hud.hide(); });

app.on('window-all-closed', (e) => e.preventDefault());
app.on('before-quit', () => { if (daemon) daemon.stop(); });
