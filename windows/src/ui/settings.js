'use strict';

const PREF_TOGGLES = [
  'notifyWhenNeeded',
  'notifyOnCompletion',
  'soundEnabled',
  'scanForUnreported',
];

const openAtLogin = document.getElementById('openAtLogin');
const hookStatus = document.getElementById('hookStatus');
const hookDetail = document.getElementById('hookDetail');
const connectToggle = document.getElementById('connectToggle');
const settingsPath = document.getElementById('settingsPath');
const about = document.getElementById('about');

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

  about.textContent = `CodeStatus for Windows ${state.version} · Node ${state.hooks.nodePath}`;
}

window.codestatus.onState(render);
window.codestatus.onTheme(({ theme, accent, acrylic }) => {
  document.documentElement.dataset.theme = theme;
  document.documentElement.dataset.acrylic = acrylic ? '1' : '0';
  if (accent) document.documentElement.style.setProperty('--accent', accent);
});
