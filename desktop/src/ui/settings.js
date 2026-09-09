'use strict';

const PREF_TOGGLES = [
  'notifyWhenNeeded',
  'notifyOnCompletion',
  'soundEnabled',
  'scanForUnreported',
];

const openAtLogin = document.getElementById('openAtLogin');
const openAtLoginLabel = document.getElementById('openAtLoginLabel');
const hookStatus = document.getElementById('hookStatus');
const hookDetail = document.getElementById('hookDetail');
const connectToggle = document.getElementById('connectToggle');
const settingsPath = document.getElementById('settingsPath');
const scanDetail = document.getElementById('scanDetail');
const focusCard = document.getElementById('focusCard');
const focusDetail = document.getElementById('focusDetail');
const about = document.getElementById('about');
const runtime = document.getElementById('runtime');

// The renderer is sandboxed and has no process object, so the platform arrives
// with the state. Everything it changes is wording — the two builds have the
// same controls, and only the names for things differ.
let platform = 'win32';
let installed = false;

for (const key of PREF_TOGGLES) {
  const input = document.getElementById(key);
  input.addEventListener('change', () => window.codestatus.setPref(key, input.checked));
}

openAtLogin.addEventListener('change', () => {
  window.codestatus.setOpenAtLogin(openAtLogin.checked);
});

connectToggle.addEventListener('click', () => {
  if (installed) window.codestatus.disconnect();
  else window.codestatus.connect();
});

document.getElementById('openFile').addEventListener('click', () => {
  window.codestatus.openSettingsFile();
});

document.getElementById('close').addEventListener('click', () => window.codestatus.close());
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') window.codestatus.close();
});

function render(state) {
  for (const key of PREF_TOGGLES) {
    document.getElementById(key).checked = Boolean(state.prefs[key]);
  }
  openAtLogin.checked = Boolean(state.openAtLogin);

  platform = state.platform || 'win32';
  const onLinux = platform === 'linux';

  openAtLoginLabel.textContent = onLinux ? 'Start with your session' : 'Start with Windows';

  // The same switch, and two very different costs behind it. On Windows the
  // scan is a PowerShell pass over the whole process table; on Linux it is a
  // walk over /proc with no subprocess at all. Saying "a few hundred
  // milliseconds" on a machine where it takes three would be a reason to leave
  // a useful thing turned off.
  scanDetail.textContent = onLinux
    ? 'Reads /proc every 20 seconds so the app can tell an idle machine from an '
      + 'agent it cannot see. Costs almost nothing.'
    : 'Scans the process list every 20 seconds so the app can tell an idle '
      + 'machine from an agent it cannot see. Costs a few hundred milliseconds '
      + 'each time.';

  // Only shown when there is something to say. A session that can raise a
  // terminal gets no reassurance about a thing that simply works.
  focusCard.hidden = !state.focusLimitation;
  focusDetail.textContent = state.focusLimitation || '';

  installed = state.hooks.installed;
  hookStatus.textContent = installed ? 'Connected' : 'Not connected';
  connectToggle.textContent = installed ? 'Disconnect' : 'Connect';
  connectToggle.classList.toggle('danger', installed);

  if (state.hooks.problems.length > 0) {
    hookDetail.textContent = state.hooks.problems.join(' ');
  } else if (installed) {
    hookDetail.textContent = `${state.hooks.events} lifecycle events registered. `
      + 'Only our own entries are ever touched, and your file is backed up first.';
  } else {
    hookDetail.textContent = 'Writes CodeStatus’s hooks into your Claude Code '
      + 'settings, with a backup first.';
  }

  settingsPath.textContent = state.hooks.settingsPath;
  settingsPath.className = 'detail mono';

  about.textContent = `CodeStatus for ${onLinux ? 'Linux' : 'Windows'} ${state.version}`;
  runtime.textContent = state.hooks.runtime;
}

window.codestatus.onState(render);
window.codestatus.onTheme(({ theme, accent, acrylic }) => {
  document.documentElement.dataset.theme = theme;
  document.documentElement.dataset.acrylic = acrylic ? '1' : '0';
  if (accent) document.documentElement.style.setProperty('--accent', accent);
});
