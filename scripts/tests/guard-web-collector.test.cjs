'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
delete process.env.CLAUDE_NOTCH_WEB_GUARD_SESSION;
const { frameLabel, sanitize, start, PROBE, localeFromArguments, localeGuard } = require('../../Sources/ClaudeNotch/Resources/Guard/claude-notch-webguard.cjs');
const main = '/Example/Claude.app/Contents/Resources/app.asar/.vite/renderer/main_window/index.html';
const values = { language: 'en-US', languages: ['en-US', 'en'], locale: 'en-US', timeZone: 'America/Los_Angeles' };
const session = 'a'.repeat(32);

function harness(frames, mode = 0o700) {
  let report;
  const disk = {
    mkdirSync() {}, lstatSync() { return { isDirectory: () => true, isSymbolicLink: () => false, uid: process.getuid(), mode }; },
    openSync(file, flags) { assert.ok(flags & require('node:fs').constants.O_NOFOLLOW); return 10; },
    fchmodSync(fd, permissions) { assert.equal(permissions, 0o600); },
    writeFileSync(fd, body) { report = JSON.parse(body); }, closeSync() {}, renameSync() {}
  };
  const app = new EventEmitter();
  app.getAppPath = () => '/Example/Claude.app/Contents/Resources/app.asar';
  app.whenReady = () => new Promise(() => {});
  const contents = new EventEmitter();
  contents.isDestroyed = () => false;
  contents.mainFrame = { framesInSubtree: frames };
  const owner = { isDestroyed: () => false, isVisible: () => true, isMinimized: () => false };
  const collector = start({ app, webContents: { getAllWebContents: () => [contents] }, BrowserWindow: { fromWebContents: () => owner } }, session,
    { fs: disk, directory: '/private-test/ClaudeNotch/Guard' });
  return { collector, report: () => report };
}
function frame(url, id, result = values) {
  return { url, frameTreeNodeId: id, executeJavaScript: async (expression, gesture) => {
    assert.equal(expression, PROBE); assert.equal(gesture, false); return result;
  } };
}

test('only actual Claude origins and exact local main page are eligible', () => {
  assert.equal(frameLabel('https://claude.ai/chat/private-id', main), 'claude.ai');
  assert.equal(frameLabel('https://claude.ai:443/', main), 'claude.ai');
  assert.equal(frameLabel('file://' + main, main), 'Claude Desktop');
  for (const url of ['https://claude.ai.evil/', 'http://claude.ai/', 'https://evil/claude.ai', 'https://claude.ai:444/', 'file://' + main + '.backup']) {
    assert.equal(frameLabel(url, main), null);
  }
});
test('only the four explicit page values survive sanitization', () => {
  assert.deepEqual(sanitize({ ...values, cookie: 'must-not-leak', chat: 'must-not-leak' }), values);
  assert.equal(sanitize({ ...values, language: '' }), null);
  assert.equal(sanitize({ ...values, languages: [] }), null);
  assert.equal(sanitize({ ...values, timeZone: 'a'.repeat(129) }), null);
  assert.ok(!/document|cookie|localStorage|sessionStorage/.test(PROBE));
});
test('remote actual page takes precedence over the local shell, URLs are never persisted', async () => {
  const value = harness([frame('file://' + main, 1), frame('https://claude.ai/chat/private-id', 2), frame('https://evil/', 3)]);
  await value.collector.collect(); value.collector.stop();
  assert.equal(value.report().candidateCount, 1);
  assert.equal(value.report().frames[0].context, 'claude.ai');
  assert.equal(value.report().session, session);
  assert.ok(!JSON.stringify(value.report()).includes('private-id'));
});
test('local main window is sampled when it is the actual Claude UI', async () => {
  const value = harness([frame('file://' + main, 1)]);
  await value.collector.collect(); value.collector.stop();
  assert.equal(value.report().frames[0].context, 'Claude Desktop');
});
test('a failed page prevents a partial sample being presented as complete', async () => {
  const broken = frame('https://claude.ai/', 2);
  broken.executeJavaScript = async () => { throw new Error('private exception must not leak'); };
  const value = harness([frame('https://claude.ai/', 1), broken]);
  await value.collector.collect(); value.collector.stop();
  assert.equal(value.report().candidateCount, 2);
  assert.equal(value.report().failedCount, 1);
  assert.equal(value.report().frames.length, 1);
  assert.ok(!JSON.stringify(value.report()).includes('exception'));
});
test('navigation during a probe discards the sampled value', async () => {
  const moving = frame('https://claude.ai/', 1);
  moving.executeJavaScript = async () => { moving.url = 'https://evil/'; return values; };
  const value = harness([moving]);
  await value.collector.collect(); value.collector.stop();
  assert.equal(value.report().frames.length, 0);
  assert.equal(value.report().failedCount, 1);
});
test('no page is represented as pending rather than a passing empty sample', async () => {
  const value = harness([frame('https://evil/', 1)]);
  await value.collector.collect(); value.collector.stop();
  assert.equal(value.report().candidateCount, 0);
  assert.deepEqual(value.report().frames, []);
});
test('world-readable directories reject report writes', async () => {
  const value = harness([frame('https://claude.ai/', 1)], 0o755);
  await value.collector.collect(); value.collector.stop();
  assert.equal(value.report(), undefined);
});
test('invalid session leaves the collector dormant', () => {
  assert.equal(start({}, ''), null);
  assert.equal(start({}, 'A'.repeat(32)), null);
});
test('more than eight candidate pages is explicitly incomplete', async () => {
  const value = harness(Array.from({ length: 9 }, (_, i) => frame('https://claude.ai/', i)));
  await value.collector.collect(); value.collector.stop();
  assert.equal(value.report().frames.length, 8);
  assert.equal(value.report().failedCount, 1);
  assert.equal(value.report().candidateCount, 9);
});

function localeHarness({ attached = false, fail = false, devtools = false, url = 'https://claude.ai/' } = {}) {
  const commands = [];
  const debuggerAPI = new EventEmitter();
  let detachCount = 0;
  debuggerAPI.isAttached = () => attached;
  debuggerAPI.attach = version => { assert.equal(version, '1.3'); attached = true; };
  debuggerAPI.detach = () => { attached = false; detachCount++; debuggerAPI.emit('detach', {}, 'test'); };
  debuggerAPI.sendCommand = async (...args) => { commands.push(args); if (fail) throw new Error('unsupported'); return {}; };
  const contents = { isDestroyed: () => false, isDevToolsOpened: () => devtools,
    debugger: debuggerAPI, mainFrame: { url, processId: 42 } };
  return { contents, commands, debuggerAPI, detachCount: () => detachCount };
}

test('locale target is read from explicit launch settings and validated as data', () => {
  assert.equal(localeFromArguments(['Claude', '--lang=en-US', '-AppleLocale', 'en_TR']), 'en_TR');
  assert.equal(localeFromArguments(['Claude', '-AppleLocale', 'en-US']), 'en_US');
  for (const args of [[], ['-AppleLocale'], ['-AppleLocale', '";evil()'], ['-AppleLocale', 'invalid_locale_value']]) {
    assert.equal(localeFromArguments(args), null);
  }
});

test('native locale override is independent of navigator language and no remote protocol domains are enabled', async () => {
  const h = localeHarness();
  const guard = localeGuard('en_TR', main);
  assert.equal(await guard.prepare(h.contents), true);
  assert.deepEqual(h.commands, [['Emulation.setLocaleOverride', { locale: 'en_TR' }]]);
  assert.equal(await guard.prepare(h.contents), true);
  assert.equal(h.commands.length, 1);
  guard.stop();
  assert.equal(h.detachCount(), 1);
});

test('unconfigured launches, unrelated pages and another debugger remain untouched', async () => {
  for (const options of [{ attached: true }, { devtools: true }, { url: 'https://example.com/' }]) {
    const h = localeHarness(options);
    const guard = localeGuard('en_TR', main);
    assert.equal(await guard.prepare(h.contents), false);
    guard.stop();
    assert.equal(h.commands.length, 0);
    assert.equal(h.detachCount(), 0);
  }
  const h = localeHarness();
  assert.equal(await localeGuard(null, main).prepare(h.contents), false);
  assert.equal(h.commands.length, 0);
});

test('failed native setting remains a failure and does not modify sampled report values', async () => {
  const h = localeHarness({ fail: true });
  const guard = localeGuard('en_TR', main);
  assert.equal(await guard.prepare(h.contents), false);
  assert.equal(await guard.prepare(h.contents), false);
  assert.equal(h.commands.length, 2);
  assert.equal(sanitize(values).locale, 'en-US');
  assert.ok(!/en_TR|setLocaleOverride|defineProperty/.test(PROBE));
  guard.stop();
});

test('new renderer and debugger detach invalidate the previous application', async () => {
  const h = localeHarness();
  const guard = localeGuard('en_TR', main);
  assert.equal(await guard.prepare(h.contents), true);
  h.contents.mainFrame.processId = 43;
  assert.equal(await guard.prepare(h.contents), true);
  h.debuggerAPI.detach();
  assert.equal(await guard.prepare(h.contents), true);
  assert.equal(h.commands.length, 3);
  guard.stop();
  assert.equal(await guard.prepare(h.contents), false);
});

test('concurrent sampling shares one native application command', async () => {
  const h = localeHarness();
  const guard = localeGuard('en_TR', main);
  const results = await Promise.all([guard.prepare(h.contents), guard.prepare(h.contents)]);
  assert.deepEqual(results, [true, true]);
  assert.equal(h.commands.length, 1);
  guard.stop();
});
