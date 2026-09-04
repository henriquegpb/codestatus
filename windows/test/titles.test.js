'use strict';

// The name a session gets, and what happens when the agent has not given it
// one. Runs on any platform: the reader is plain fs work against the agents'
// own stores, and the layout of those stores is the same everywhere.

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

const { test, run } = require('./harness');

const { SessionTitleReader } = require('../src/platform/titles');
const { gitRoot } = require('../src/platform/workspace');
const {
  makeSession, displayName, primaryLabel, secondaryLabel, announcement,
} = require('../src/core/session');
const { SessionRegistry } = require('../src/core/registry');
const { AgentProvider, HostApplication } = require('../src/core/events');
const { AgentState } = require('../src/core/state');

// A throwaway home laid out the way the agents lay theirs out, so the reader
// is exercised against the real shape rather than a stand-in.
function makeTestHome() {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'cs-titles-'));
  fs.mkdirSync(path.join(home, '.claude', 'projects'), { recursive: true });
  fs.mkdirSync(path.join(home, '.codex'), { recursive: true });
  return home;
}

function readerFor(home) {
  return new SessionTitleReader({
    claudeProjects: path.join(home, '.claude', 'projects'),
    codexSessionIndex: path.join(home, '.codex', 'session_index.jsonl'),
  });
}

function writeTranscript(home, slug, sessionID, lines) {
  const directory = path.join(home, '.claude', 'projects', slug);
  fs.mkdirSync(directory, { recursive: true });
  const file = path.join(directory, `${sessionID}.jsonl`);
  fs.writeFileSync(file, `${lines.join('\n')}\n`, 'utf8');
  return file;
}

function titleRecord(title, session) {
  return JSON.stringify({ type: 'custom-title', customTitle: title, sessionId: session });
}

// A user record big enough to push earlier lines out of a tail read.
function filler(bytes) {
  return JSON.stringify({ type: 'user', text: 'x'.repeat(bytes) });
}

// --- Claude Code transcripts -------------------------------------------------

test('The last custom-title in a transcript wins', () => {
  const home = makeTestHome();
  const session = '11111111-2222-3333-4444-555555555555';
  writeTranscript(home, '-Users-x-repo', session, [
    JSON.stringify({ type: 'user', text: 'hello' }),
    titleRecord('First guess', session),
    titleRecord('Renamed by hand', session),
  ]);

  assert.strictEqual(readerFor(home).title(AgentProvider.claudeCode, session), 'Renamed by hand');
});

test('A title is found without reading more than the tail of a huge transcript', () => {
  const home = makeTestHome();
  const session = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';

  const lines = [titleRecord('Buried and stale', session)];
  for (let i = 0; i < 32; i += 1) lines.push(filler(64 * 1024));
  lines.push(titleRecord('Near the end', session));
  lines.push(filler(8 * 1024));
  const file = writeTranscript(home, '-Users-x-big', session, lines);

  assert.ok(fs.statSync(file).size > 2_000_000, 'the fixture should be genuinely large');
  assert.strictEqual(readerFor(home).title(AgentProvider.claudeCode, session), 'Near the end');
});

test('A title older than the tail window is not found rather than guessed at', () => {
  const home = makeTestHome();
  const session = '99999999-8888-7777-6666-555555555555';

  const lines = [titleRecord('Long gone', session)];
  for (let i = 0; i < 4; i += 1) lines.push(filler(64 * 1024));
  writeTranscript(home, '-Users-x-old', session, lines);

  assert.strictEqual(readerFor(home).title(AgentProvider.claudeCode, session), null);
});

test('A transcript that grows is re-read, and one that does not is not', () => {
  const home = makeTestHome();
  const session = '12121212-3434-5656-7878-909090909090';
  const file = writeTranscript(home, '-Users-x-grow', session, [titleRecord('Before', session)]);

  const reader = readerFor(home);
  assert.strictEqual(reader.title(AgentProvider.claudeCode, session), 'Before');

  // Deleting the file behind the reader's back proves the next answer came
  // from disk and not from the cache.
  fs.unlinkSync(file);
  assert.strictEqual(reader.title(AgentProvider.claudeCode, session), null);

  writeTranscript(home, '-Users-x-grow', session, [
    titleRecord('Before', session),
    titleRecord('After', session),
  ]);
  assert.strictEqual(reader.title(AgentProvider.claudeCode, session), 'After');
});

test('A session with no title anywhere reads as null rather than as an error', () => {
  const home = makeTestHome();
  writeTranscript(home, '-Users-x-quiet', 'known', [JSON.stringify({ type: 'user', text: 'hi' })]);

  const reader = readerFor(home);
  assert.strictEqual(reader.title(AgentProvider.claudeCode, 'known'), null);
  assert.strictEqual(reader.title(AgentProvider.claudeCode, 'never-existed'), null);
  assert.strictEqual(reader.title(AgentProvider.generic, 'known'), null);
  assert.strictEqual(reader.title(AgentProvider.claudeCode, null), null);
});

test('A truncated or malformed transcript yields no title instead of throwing', () => {
  const home = makeTestHome();
  const session = 'dddddddd-dddd-dddd-dddd-dddddddddddd';
  writeTranscript(home, '-Users-x-broken', session, [
    'not json at all',
    '{"type":"custom-title","customTitle":"unterminated',
    '{"type":"custom-title"}',
  ]);

  assert.strictEqual(readerFor(home).title(AgentProvider.claudeCode, session), null);
});

test('Pruning drops the cache for sessions that have ended', () => {
  const home = makeTestHome();
  const session = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee';
  const file = writeTranscript(home, '-Users-x-prune', session, [titleRecord('Cached', session)]);

  const reader = readerFor(home);
  assert.strictEqual(reader.title(AgentProvider.claudeCode, session), 'Cached');

  reader.prune(new Set());
  fs.unlinkSync(file);
  assert.strictEqual(reader.title(AgentProvider.claudeCode, session), null);
});

// --- Codex -------------------------------------------------------------------

test('Codex names come from the session index, last entry winning', () => {
  const home = makeTestHome();
  fs.writeFileSync(path.join(home, '.codex', 'session_index.jsonl'), [
    '{"id":"01a0-first","thread_name":"Corrigir salvamento","updated_at":"2026-03-12T22:19:47Z"}',
    '{"id":"01a0-second","thread_name":"Explique DDL e DML","updated_at":"2026-03-15T20:27:59Z"}',
    '{"id":"01a0-first","thread_name":"Renamed later","updated_at":"2026-03-16T09:00:00Z"}',
    'half a line that never finished',
  ].join('\n'), 'utf8');

  const reader = readerFor(home);
  assert.strictEqual(reader.title(AgentProvider.codex, '01a0-first'), 'Renamed later');
  assert.strictEqual(reader.title(AgentProvider.codex, '01a0-second'), 'Explique DDL e DML');
  // A `codex exec` run never reaches the index.
  assert.strictEqual(reader.title(AgentProvider.codex, '01a0-unindexed'), null);
});

test('A missing Codex index is not an error', () => {
  const home = makeTestHome();
  assert.strictEqual(readerFor(home).title(AgentProvider.codex, 'anything'), null);
});

// --- what the row shows ------------------------------------------------------

function sessionWith(overrides) {
  const session = makeSession({
    id: 'claudeCode:s1',
    provider: AgentProvider.claudeCode,
    now: 1_700_000_000_000,
    sourceAdapter: 'claudeCodeHook',
  });
  return Object.assign(session, overrides);
}

test('A session with no title keeps the repository name it has today', () => {
  const session = sessionWith({
    cwd: path.join('C:', 'src', 'backend', 'packages', 'api'),
    repositoryName: 'backend',
  });

  assert.strictEqual(primaryLabel(session), 'backend');
  assert.strictEqual(secondaryLabel(session), null);

  session.sessionTitle = 'Calendar fix';
  assert.strictEqual(primaryLabel(session), 'Calendar fix');
  assert.strictEqual(secondaryLabel(session), 'backend');
  // The name every export path still uses must not have moved.
  assert.strictEqual(displayName(session), 'backend');
});

test('An empty title is treated as no title', () => {
  const session = sessionWith({ repositoryName: 'backend', sessionTitle: '' });
  assert.strictEqual(primaryLabel(session), 'backend');
  assert.strictEqual(secondaryLabel(session), null);
  assert.strictEqual(announcement(session, 'Finished.'), 'Finished.');
});

test('A toast names the repository first and the session second', () => {
  const session = sessionWith({ repositoryName: 'backend' });

  // Untitled, the toast reads exactly as it did before this existed.
  assert.strictEqual(announcement(session, 'Waiting for your approval.'),
    'Waiting for your approval.');

  session.sessionTitle = 'Situação da infraestrutura WAHA';
  assert.strictEqual(announcement(session, 'Waiting for your approval.'),
    'Situação da infraestrutura WAHA — Waiting for your approval.');
  // The line the toast leads with stays the repository.
  assert.strictEqual(displayName(session), 'backend');
});

test('The session title never reaches the snapshot on disk', () => {
  const registry = new SessionRegistry();
  const session = sessionWith({
    state: AgentState.free,
    repositoryName: 'backend',
    sessionTitle: 'Something the model wrote about the user',
    hostApplication: HostApplication.unknown,
  });
  registry.sessions.set(session.id, session);

  const snapshot = registry.toJSON();
  assert.strictEqual(snapshot.sessions.length, 1);
  assert.ok(!('sessionTitle' in snapshot.sessions[0]), 'sessionTitle must not be persisted');
  assert.strictEqual(snapshot.sessions[0].repositoryName, 'backend');
  assert.ok(!JSON.stringify(snapshot).includes('the model wrote'));
});

// --- the repository a session sits in ----------------------------------------

test('The repository walk finds the root from a directory deep inside it', () => {
  const home = makeTestHome();
  const root = path.join(home, 'checkout');
  const deep = path.join(root, 'packages', 'api', 'src');
  fs.mkdirSync(deep, { recursive: true });
  fs.mkdirSync(path.join(root, '.git'));

  assert.strictEqual(gitRoot(deep), root);
  assert.strictEqual(path.basename(gitRoot(deep)), 'checkout');
});

test('A worktree, whose .git is a file, is still a repository', () => {
  const home = makeTestHome();
  const root = path.join(home, 'worktree');
  fs.mkdirSync(root, { recursive: true });
  fs.writeFileSync(path.join(root, '.git'), 'gitdir: /elsewhere/.git/worktrees/wt\n', 'utf8');

  assert.strictEqual(gitRoot(root), root);
});

test('A directory in no repository at all walks out rather than up forever', () => {
  assert.strictEqual(gitRoot(path.parse(process.cwd()).root), null);
  assert.strictEqual(gitRoot(null), null);
});

run('Session titles');
