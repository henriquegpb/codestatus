'use strict';

// The popover's renderer.
//
// Builds every node with the DOM API rather than innerHTML. Nothing here is
// user-authored markup, but session names come from directory names on disk,
// and a folder is allowed to be called anything at all.

const surface = document.getElementById('surface');
const summaryEl = document.getElementById('summary');
const bodyInner = document.getElementById('bodyInner');

// Mirrors StateBucket ordering on macOS: what needs you, then what is working,
// then what is idle. The menu bar lists them in this order too.
const SUMMARY_GROUPS = [
  { key: 'needsYou', label: 'needs you', tint: 'var(--state-needs)' },
  { key: 'busy', label: 'busy', tint: 'var(--state-busy)' },
  { key: 'free', label: 'free', tint: 'var(--state-free)' },
  { key: 'indeterminate', label: 'unknown', tint: 'var(--text-disabled)' },
];

// Segoe Fluent Icons / Segoe MDL2 Assets code points, written as escapes: the
// literal characters are invisible in an editor and indistinguishable from each
// other in a diff.
const GLYPH = {
  close: '\uE711',
  warning: '\uE7BA',
  info: '\uE946',
};

const PROVIDER_NAMES = {
  claudeCode: 'Claude Code',
  codex: 'Codex',
  generic: 'Agent',
};

let latest = null;

// ------------------------------------------------------------------ helpers

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function glyph(code) {
  const node = el('span', 'glyph');
  node.textContent = code;
  node.setAttribute('aria-hidden', 'true');
  return node;
}

// Same shape as DurationFormatter.short on macOS: a duration you read at a
// glance, never more than two units.
function formatAge(since) {
  const seconds = Math.max(0, Math.round((Date.now() - since) / 1000));
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  return minutes > 0 ? `${hours}h ${minutes}m` : `${hours}h`;
}

// States where the clock would be meaningless: we do not know when a
// discovering or reconnecting session entered that state.
function showsDuration(state) {
  return state === 'free'
    || state === 'busy'
    || state === 'waitingForApproval'
    || state === 'waitingForInput'
    || state === 'failed';
}

// ------------------------------------------------------------------ summary

function renderSummary(data) {
  summaryEl.textContent = '';

  const groups = SUMMARY_GROUPS.filter((g) => (data.counts[g.key] || 0) > 0);

  if (groups.length === 0) {
    summaryEl.appendChild(el('span', 'idle', 'No agent sessions'));
    return;
  }

  for (const group of groups) {
    const wrap = el('span', 'group');
    const dot = el('span', 'dot');
    dot.style.background = group.tint;
    wrap.appendChild(dot);
    wrap.appendChild(el('span', 'count', String(data.counts[group.key])));
    wrap.appendChild(el('span', null, group.label));
    summaryEl.appendChild(wrap);
  }
}

// --------------------------------------------------------------------- rows

function renderSession(session) {
  const row = el('div', 'session');

  const dot = el('div', `dot ${session.state}`);
  row.appendChild(dot);

  const info = el('div', 'info');
  info.appendChild(el('div', 'name', session.name));

  const meta = el('div', 'meta');
  const provider = PROVIDER_NAMES[session.provider] || 'Agent';
  meta.appendChild(el('span', null, `${provider} · ${session.label}`));
  if (showsDuration(session.state)) {
    meta.appendChild(el('span', null, ' · '));
    const age = el('span', 'age', formatAge(session.since));
    age.dataset.since = String(session.since);
    meta.appendChild(age);
  }
  info.appendChild(meta);
  row.appendChild(info);

  const trailing = el('div', 'trailing');
  if (session.host) trailing.appendChild(el('span', 'host', session.host));

  const actions = el('div', 'actions');

  const open = el('button', 'row-button', 'Open');
  open.title = 'Bring this session’s window to the front';
  open.addEventListener('click', (e) => {
    e.stopPropagation();
    window.codestatus.focusSession(session.id);
  });
  actions.appendChild(open);

  const dismiss = el('button', 'row-button icon');
  dismiss.appendChild(glyph(GLYPH.close));
  dismiss.title = 'Stop watching this session';
  dismiss.addEventListener('click', (e) => {
    e.stopPropagation();
    window.codestatus.dismissSession(session.id);
  });
  actions.appendChild(dismiss);

  trailing.appendChild(actions);
  row.appendChild(trailing);

  row.addEventListener('click', () => window.codestatus.focusSession(session.id));
  return row;
}

// ----------------------------------------------------------------- messages

function renderNotConnected(providers) {
  const names = Object.keys(providers).map((p) => PROVIDER_NAMES[p] || p).sort().join(' and ');
  const callout = el('div', 'callout');
  callout.appendChild(glyph(GLYPH.warning));

  const text = el('div');
  text.appendChild(el('div', 'title', `${names} is running but not connected`));
  text.appendChild(el(
    'div',
    'detail',
    'CodeStatus has no hooks installed for it. Use Connect Claude Code below.',
  ));
  callout.appendChild(text);

  const connect = el('button', 'accent-button', 'Connect Claude Code');
  connect.addEventListener('click', () => window.codestatus.connect());

  const actions = el('div', 'callout-actions');
  actions.appendChild(connect);

  const wrap = el('div');
  wrap.appendChild(callout);
  wrap.appendChild(actions);
  return wrap;
}

// A count rather than rows: they are real, so hiding them would be its own
// dishonesty, but each is a session whose state we would have to invent. Almost
// always it means hooks were installed after the session started — Claude Code
// reads its hook configuration once, at session start — so the fix is to open a
// new one, and saying so is more useful than a row that reads Unknown for ever.
function renderFootnote(count) {
  const note = el('div', 'footnote');
  note.appendChild(glyph(GLYPH.info));
  note.appendChild(el(
    'span',
    null,
    count === 1
      ? '1 other session isn’t reporting yet'
      : `${count} other sessions aren’t reporting yet`,
  ));
  note.title = 'They started before hooks were installed. Claude Code reads its '
    + 'hook configuration at session start, so a new session will report normally.';
  return note;
}

function renderNotInstalled() {
  const empty = el('div', 'empty');
  empty.appendChild(el('div', 'lead', 'Not connected yet'));
  empty.appendChild(el(
    'div',
    null,
    'CodeStatus watches Claude Code through its lifecycle hooks. '
    + 'Nothing is observed until they are installed.',
  ));
  const button = el('button', 'accent-button', 'Connect Claude Code');
  button.addEventListener('click', () => window.codestatus.connect());
  empty.appendChild(button);
  return empty;
}

function renderEmpty(data) {
  const empty = el('div', 'empty');
  empty.appendChild(el('div', 'lead', 'No agent sessions'));
  empty.appendChild(el('div', null, 'Open Claude Code in a terminal and it will appear here.'));
  // Said out loud rather than swallowed: with the scan down we cannot tell an
  // idle machine from a running agent we failed to see, and claiming the former
  // would be exactly the kind of guess this app refuses to make.
  if (data.scanFailed) {
    empty.appendChild(el(
      'div',
      'detail',
      'Could not check for running agents on this machine.',
    ));
  }
  return empty;
}

// ------------------------------------------------------------------- render

function render(data) {
  latest = data;
  renderSummary(data);

  bodyInner.textContent = '';

  const diagnosis = data.diagnosis || { notConnected: {}, predatesHooks: 0, unexplained: 0 };
  const notConnected = diagnosis.notConnected || {};
  const unexplained = (diagnosis.predatesHooks || 0) + (diagnosis.unexplained || 0);

  if (!data.installed && data.sessions.length === 0) {
    bodyInner.appendChild(renderNotInstalled());
  } else if (data.sessions.length === 0 && Object.keys(notConnected).length === 0) {
    bodyInner.appendChild(renderEmpty(data));
  } else {
    data.sessions.forEach((session, index) => {
      if (index > 0) bodyInner.appendChild(el('div', 'divider'));
      bodyInner.appendChild(renderSession(session));
    });
  }

  // Before the footnote, because it is the more fundamental problem: there is
  // nothing in the config file to report through.
  if (Object.keys(notConnected).length > 0) {
    bodyInner.appendChild(renderNotConnected(notConnected));
  }
  if (unexplained > 0) {
    if (data.sessions.length > 0) bodyInner.appendChild(el('div', 'divider'));
    bodyInner.appendChild(renderFootnote(unexplained));
  }

  measure();
}

// The window hugs its content, the way the macOS popover does.
//
// Measured from the inner wrapper rather than the scroller, and after layout
// has settled: the first frame still reports the previous size, and a scroller
// that has already been stretched reports its own height rather than its
// content's, which would let the popover grow and never shrink.
const BODY_PADDING = 8; // 4px top and bottom, from .body
const BODY_MAX = 520; // .body's max-height

function measure() {
  requestAnimationFrame(() => {
    const content = bodyInner.getBoundingClientRect().height + BODY_PADDING;
    const total = summaryEl.offsetHeight
      + Math.min(content, BODY_MAX)
      + document.querySelector('.footer').offsetHeight
      + 2; // the surface's own border
    window.codestatus.reportHeight(Math.ceil(total));
  });
}

// -------------------------------------------------------------------- ticks

// Only the durations change between events, so the tick rewrites those and
// nothing else — a full re-render every second would drop the hover state and
// make the action buttons unclickable.
setInterval(() => {
  if (!latest) return;
  for (const node of bodyInner.querySelectorAll('.age')) {
    node.textContent = formatAge(Number(node.dataset.since));
  }
}, 1000);

// ------------------------------------------------------------------ actions

const refreshButton = document.getElementById('refresh');
refreshButton.addEventListener('click', () => {
  window.codestatus.refresh();
  refreshButton.classList.remove('acknowledging');
  // Reading offsetWidth forces the class removal to take effect before it is
  // added back, so a second click restarts the animation instead of ignoring it.
  void refreshButton.offsetWidth;
  refreshButton.classList.add('acknowledging');
});
refreshButton.addEventListener('animationend', () => {
  refreshButton.classList.remove('acknowledging');
});

document.getElementById('settings').addEventListener('click', () => window.codestatus.openSettings());
document.getElementById('quit').addEventListener('click', () => window.codestatus.quit());

document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') window.codestatus.close();
});

window.codestatus.onState(render);
window.codestatus.onTheme(({ theme, accent, acrylic }) => {
  document.documentElement.dataset.theme = theme;
  document.documentElement.dataset.acrylic = acrylic ? '1' : '0';
  if (accent) document.documentElement.style.setProperty('--accent', accent);
});

// The surface can change height without new state — a hover that reveals a
// wider action row, or a font that finishes loading.
new ResizeObserver(() => measure()).observe(surface);
