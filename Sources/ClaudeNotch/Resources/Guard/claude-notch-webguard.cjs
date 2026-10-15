'use strict';
// Claude Notch web environment guard, protocol v1. No remote port or DOM/storage access.
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { fileURLToPath } = require('node:url');
const SESSION_KEY = 'CLAUDE_NOTCH_WEB_GUARD_SESSION';
const PROBE = `(() => {
  const options = new Intl.DateTimeFormat().resolvedOptions();
  return { language: navigator.language, languages: Array.from(navigator.languages),
           locale: options.locale, timeZone: options.timeZone };
})()`;

function frameLabel(raw, mainFile) {
  try {
    const url = new URL(raw);
    if (url.protocol === 'https:' && url.hostname === 'claude.ai' && (!url.port || url.port === '443')) return 'claude.ai';
    if (url.protocol === 'file:' && path.normalize(fileURLToPath(url)) === mainFile) return 'Claude Desktop';
  } catch {}
  return null;
}
function sanitize(value) {
  const text = (item, max) => typeof item === 'string' && item.length > 0 && item.length <= max && !/[\x00-\x1f]/.test(item);
  if (!value || !text(value.language, 64) || !text(value.locale, 64) || !text(value.timeZone, 128) ||
      !Array.isArray(value.languages) || value.languages.length < 1 || value.languages.length > 16 ||
      !value.languages.every(item => text(item, 64))) return null;
  return { language: value.language, languages: value.languages, locale: value.locale, timeZone: value.timeZone };
}

function localeFromArguments(args) {
  const index = args.lastIndexOf('-AppleLocale');
  const value = index >= 0 ? args[index + 1] : null;
  if (typeof value !== 'string' || !/^[a-zA-Z]{2,3}(?:[-_][a-zA-Z0-9]{2,8}){1,3}$/.test(value)) return null;
  try { return Intl.getCanonicalLocales(value.replaceAll('_', '-'))[0].replaceAll('-', '_'); }
  catch { return null; }
}

// Chromium's default Intl locale follows --lang, independently of macOS AppleLocale.
// Set the renderer's native ICU default through Electron's in-process API, then
// continue sampling the unmodified Intl/navigator APIs. Never replace a report value.
function localeGuard(locale, mainFile) {
  const records = new WeakMap();
  const owned = new Set();
  let stopped = false;
  function prepare(contents, navigatingURL) {
    if (stopped || !locale || contents.isDestroyed()) return Promise.resolve(false);
    let raw, processID;
    try {
      raw = navigatingURL || contents.mainFrame.url;
      processID = contents.mainFrame.processId;
    } catch { return Promise.resolve(false); }
    if (!frameLabel(raw, mainFile)) return Promise.resolve(false);
    const debuggerAPI = contents.debugger;
    if (!debuggerAPI || contents.isDevToolsOpened?.()) return Promise.resolve(false);
    let record = records.get(contents);
    if (!record) {
      record = { owned: false, ready: false, processID: null, pending: null, generation: 0 };
      records.set(contents, record);
      debuggerAPI.on('detach', () => {
        record.owned = false; record.ready = false; record.generation++;
        owned.delete(contents);
      });
    }
    if (record.pending) return record.pending;
    if (record.ready && record.processID === processID && debuggerAPI.isAttached()) return Promise.resolve(true);
    try {
      if (debuggerAPI.isAttached() && !record.owned) return Promise.resolve(false);
      if (!debuggerAPI.isAttached()) { debuggerAPI.attach('1.3'); record.owned = true; owned.add(contents); }
    } catch { return Promise.resolve(false); }
    const generation = record.generation;
    record.pending = (async () => {
      let timeout;
      try {
        await Promise.race([
          Promise.resolve().then(() => debuggerAPI.sendCommand('Emulation.setLocaleOverride', { locale })),
          new Promise((_, reject) => { timeout = setTimeout(() => reject(new Error('locale timeout')), 1500); timeout.unref?.(); })
        ]);
        if (stopped || record.generation !== generation || !debuggerAPI.isAttached()) return false;
        record.ready = true; record.processID = processID;
        return true;
      } catch { record.ready = false; return false; }
      finally { clearTimeout(timeout); record.pending = null; }
    })();
    return record.pending;
  }
  function stop() {
    stopped = true;
    for (const contents of owned) {
      try { if (!contents.isDestroyed() && contents.debugger.isAttached()) contents.debugger.detach(); } catch {}
    }
    owned.clear();
  }
  return { prepare, stop };
}

function start(electron, session, dependencies = {}) {
  if (!/^[a-f0-9]{32}$/.test(session || '')) return null;
  const { app, webContents, BrowserWindow } = electron;
  const disk = dependencies.fs || fs;
  const directory = dependencies.directory || path.join(os.homedir(), 'Library', 'Application Support', 'ClaudeNotch', 'Guard');
  const mainFile = path.normalize(path.join(app.getAppPath(), '.vite', 'renderer', 'main_window', 'index.html'));
  const locale = localeFromArguments(dependencies.argv || process.argv);
  const regionGuard = localeGuard(locale, mainFile);
  const destination = path.join(directory, 'web-environment.json');
  const temporary = path.join(directory, 'web-environment.tmp');
  let stopped = false;
  let busy = false;
  let pending = false;
  let timer;
  let debounce;
  const watched = new WeakSet();

  function write(report) {
    try {
      const parent = path.dirname(directory);
      for (const folder of [parent, directory]) {
        disk.mkdirSync(folder, { recursive: true, mode: 0o700 });
        const info = disk.lstatSync(folder);
        if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== process.getuid() || (info.mode & 0o077)) return;
      }
      const data = JSON.stringify(report);
      if (Buffer.byteLength(data) > 32768) return;
      const fd = disk.openSync(temporary, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_TRUNC | fs.constants.O_NOFOLLOW, 0o600);
      try { disk.fchmodSync(fd, 0o600); disk.writeFileSync(fd, data, 'utf8'); }
      finally { disk.closeSync(fd); }
      disk.renameSync(temporary, destination);
    } catch {} // Diagnostics must never prevent Claude from starting or quitting.
  }
  function watch(contents) {
    if (watched.has(contents)) return;
    watched.add(contents);
    contents.on('did-frame-finish-load', schedule);
    contents.on('did-start-navigation', (_, url, _inPlace, isMainFrame) => {
      if (isMainFrame !== false) void regionGuard.prepare(contents, url);
    });
    contents.on('dom-ready', () => { void regionGuard.prepare(contents); schedule(); });
    contents.on('devtools-closed', () => { void regionGuard.prepare(contents); schedule(); });
    contents.on('did-navigate-in-page', schedule);
    contents.on('render-process-gone', schedule);
    contents.on('destroyed', schedule);
  }
  function schedule() {
    if (stopped) return;
    clearTimeout(debounce);
    debounce = setTimeout(() => { void collect(); }, 300);
    debounce.unref?.();
  }
  async function collect() {
    if (stopped) return;
    if (busy) { pending = true; return; }
    busy = true;
    try {
      let candidates = [];
      for (const contents of webContents.getAllWebContents()) {
        if (contents.isDestroyed()) continue;
        watch(contents);
        const owner = BrowserWindow.fromWebContents(contents) || (contents.hostWebContents && BrowserWindow.fromWebContents(contents.hostWebContents));
        if (!owner || owner.isDestroyed() || (!owner.isVisible() && !owner.isMinimized())) continue;
        try {
          for (const frame of contents.mainFrame.framesInSubtree) {
            const label = frameLabel(frame.url, mainFile);
            if (label) candidates.push({ frame, label, url: frame.url, contents });
          }
        } catch {}
      }
      // The remote Claude page takes precedence over its local shell in the same visible UI.
      const hasRemote = candidates.some(item => item.label === 'claude.ai');
      if (hasRemote) candidates = candidates.filter(item => item.label === 'claude.ai');
      const unique = new Map(candidates.map(item => [item.frame.frameTreeNodeId, item]));
      candidates = Array.from(unique.values());
      const frames = [];
      let failed = Math.max(0, candidates.length - 8);
      for (const candidate of candidates.slice(0, 8)) {
        let timeout;
        try {
          await regionGuard.prepare(candidate.contents, candidate.url);
          const value = await Promise.race([
            candidate.frame.executeJavaScript(PROBE, false),
            new Promise((_, reject) => { timeout = setTimeout(() => reject(new Error('timeout')), 2000); timeout.unref?.(); })
          ]);
          // Discard a response if navigation changed the actual page while the probe ran.
          const clean = sanitize(value);
          if (!clean || candidate.frame.url !== candidate.url) { failed++; continue; }
          frames.push({ context: candidate.label, ...clean });
        } catch { failed++; }
        finally { clearTimeout(timeout); }
      }
      if (!stopped) write({ protocol: 1, session, pid: process.pid, capturedAt: Date.now(),
                            candidateCount: candidates.length, failedCount: failed, frames });
    } catch {
      if (!stopped) write({ protocol: 1, session, pid: process.pid, capturedAt: Date.now(), candidateCount: 0, failedCount: 1, frames: [] });
    } finally {
      busy = false;
      if (pending) { pending = false; schedule(); }
    }
  }
  function stop() { stopped = true; clearTimeout(debounce); clearInterval(timer); regionGuard.stop(); }
  app.on('web-contents-created', (_, contents) => { watch(contents); schedule(); });
  app.on('browser-window-focus', schedule);
  app.once('before-quit', stop);
  app.whenReady().then(() => {
    if (stopped) return;
    void collect();
    timer = setInterval(() => { void collect(); }, 30000);
    timer.unref?.();
  }).catch(() => {});
  return { collect, stop };
}
module.exports = { frameLabel, sanitize, start, PROBE, localeFromArguments, localeGuard };
const session = process.env[SESSION_KEY];
if (/^[a-f0-9]{32}$/.test(session || '')) {
  try { start(require('electron'), session); } catch {}
}
