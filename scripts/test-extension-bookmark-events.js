#!/usr/bin/env node
'use strict';

// Execute both real MV3 service workers against a tiny synthetic bookmarks
// API. This is deliberately not a replacement for browser integration tests;
// it catches regressions in the event wiring without opening a user's profile.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

function listenerEvent() {
  const listeners = [];
  return {
    addListener(listener) { listeners.push(listener); },
    listeners
  };
}

function waitForMicrotasks() {
  return new Promise(resolve => setTimeout(resolve, 0));
}

async function loadWorker(relativePath, browser) {
  const sent = [];
  let mutationAttempts = 0;
  const roots = browser === 'firefox'
    ? { tree: 'root________', bar: 'toolbar_____', menu: 'menu________', other: 'unfiled_____', mobile: 'mobile____' }
    : { tree: '0', bar: '1', other: '2', mobile: '3' };
  const values = {
    appSettings: {
      bookmarkSyncEnabled: true,
      bookmarkParticipatingBrowsers: { [browser]: true },
      bookmarkSyncFolders: {}
    },
    syncIdMap: { "source-item": "item" }
  };
  const nodes = new Map([
    [roots.tree, { id: roots.tree, title: 'root' }],
    [roots.bar, { id: roots.bar, title: browser === 'firefox' ? 'Bookmarks Toolbar' : 'Bookmarks Bar', parentId: roots.tree }],
    [roots.other, { id: roots.other, title: 'Other Bookmarks', parentId: roots.tree }],
    ...(roots.menu ? [[roots.menu, { id: roots.menu, title: 'Bookmarks Menu', parentId: roots.tree }]] : []),
    ...(roots.mobile ? [[roots.mobile, { id: roots.mobile, title: 'Mobile Bookmarks', parentId: roots.tree }]] : []),
    ['folder', { id: 'folder', title: 'Work', parentId: roots.bar }],
    ['item', { id: 'item', title: 'Synthetic bookmark', url: 'https://example.test/', parentId: 'folder' }],
    ['outside', { id: 'outside', title: 'Outside', url: 'https://outside.test/', parentId: roots.other }]
  ]);
  let nextSyntheticBookmarkId = 0;
  const indexedNode = node => {
    if (!node) return null;
    const siblings = [...nodes.values()].filter(candidate => candidate.parentId === node.parentId);
    return { ...node, index: siblings.findIndex(candidate => candidate.id === node.id) };
  };
  const events = {
    created: listenerEvent(), removed: listenerEvent(), changed: listenerEvent(), moved: listenerEvent(),
    alarm: listenerEvent(), startup: listenerEvent(), installed: listenerEvent(), connect: listenerEvent(),
    message: listenerEvent(), permissionAdded: listenerEvent(), permissionRemoved: listenerEvent(),
    tabsUpdated: listenerEvent(), tabsRemoved: listenerEvent(), cookieChanged: listenerEvent()
  };
  class TestWebSocket {
    static CONNECTING = 0;
    static OPEN = 1;
    constructor() { this.readyState = TestWebSocket.OPEN; }
    send(raw) { sent.push(JSON.parse(raw)); }
  }
  const local = {
    async get(keys) {
      if (typeof keys === 'string') return { [keys]: values[keys] };
      if (Array.isArray(keys)) return Object.fromEntries(keys.map(key => [key, values[key]]));
      return { ...values };
    },
    async set(next) { Object.assign(values, next); },
    async remove(keys) { for (const key of Array.isArray(keys) ? keys : [keys]) delete values[key]; }
  };
  const chrome = {
    storage: { local, onChanged: listenerEvent() },
    runtime: {
      onStartup: events.startup, onInstalled: events.installed, onConnect: events.connect, onMessage: events.message,
      getURL: value => `moz-extension://synthetic/${value}`
    },
    bookmarks: {
      onCreated: events.created, onRemoved: events.removed, onChanged: events.changed, onMoved: events.moved,
      async get(id) { return nodes.has(id) ? [indexedNode(nodes.get(id))] : []; },
      async getChildren(id) { return [...nodes.values()].filter(node => node.parentId === id); },
      async getTree() {
        const copy = id => {
          const node = nodes.get(id);
          return { ...node, children: [...nodes.values()].filter(child => child.parentId === id).map(child => copy(child.id)) };
        };
        return [copy(roots.tree)];
      },
      async create(details) {
        mutationAttempts += 1;
        const id = `created-${nextSyntheticBookmarkId++}`;
        const node = { id, title: details.title || '', parentId: details.parentId, url: details.url };
        nodes.set(id, node);
        return indexedNode(node);
      },
      async update(id, changes) {
        mutationAttempts += 1;
        if (!nodes.has(id)) throw new Error('missing synthetic bookmark');
        Object.assign(nodes.get(id), changes);
        return indexedNode(nodes.get(id));
      },
      async move(id, destination) {
        mutationAttempts += 1;
        if (!nodes.has(id)) throw new Error('missing synthetic bookmark');
        nodes.get(id).parentId = destination.parentId;
        return indexedNode(nodes.get(id));
      },
      async removeTree(id) {
        mutationAttempts += 1;
        if (!nodes.has(id)) throw new Error('missing synthetic bookmark');
        const pending = [id];
        while (pending.length) {
          const current = pending.pop();
          for (const child of nodes.values()) if (child.parentId === current) pending.push(child.id);
          nodes.delete(current);
        }
      },
      async remove(id) { return this.removeTree(id); }
    },
    alarms: { onAlarm: events.alarm, async create() {}, async clear() {} },
    action: { async setBadgeText() {}, async setBadgeBackgroundColor() {}, async setBadgeTextColor() {} },
    permissions: {
      onAdded: events.permissionAdded, onRemoved: events.permissionRemoved,
      async contains() { return false; }, async remove() { return true; }
    },
    scripting: {
      async getRegisteredContentScripts() { return []; }, async registerContentScripts() {},
      async unregisterContentScripts() {}, async executeScript() {}
    },
    tabs: {
      onUpdated: events.tabsUpdated, onRemoved: events.tabsRemoved,
      async query() { return []; }, async get() { return null; }, async sendMessage() {}
    },
    cookies: { onChanged: events.cookieChanged, async getAll() { return []; }, async set() {}, async remove() {} }
  };
  const sandbox = {
    chrome, browser: chrome, WebSocket: TestWebSocket, navigator: { userAgent: browser === 'firefox' ? 'Firefox/159.0' : 'Chrome/156.0' },
    crypto: { randomUUID: () => 'synthetic-id' }, URL, URLSearchParams, console,
    setTimeout, clearTimeout, setInterval, clearInterval, TextEncoder, TextDecoder, structuredClone
  };
  const source = fs.readFileSync(path.join(process.cwd(), relativePath), 'utf8');
  vm.runInNewContext(`${source}\nglobalThis.__browSyncWorkerTest = { mayExecuteAppBookmarkPlan, applySync, handlePullRequest };`, sandbox,
                     { filename: relativePath, timeout: 2_000 });
  await waitForMicrotasks();
  return {
    events, sent, values, roots, internals: sandbox.__browSyncWorkerTest,
    mutationAttempts: () => mutationAttempts,
    mutateTree(id, changes) { Object.assign(nodes.get(id), changes); }
  };
}

async function invoke(listener, ...args) {
  const result = listener(...args);
  if (result && typeof result.then === 'function') await result;
  await waitForMicrotasks();
}

async function testWorker(relativePath, browser) {
  const worker = await loadWorker(relativePath, browser);
  assert.equal(worker.events.created.listeners.length, 1, `${relativePath}: missing onCreated listener`);
  assert.equal(worker.events.removed.listeners.length, 1, `${relativePath}: missing onRemoved listener`);
  assert.equal(worker.events.changed.listeners.length, 1, `${relativePath}: missing onChanged listener`);
  assert.equal(worker.events.moved.listeners.length, 1, `${relativePath}: missing onMoved listener`);

  worker.sent.length = 0;
  await invoke(worker.events.created.listeners[0], 'item', { id: 'item', parentId: 'folder' });
  assert.equal(worker.sent.length, 1, `${relativePath}: created bookmark emitted no activity signal`);
  assert.equal(worker.sent[0].category, 'bookmark_changed');
  assert.equal(worker.sent[0].payload.raw.reason, 'created');

  worker.sent.length = 0;
  await invoke(worker.events.changed.listeners[0], 'item', {
    title: 'Synthetic bookmark (renamed)', url: 'https://example.test/edited'
  });
  assert.equal(worker.sent.length, 1, `${relativePath}: changed bookmark emitted no activity signal`);
  assert.equal(worker.sent[0].category, 'bookmark_changed');
  assert.equal(worker.sent[0].payload.raw.reason, 'changed');

  worker.sent.length = 0;
  await invoke(worker.events.moved.listeners[0], 'item', { oldParentId: 'folder', parentId: 'folder' });
  assert.equal(worker.sent.length, 1, `${relativePath}: moved bookmark emitted no activity signal`);
  assert.equal(worker.sent[0].payload.raw.reason, 'moved');

  worker.sent.length = 0;
  await invoke(worker.events.removed.listeners[0], 'item', {
    parentId: 'folder', node: { id: 'item', title: 'Synthetic bookmark', url: 'https://example.test/', parentId: 'folder' }
  });
  assert.equal(worker.sent.length, 1, `${relativePath}: deleted bookmark emitted no deletion observation`);
  assert.equal(worker.sent[0].category, 'bookmarks_removed');
  assert.equal(worker.sent[0].payload.bookmarksRemoved.title, 'Synthetic bookmark');

  worker.values.appSettings.bookmarkSyncFolders = { [browser]: 'Bookmarks Bar/Work' };
  worker.sent.length = 0;
  await invoke(worker.events.moved.listeners[0], 'item', {
    oldParentId: 'folder', parentId: worker.roots.other
  });
  assert.equal(worker.sent.length, 1,
               `${relativePath}: moving a bookmark out of the selected folder emitted no activity signal`);
  assert.equal(worker.sent[0].category, 'bookmark_changed');
  assert.equal(worker.sent[0].payload.raw.reason, 'moved');

  worker.sent.length = 0;
  await invoke(worker.events.created.listeners[0], 'outside', { id: 'outside', parentId: worker.roots.other });
  assert.equal(worker.sent.length, 0, `${relativePath}: out-of-scope bookmark event escaped its selected folder`);

  const allowedPlan = {
    bookmarkSyncEnabled: true,
    bookmarkWriteAllowed: true,
    bookmarkSyncStrategy: 'two_way',
    bookmarkSourceBrowser: browser
  };
  assert.equal(await worker.internals.mayExecuteAppBookmarkPlan(allowedPlan), true,
               `${relativePath}: valid app-authorized plan was refused`);
  assert.equal(await worker.internals.mayExecuteAppBookmarkPlan({ ...allowedPlan, bookmarkSyncEnabled: false }), false,
               `${relativePath}: final executor accepted bookmark sync OFF`);
  assert.equal(await worker.internals.mayExecuteAppBookmarkPlan({
    ...allowedPlan, bookmarkSyncStrategy: 'one_way', bookmarkSourceBrowser: browser
  }), false, `${relativePath}: final executor accepted automatic write to one-way source`);
  assert.equal(await worker.internals.mayExecuteAppBookmarkPlan({
    ...allowedPlan, bookmarkSyncStrategy: 'one_way', bookmarkSourceBrowser: browser, isExplicitBookmarkRestore: true
  }), true, `${relativePath}: explicit restore was incorrectly blocked for one-way source`);

  worker.values.appSettings.bookmarkSyncEnabled = false;
  assert.equal(await worker.internals.mayExecuteAppBookmarkPlan(allowedPlan), false,
               `${relativePath}: stale app settings allowed a write after bookmark sync was disabled`);
  worker.values.appSettings.bookmarkSyncEnabled = true;
  worker.values.appSettings.bookmarkParticipatingBrowsers = {};
  assert.equal(await worker.internals.mayExecuteAppBookmarkPlan(allowedPlan), false,
               `${relativePath}: non-participating browser was allowed to write`);
  worker.values.appSettings.bookmarkParticipatingBrowsers = { [browser]: true };

  worker.sent.length = 0;
  await worker.internals.applySync({
    ...allowedPlan,
    bookmarkSyncEnabled: false,
    category: 'bookmark_apply_plan',
    payload: { kind: 'raw', raw: { operations: [{ type: 'create', id: 'forbidden' }] } },
    messageId: 'forbidden-write'
  });
  assert.equal(worker.mutationAttempts(), 0, `${relativePath}: refused plan reached a mutation API`);
  assert.equal(worker.sent.at(-1)?.category, 'bookmark_apply_result', `${relativePath}: refused plan was not reported`);
  assert.equal(worker.sent.at(-1)?.payload?.raw?.applied, false, `${relativePath}: refused plan was reported as applied`);

  // The app first requests an exact, current target tree.  The returned
  // token, rather than a test-created token, is what permits the later
  // replay. This catches runtime parity errors in the Firefox context path.
  worker.sent.length = 0;
  await worker.internals.handlePullRequest('bookmark_plan_context', 'synthetic-request', {
    requestId: 'synthetic-request', targetFolder: 'Bookmarks Bar/Work'
  });
  const contextMessage = worker.sent.at(-1);
  assert.equal(contextMessage?.category, 'bookmark_plan_context',
               `${relativePath}: target-tree context was not returned to the app`);
  const inputToken = contextMessage?.payload?.raw?.inputToken;
  assert.equal(typeof inputToken, 'string', `${relativePath}: target-tree context had no current-tree token`);
  assert.equal(contextMessage?.payload?.raw?.scopeRootId, 'folder',
               `${relativePath}: selected-folder scope was not preserved in target-tree context`);

  // No selected folder uses portable system roots. This specifically covers
  // Firefox's toolbar/other/mobile root handling without borrowing Chromium
  // root-selection state.
  worker.sent.length = 0;
  await worker.internals.handlePullRequest('bookmark_plan_context', 'synthetic-root-request', {
    requestId: 'synthetic-root-request', targetFolder: null
  });
  const rootContext = worker.sent.at(-1);
  assert.equal(rootContext?.category, 'bookmark_plan_context',
               `${relativePath}: root-level target-tree context was not returned`);
  assert.equal(rootContext?.payload?.raw?.scopeRootId, null,
               `${relativePath}: root-level context unexpectedly acquired a selected-folder scope`);
  assert.equal(rootContext?.payload?.raw?.rootIds?.['1'], worker.roots.bar,
               `${relativePath}: bookmark-bar root identity was not preserved`);
  assert.equal(rootContext?.payload?.raw?.rootIds?.['2'], worker.roots.other,
               `${relativePath}: other-bookmarks root identity was not preserved`);

  // The only mutation path accepts that app-requested, current-tree token and
  // replays exactly that plan. This exercises real worker code against an
  // in-memory tree, including post-write verification and result report.
  worker.sent.length = 0;
  await worker.internals.applySync({
    ...allowedPlan,
    category: 'bookmark_apply_plan', messageId: 'approved-write',
    payload: { kind: 'raw', raw: {
      inputToken,
      operations: [{ type: 'create', id: 'app-planned-new', sourceId: 'source-new', parentId: 'folder', index: 1,
        title: 'Created by app plan', url: 'https://created.test/' }]
    } }
  });
  assert.equal(worker.mutationAttempts(), 1, `${relativePath}: approved app plan was not replayed exactly once`);
  const applied = worker.sent.at(-1);
  assert.equal(applied?.category, 'bookmark_apply_result', `${relativePath}: approved plan did not report a result`);
  assert.equal(applied?.payload?.raw?.applied, true, `${relativePath}: approved plan was not reported as applied`);
  assert.equal(applied?.payload?.raw?.verified, true, `${relativePath}: approved plan was not independently re-read`);
  assert.equal(applied?.payload?.raw?.operationResults?.[0]?.title, 'Created by app plan',
               `${relativePath}: operation result did not describe the app-planned mutation`);

  // A preview token is single-use and bound to the exact current target tree.
  // Simulate a user edit after the app inspected the tree: the old approval
  // must be refused before a bookmark API mutation is attempted.
  worker.sent.length = 0;
  await worker.internals.handlePullRequest('bookmark_plan_context', 'stale-request', {
    requestId: 'stale-request', targetFolder: 'Bookmarks Bar/Work'
  });
  const staleToken = worker.sent.at(-1)?.payload?.raw?.inputToken;
  worker.mutateTree('item', { title: 'Changed after preview' });
  const writesBeforeStaleAttempt = worker.mutationAttempts();
  worker.sent.length = 0;
  await worker.internals.applySync({
    ...allowedPlan,
    category: 'bookmark_apply_plan', messageId: 'stale-write',
    payload: { kind: 'raw', raw: {
      inputToken: staleToken,
      operations: [{ type: 'create', id: 'stale-create', parentId: 'folder', index: 2,
        title: 'Must not be created', url: 'https://stale.test/' }]
    } }
  });
  assert.equal(worker.mutationAttempts(), writesBeforeStaleAttempt,
               `${relativePath}: stale app plan reached a bookmark mutation API`);
  const staleResult = worker.sent.at(-1);
  assert.equal(staleResult?.payload?.raw?.applied, false,
               `${relativePath}: stale app plan was reported as applied`);
  assert.equal(staleResult?.payload?.raw?.verified, false,
               `${relativePath}: stale app plan was reported as verified`);
}

(async () => {
  await testWorker('ChromiumExtension/background/service-worker.js', 'chrome');
  await testWorker('FirefoxExtension/background/service-worker.js', 'firefox');
  console.log('PASS: Chromium and Firefox bookmark event wiring with synthetic trees');
})().catch(error => {
  console.error(`FAIL: ${error.stack || error}`);
  process.exitCode = 1;
});
