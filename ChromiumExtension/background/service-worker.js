// service-worker.js — BrowSync Chromium Extension background service worker
// Shared for Chrome, Arc, Edge, Brave
// MV3 — persistent state in chrome.storage, heartbeat via chrome.alarms

'use strict';

const DAEMON_URL = 'ws://127.0.0.1:62333';
const BROWSER_ID = 'chrome';   // Will be detected dynamically below
const HEARTBEAT_ALARM = 'browsync-heartbeat';
const RECONNECT_ALARM = 'browsync-reconnect';
const COOKIE_TIMESTAMPS_KEY = 'cookieUpdatedAt';

const applyingCookies = new Set();
// Batch rapid cookie updates before sending them to the macOS sync service.
const cookieSyncQueue = new Map();
let cookieSyncTimer = null;
let badgeResetTimer = null;
let permissionBadgeNeeded = false;

function cookieIdentity(cookie) {
  return `${cookie.domain}::${cookie.path || '/'}::${cookie.name}`;
}

async function filterIncomingCookiesBySource(cookies, senderBrowser) {
  const sender = String(senderBrowser || '').split('-')[0].toLowerCase();
  const { appSettings = {} } = await chrome.storage.local.get('appSettings').catch(() => ({}));
  const websiteSettings = appSettings.websiteSettings || [];

  return cookies.filter(cookie => {
    const domain = (cookie.domain || '').replace(/^\./, '').toLowerCase();
    if (!isSiteStateSyncEnabled(syncDomainForHostname(domain), appSettings)) {
      console.log(`[BrowSync] Ignoring ${domain} cookies because this site is excluded from State Sync.`);
      return false;
    }
    const site = websiteSettings.find(setting => syncDomainForHostname(domain) === setting.domain);
    const source = String(site?.sourceBrowser || '').split('-')[0].toLowerCase();
    const shouldReject = site?.strategy === 'primary_wins' && source && source !== sender;
    if (shouldReject) console.log(`[BrowSync] Ignoring ${domain} cookies from ${sender}; ${source} is the primary browser.`);
    return !shouldReject;
  });
}

let cachedCookieTimestamps = null;
let saveCookieTimestampsTimer = null;

async function getCookieTimestamps() {
  if (cachedCookieTimestamps) return cachedCookieTimestamps;
  const result = await chrome.storage.local.get(COOKIE_TIMESTAMPS_KEY).catch(() => ({}));
  cachedCookieTimestamps = result[COOKIE_TIMESTAMPS_KEY] || {};
  return cachedCookieTimestamps;
}

async function setCookieTimestamp(cookie, updatedAt) {
  const timestamps = await getCookieTimestamps();
  timestamps[cookieIdentity(cookie)] = updatedAt;
  if (saveCookieTimestampsTimer) clearTimeout(saveCookieTimestampsTimer);
  saveCookieTimestampsTimer = setTimeout(() => {
    chrome.storage.local.set({ [COOKIE_TIMESTAMPS_KEY]: cachedCookieTimestamps }).catch(() => {});
  }, 2000);
}

// ─── Browser detection ────────────────────────────────────────────────────────

function detectBrowserId() {
  const ua = navigator.userAgent.toLowerCase();
  if (ua.includes('edg/')) return 'edge';
  if (ua.includes('safari/') && !ua.includes('chrome/') && !ua.includes('chromium/')) return 'safari';
  if (ua.includes('brave/') || navigator.brave) return 'brave';
  if (ua.includes('opr/') || ua.includes('opera/')) return 'opera';
  if (ua.includes('vivaldi/')) return 'vivaldi';
  if (ua.includes('yabrowser/')) return 'yandex';
  if (ua.includes('orion/')) return 'orion';
  if (ua.includes('helium/')) return 'helium';
  if (ua.includes('browseros/')) return 'browseros';
  return 'chrome';
}

const DETECTED_BROWSER = detectBrowserId();
let CURRENT_BROWSER_ID = DETECTED_BROWSER;
const INSTANCE_ID = `${DETECTED_BROWSER}-main`;
chrome.storage.local.set({ currentBrowserId: CURRENT_BROWSER_ID }).catch(() => {});

const STATE_SYNC_PERMISSIONS = {
  permissions: ['tabs', 'cookies', 'scripting'],
  origins: ['<all_urls>']
};
const TAB_SHARING_PERMISSIONS = { permissions: ['tabs'] };
const STATE_SYNC_CONTENT_SCRIPT_ID = 'browsync-state-sync';
const STATE_SYNC_CONTENT_SCRIPT = 'content/content-script.js';

async function hasOptionalPermissions(details) {
  if (!chrome.permissions?.contains) return false;
  try { return await chrome.permissions.contains(details); } catch (_) { return false; }
}

async function isStateSyncConfigured() {
  const { appSettings = {} } = await chrome.storage.local.get('appSettings').catch(() => ({}));
  // Older BrowSync apps do not send stateSyncEnabled. Treat that as legacy
  // behavior, while an explicit false from a current app remains authoritative.
  return appSettings.stateSyncEnabled !== false && appSettings.stateParticipatingBrowsers?.[DETECTED_BROWSER] === true;
}

async function isTabSharingConfigured() {
  const { appSettings = {} } = await chrome.storage.local.get('appSettings').catch(() => ({}));
  return appSettings.tabSharingEnabled === true &&
    appSettings.tabSharingParticipatingBrowsers?.[DETECTED_BROWSER] === true;
}

async function canSyncState() {
  return await isStateSyncConfigured() && await hasOptionalPermissions(STATE_SYNC_PERMISSIONS);
}

async function canShareTabs() {
  return await isTabSharingConfigured() && await hasOptionalPermissions(TAB_SHARING_PERMISSIONS);
}

async function updatePermissionBadge() {
  if (!chrome.action?.setBadgeText) return;
  const needsStateSyncPermission = await isStateSyncConfigured() &&
    !(await hasOptionalPermissions(STATE_SYNC_PERMISSIONS));
  const needsTabSharingPermission = await isTabSharingConfigured() &&
    !(await hasOptionalPermissions(TAB_SHARING_PERMISSIONS));
  permissionBadgeNeeded = needsStateSyncPermission || needsTabSharingPermission;
  updateBadge();
}

async function reconcileOptionalFeaturePermissions() {
  if (!chrome.permissions?.remove || await isStateSyncConfigured()) return;
  // The popup sends its settings write only after chrome.permissions.request()
  // resolves (required to preserve the user-gesture context), so this can run
  // via permissions.onAdded before that write lands. Re-check after a brief
  // pause rather than revoking a permission the user just turned on.
  await new Promise(resolve => setTimeout(resolve, 300));
  if (await isStateSyncConfigured()) return;

  // State Sync is the only feature that needs cookies, scripting, and host
  // access. Tabs remain granted only when Tab Sharing still needs them.
  const permissions = ['cookies', 'scripting'];
  if (!(await isTabSharingConfigured())) permissions.push('tabs');
  try {
    await chrome.permissions.remove({ permissions, origins: ['<all_urls>'] });
  } catch (error) {
    console.warn('[BrowSync] Could not revoke unused feature permissions:', error);
  }
}

// Dynamic registrations only apply to later navigations.  State Sync must also
// begin observing pages that were already open when the user granted access or
// reloaded the extension; otherwise storage changes and the update banner are
// both silently absent until the user happens to reload every tab.
async function injectStateContentScriptIntoOpenTabs() {
  if (!chrome.scripting?.executeScript || !chrome.tabs?.query) return;
  const tabs = await chrome.tabs.query({}).catch(() => []);
  await Promise.all(tabs
    .filter(tab => tab.id && /^https?:\/\//i.test(tab.url || ''))
    .map(tab => chrome.scripting.executeScript({
      target: { tabId: tab.id }, files: [STATE_SYNC_CONTENT_SCRIPT]
    }).catch(() => {})));
}

async function reconcileStateContentScript() {
  if (!chrome.scripting?.getRegisteredContentScripts) {
    await chrome.storage.local.set({ stateSyncRuntimeEnabled: false }).catch(() => {});
    await reconcileOptionalFeaturePermissions();
    await updatePermissionBadge();
    return;
  }
  const shouldRegister = await canSyncState();
  let stateSyncRuntimeEnabled = false;
  try {
    const registered = await chrome.scripting.getRegisteredContentScripts({ ids: [STATE_SYNC_CONTENT_SCRIPT_ID] });
    if (shouldRegister && registered.length === 0) {
      await chrome.scripting.registerContentScripts([{
        id: STATE_SYNC_CONTENT_SCRIPT_ID,
        matches: ['<all_urls>'],
        js: [STATE_SYNC_CONTENT_SCRIPT],
        runAt: 'document_idle',
        persistAcrossSessions: true
      }]);
    } else if (!shouldRegister && registered.length > 0) {
      await chrome.scripting.unregisterContentScripts({ ids: [STATE_SYNC_CONTENT_SCRIPT_ID] });
    }
    stateSyncRuntimeEnabled = shouldRegister;
  } catch (error) {
    // A concurrent reconcile (e.g. permissions.onAdded firing back-to-back with
    // this settings-driven call, which happens on every toggle) may have already
    // applied this exact change, making register/unregister throw "already
    // exists"/"not found". Re-check the actual registration state rather than
    // assuming the desired state failed to apply and persisting a false "off".
    try {
      const registeredNow = await chrome.scripting.getRegisteredContentScripts({ ids: [STATE_SYNC_CONTENT_SCRIPT_ID] });
      stateSyncRuntimeEnabled = registeredNow.length > 0;
    } catch (_) {
      console.warn('[BrowSync] Could not update State Sync content script:', error);
    }
  }
  await chrome.storage.local.set({ stateSyncRuntimeEnabled }).catch(() => {});
  if (stateSyncRuntimeEnabled) await injectStateContentScriptIntoOpenTabs();
  // Unregister first, then revoke scripting so a disabled State Sync cannot
  // leave an already-registered content script behind.
  await reconcileOptionalFeaturePermissions();
  await updatePermissionBadge();
}

// ─── WebSocket management ────────────────────────────────────────────────────

let messageQueue = [];
let isProcessingQueue = false;

async function processQueue() {
  if (isProcessingQueue) return;
  isProcessingQueue = true;
  while (messageQueue.length > 0) {
    const msg = messageQueue.shift();
    try {
      await handleIncoming(msg);
    } catch (e) {
      console.error('[BrowSync] Error processing message:', e);
    }
  }
  isProcessingQueue = false;
}

let ws = null;
let isConnecting = false;
let reconnectDelay = 1000;
const outboundQueue = [];

async function connect() {
  if (isConnecting || (ws && (ws.readyState === WebSocket.CONNECTING || ws.readyState === WebSocket.OPEN))) return;
  isConnecting = true;

  await chrome.storage.local.set({ wsState: 'connecting' }).catch(() => { });
  console.log('[BrowSync] Connecting to daemon... browser:', DETECTED_BROWSER);

  try {
    ws = new WebSocket(DAEMON_URL);
  } catch (e) {
    console.warn('[BrowSync] Failed to create WebSocket:', e);
    isConnecting = false;
    await chrome.storage.local.set({ wsState: 'closed' }).catch(() => { });
    scheduleReconnect();
    return;
  }

  ws.onopen = async () => {
    console.log('[BrowSync] Connected');
    reconnectDelay = 1000;
    isConnecting = false;
    await chrome.storage.local.set({ wsState: 'open' }).catch(() => { });

    // The app owns planning/review; this extension only snapshots, validates,
    // executes explicit operations and verifies their actual result.
    send({ type: 'register', browser: DETECTED_BROWSER, instanceId: INSTANCE_ID, capabilities: ['bookmarkExecutorV2'] });
    // Do not request an unscoped snapshot on every connection. It makes every
    // browser stream all cookies back to this worker; state is pulled only for
    // the site being opened or explicitly synced.
    while (outboundQueue.length > 0) {
      ws.send(JSON.stringify(outboundQueue.shift()));
    }

    if (chrome.alarms) {
      await chrome.alarms.create(HEARTBEAT_ALARM, { periodInMinutes: 0.5 });
      await chrome.alarms.clear(RECONNECT_ALARM);
    }
    updateBadge();
  };

  ws.onclose = async () => {
    console.log('[BrowSync] Disconnected');
    isConnecting = false;
    await chrome.storage.local.set({ wsState: 'closed' }).catch(() => { });
    ws = null;
    updateBadge();
    scheduleReconnect();
  };

  ws.onerror = (e) => console.warn('[BrowSync] WS error:', e);

  ws.onmessage = (event) => {
    try {
      const msg = JSON.parse(event.data.trim());
      messageQueue.push(msg);
      processQueue();
    } catch (e) {
      console.warn('[BrowSync] Parse error:', e);
    }
  };
}

function send(message) {
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(message));
  } else {
    outboundQueue.push(message);
    connect();
  }
}

function scheduleReconnect() {
  if (chrome.alarms) {
    chrome.alarms.create(RECONNECT_ALARM, { delayInMinutes: reconnectDelay / 60000 });
  } else {
    setTimeout(connect, reconnectDelay);
  }
  reconnectDelay = Math.min(reconnectDelay * 2, 30000);
}

function updateBadge(state = null) {
  if (state === 'syncing') {
    if (badgeResetTimer) clearTimeout(badgeResetTimer);
    chrome.action.setBadgeText({ text: 'SYNC' });
    chrome.action.setBadgeBackgroundColor({ color: '#3b82f6' });
    if (chrome.action.setBadgeTextColor) {
      try { chrome.action.setBadgeTextColor({ color: '#ffffff' }); } catch (e) {}
    }
    badgeResetTimer = setTimeout(() => {
      badgeResetTimer = null;
      updateBadge();
    }, 2000);
    return;
  }

  if (permissionBadgeNeeded) {
    chrome.action.setBadgeText({ text: '!' }).catch(() => {});
    chrome.action.setBadgeBackgroundColor({ color: '#FF9500' }).catch(() => {});
    if (chrome.action.setBadgeTextColor) {
      try { chrome.action.setBadgeTextColor({ color: '#ffffff' }).catch(() => {}); } catch (e) {}
    }
    return;
  }
  
  if (ws && ws.readyState === WebSocket.OPEN) {
    chrome.action.setBadgeText({ text: '' }).catch(() => {});
    chrome.action.setBadgeBackgroundColor({ color: '#22c55e' }).catch(() => {});
    if (chrome.action.setBadgeTextColor) {
      try { chrome.action.setBadgeTextColor({ color: '#ffffff' }).catch(() => {}); } catch(e) {}
    }
  } else {
    chrome.action.setBadgeText({ text: 'OFF' }).catch(() => {});
    chrome.action.setBadgeBackgroundColor({ color: '#94a3b8' }).catch(() => {});
    if (chrome.action.setBadgeTextColor) {
      try { chrome.action.setBadgeTextColor({ color: '#ffffff' }).catch(() => {}); } catch(e) {}
    }
  }
}

// ─── Incoming messages ───────────────────────────────────────────────────────

chrome.runtime.onConnect.addListener((port) => {
  if (port.name === 'browsync-keepalive') {
    port.onMessage.addListener((msg) => {
      if (msg.type === 'ping') {
        port.postMessage({ type: 'pong' });
      }
    });
  }
});


async function handleIncoming(message) {
  if (!message?.type) return;

  switch (message.type) {
    case 'sync':
      await applySync(message);
      break;
    case 'settings':
      if (message.payload && message.payload.kind === 'raw') {
        const raw = message.payload.raw;
        chrome.storage.local.get('appSettings').then(({ appSettings }) => {
          let settings = appSettings || {};
          if (raw.routerDefault !== undefined) settings.routerDefault = raw.routerDefault;
          if (raw.routerEnabled !== undefined) settings.routerEnabled = raw.routerEnabled;
          if (raw.interfaceLanguage !== undefined) settings.interfaceLanguage = raw.interfaceLanguage;
          if (raw.bookmarkSyncEnabled !== undefined) settings.bookmarkSyncEnabled = raw.bookmarkSyncEnabled;
          if (raw.bookmarkSyncStrategy !== undefined) settings.bookmarkSyncStrategy = raw.bookmarkSyncStrategy;
          if (raw.bookmarkSourceBrowser !== undefined) settings.bookmarkSourceBrowser = raw.bookmarkSourceBrowser;
          if (raw.bookmarkSafeMode !== undefined) settings.bookmarkSafeMode = raw.bookmarkSafeMode;
          if (raw.stateSyncEnabled !== undefined) settings.stateSyncEnabled = raw.stateSyncEnabled;
          if (raw.automaticSync !== undefined) settings.automaticSync = raw.automaticSync;
          if (raw.tabSharingEnabled !== undefined) settings.tabSharingEnabled = raw.tabSharingEnabled;
          if (raw.stateParticipatingBrowsers) settings.stateParticipatingBrowsers = raw.stateParticipatingBrowsers;
          if (raw.bookmarkParticipatingBrowsers) settings.bookmarkParticipatingBrowsers = raw.bookmarkParticipatingBrowsers;
          if (raw.bookmarkSyncFolders) settings.bookmarkSyncFolders = raw.bookmarkSyncFolders;
          if (raw.tabSharingParticipatingBrowsers) settings.tabSharingParticipatingBrowsers = raw.tabSharingParticipatingBrowsers;
          if (raw.websiteListPolicy !== undefined) settings.websiteListPolicy = raw.websiteListPolicy;
          if (raw.websiteSettings !== undefined) settings.websiteSettings = raw.websiteSettings;
          if (raw.installedBrowsers !== undefined) settings.installedBrowsers = raw.installedBrowsers;
          if (raw.installedBrowserDetails !== undefined) settings.installedBrowserDetails = raw.installedBrowserDetails;
          if (raw.syncDisabledDomains !== undefined) settings.syncDisabledDomains = raw.syncDisabledDomains;
          chrome.storage.local.set({ appSettings: settings }).then(async () => {
            await reconcileStateContentScript();
            // A service worker can receive settings after the first navigation event.
            // Re-check the active page once the automatic-sync gate is available.
            if ((raw.automaticSync !== undefined || raw.stateParticipatingBrowsers) && await canSyncState()) {
              const tabs = await chrome.tabs.query({ active: true, currentWindow: true });
              for (const tab of tabs) {
                if (tab.id && tab.url) void requestCurrentSiteState(tab.id, tab.url);
              }
            }
          });
        });
      }
      break;
    case 'pull':
      await handlePullRequest(message.category, message.site, message.payload?.raw || null);
      break;
    case 'ack':
      if (message.browser) {
        CURRENT_BROWSER_ID = message.browser;
        chrome.storage.local.set({ currentBrowserId: CURRENT_BROWSER_ID });
      }
      break;
  }
}

async function applySync(message) {
  updateBadge('syncing');
  const { category, payload } = message;

  // Empty payload means it's a pull request from the App
  if (!payload || (payload.kind === 'raw' && Object.keys(payload.raw || {}).length === 0)) {
    if (category === 'bookmarks' && (isApplyingSync || queuedBookmarkSyncs.length)) {
      // Answer after the writes before it: a tree read mid-write (or before a
      // queued removal) would show bookmarks that are about to change.
      queuedBookmarkSyncs.push(() => handlePullRequest(category));
      return;
    }
    await handlePullRequest(category);
    return;
  }

  switch (category) {
    case 'bookmark_apply_plan':
      if (!(await mayExecuteAppBookmarkPlan(message))) {
        send({ type: 'sync', browser: CURRENT_BROWSER_ID, category: 'bookmark_apply_result',
          payload: { kind: 'raw', raw: { messageId: message.messageId || null, applied: false, verified: false,
            writes: 0, error: 'bookmark write refused by extension safety policy' } },
          messageId: crypto.randomUUID(), timestamp: Date.now() });
        break;
      }
      await executeAppBookmarkPlan(payload.raw || {}, message.messageId);
      break;
    case 'bookmarks':
    case 'bookmarks_removed_batch':
    case 'bookmarks_removed':
      send({ type: 'sync', browser: CURRENT_BROWSER_ID, category: 'bookmark_apply_result',
        payload: { kind: 'raw', raw: { messageId: message.messageId || null, applied: false, verified: false,
          writes: 0, error: 'native app bookmark plan required' } },
        messageId: crypto.randomUUID(), timestamp: Date.now() });
      break;
    case 'localStorage':
    case 'sessionStorage': {
      if (!(await canSyncState())) break;
      const items = payload[category] || [];
      if (items.length > 0) {
        const byOrigin = {};
        for (const item of items) {
          if (!item.origin) continue;
          if (!byOrigin[item.origin]) byOrigin[item.origin] = [];
          byOrigin[item.origin].push(item);
          
          if (item.value !== null) {
            const tKey = `tombstone_${category}_${item.origin}::${item.key}`;
            chrome.storage.local.remove(tKey).catch(() => {});
          }
        }
        for (const origin of Object.keys(byOrigin)) {
          const key = `sync_${category}_${origin}`;
          await chrome.storage.local.set({ [key]: byOrigin[origin] }).catch(e => console.warn('[BrowSync] Failed to set storage chunk:', e));
        }
      }
      await broadcastToContentScripts(category, items, message.site);
      break;
    }
    case 'cookies':
      if (!(await canSyncState())) break;
      const acceptedCookies = await filterIncomingCookiesBySource(payload.cookies || [], message.browser);
      if (acceptedCookies.length === 0) break;
      await applyCookieSync(acceptedCookies, message.browser || 'unknown');
      await showStateSyncUpdatePrompt(acceptedCookies);
      break;
    case 'tabSharing':
      if (!(await canShareTabs())) break;
      // Store remote tabs in local storage for popup.js to read
      if (payload.kind === 'tabs') {
        const tabs = payload.tabs || [];
        const browserId = message.browser || 'other';
        if (browserId !== CURRENT_BROWSER_ID) {
           chrome.storage.local.get('remoteTabs').then(data => {
             const remoteTabs = data.remoteTabs || {};
             remoteTabs[browserId] = tabs;
             chrome.storage.local.set({ remoteTabs });
           });
        }
      }
      break;
  }
}

const appBookmarkPlanInputs = new Map();

async function mayExecuteAppBookmarkPlan(message) {
  if (message.bookmarkSyncEnabled !== true || message.bookmarkWriteAllowed !== true) return false;
  const explicitRestore = message.isExplicitDeletedBookmarkRestore === true || message.isExplicitBookmarkRestore === true;
  const target = String(CURRENT_BROWSER_ID || DETECTED_BROWSER).split('-')[0].toLowerCase();
  const source = String(message.bookmarkSourceBrowser || '').split('-')[0].toLowerCase();
  if (!explicitRestore && message.bookmarkSyncStrategy === 'one_way' && source === target) return false;
  const { appSettings = {} } = await chrome.storage.local.get('appSettings').catch(() => ({}));
  if (appSettings.bookmarkSyncEnabled !== true) return false;
  const participants = appSettings.bookmarkParticipatingBrowsers || {};
  if (participants[target] !== true) return false;
  const cachedSource = String(appSettings.bookmarkSourceBrowser || '').split('-')[0].toLowerCase();
  if (!explicitRestore && appSettings.bookmarkSyncStrategy === 'one_way' && cachedSource === target) return false;
  return true;
}

function bookmarkTreeFingerprint(tree) {
  const rows = [];
  const visit = nodes => (nodes || []).forEach((node, index) => {
    rows.push([node.id, node.parentId || '', index, node.title || '', node.url || null]);
    visit(node.children);
  });
  visit(tree);
  return JSON.stringify(rows);
}

function bookmarkOutsideScopeFingerprint(tree, scopeRootId = null) {
  const excluded = new Set(scopeRootId ? [scopeRootId] : [...rootRoleById.entries()].filter(([, role]) => role).map(([id]) => id));
  const rows = [];
  const visit = nodes => (nodes || []).forEach((node, index) => {
    rows.push([node.id, node.parentId || '', index, node.title || '', node.url || null]);
    if (!excluded.has(node.id)) visit(node.children);
  });
  visit(tree);
  return JSON.stringify(rows);
}

function canonicalBookmarkURL(value) {
  if (!value) return null;
  try { return new URL(value).href; }
  catch (_) { return String(value); }
}

async function executeAppBookmarkPlan(raw, messageId) {
  const token = raw.inputToken;
  const expected = appBookmarkPlanInputs.get(token);
  const answer = (applied, verified, writes, failures = [], error = null, operationResults = []) => send({
    type: 'sync', browser: CURRENT_BROWSER_ID, category: 'bookmark_apply_result',
    payload: { kind: 'raw', raw: { messageId: messageId || null, applied, verified, writes, failures, error, operationResults } },
    messageId: crypto.randomUUID(), timestamp: Date.now()
  });
  if (!expected) { answer(false, false, 0, [], 'stale or unknown app plan input'); return; }
  await primaryRootsReady;
  const before = await getTreeForRoots();
  if (bookmarkTreeFingerprint(before) !== expected.full) {
    appBookmarkPlanInputs.delete(token);
    answer(false, false, 0, [], 'target bookmarks changed after preview');
    return;
  }
  appBookmarkPlanInputs.delete(token);
  const failures = [];
  const createdIds = new Map();
  const appliedOps = [];
  const { syncIdMap = {} } = await chrome.storage.local.get('syncIdMap');
  const real = id => createdIds.get(id) || id;
  const selectedIds = Array.isArray(raw.selectedNodeIds) ? new Set(raw.selectedNodeIds) : null;
  const operations = selectedIds ? (raw.operations || []).filter(op => selectedIds.has(op.id)) : (raw.operations || []);
  for (const op of operations) {
    try {
      if (op.type === 'create') {
        const created = await chrome.bookmarks.create({ parentId: real(op.parentId), index: op.index ?? undefined,
          title: op.title || '', url: op.url || undefined });
        createdIds.set(op.id, created.id);
        if (op.sourceId) syncIdMap[op.sourceId] = created.id;
      } else if (op.type === 'update') {
        await chrome.bookmarks.update(real(op.id), { title: op.title, url: op.url ?? undefined });
        if (op.sourceId) syncIdMap[op.sourceId] = real(op.id);
      } else if (op.type === 'move') {
        await chrome.bookmarks.move(real(op.id), { parentId: real(op.parentId), index: op.index ?? undefined });
        if (op.sourceId) syncIdMap[op.sourceId] = real(op.id);
      } else if (op.type === 'removeTree') {
        try { await chrome.bookmarks.removeTree(real(op.id)); }
        catch (_) { await chrome.bookmarks.remove(real(op.id)); }
        if (op.sourceId) delete syncIdMap[op.sourceId];
      }
      appliedOps.push(op);
    } catch (error) {
      failures.push({ type: op.type, id: op.id, error: String(error?.message || error) });
    }
  }
  const after = await getTreeForRoots().catch(() => null);
  if (after && bookmarkOutsideScopeFingerprint(after, expected.scopeRootId) !== expected.outside) {
    failures.push({ type: 'scope', id: expected.scopeRootId || 'synced-roots', error: 'bookmarks outside the selected scope changed' });
  }
  const operationResults = [];
  if (after && !failures.length) {
    for (const op of appliedOps) {
      const id = real(op.id);
      const actual = (await chrome.bookmarks.get(id).catch(() => []))[0];
      operationResults.push({ type: op.type, id: op.id, actualId: id, exists: Boolean(actual),
        parentId: actual?.parentId ?? null, index: actual?.index ?? null,
        title: actual?.title ?? null, url: actual?.url ?? null });
      if (op.type === 'removeTree' ? Boolean(actual) : !actual) {
        failures.push({ type: op.type, id: op.id, error: 'post-write verification failed' });
        continue;
      }
      if ((op.type === 'create' || op.type === 'update') &&
          (actual.title !== (op.title || '') || canonicalBookmarkURL(actual.url) !== canonicalBookmarkURL(op.url))) {
        failures.push({ type: op.type, id: op.id, error: 'post-write values differ' });
      }
      if ((op.type === 'create' || op.type === 'move') &&
          (actual.parentId !== real(op.parentId) || (op.index != null && actual.index !== op.index))) {
        failures.push({ type: op.type, id: op.id, error: 'post-write location differs' });
      }
    }
  }
  if (!failures.length) await chrome.storage.local.set({ syncIdMap });
  answer(failures.length === 0, Boolean(after) && failures.length === 0,
         operations.length - failures.length, failures,
         failures.length ? 'one or more app-planned writes failed' : null, operationResults);
}

async function sendCookiesSnapshot(site) {
  if (!(await canSyncState())) return;
  console.log(`[BrowSync] Processing full cookie pull request for site: ${site || 'all'}`);
  if (!chrome.cookies) return;
  const timestamps = await getCookieTimestamps();
  const cookies = await chrome.cookies.getAll(site ? { domain: site } : {});
  const mapped = cookies.map(c => ({
    name: c.name, value: c.value, domain: c.domain, path: c.path,
    expirationDate: c.expirationDate, secure: c.secure, httpOnly: c.httpOnly, hostOnly: c.hostOnly, sameSite: c.sameSite,
    updatedAt: timestamps[cookieIdentity(c)] || 0
  }));

  const mappedMap = new Map();
  mapped.forEach(c => mappedMap.set(cookieIdentity(c), c));

  // Include tombstones
  const allStorage = await chrome.storage.local.get(null);
  for (const [key, value] of Object.entries(allStorage)) {
    // A targeted pull must not drag every site's old deletion tombstones into
    // the response. Besides being unrelated, they can delay the requested
    // session cookie until the app-side repair window expires.
    if (key.startsWith('tombstone_cookies_') && value && (!site || cookieMatchesSite(value, site))) {
      const mapKey = cookieIdentity(value);
      if (!mappedMap.has(mapKey)) {
        mappedMap.set(mapKey, value);
      }
    }
  }

  const allCookies = Array.from(mappedMap.values());
  // Send in chunks of 100 to avoid WS message size limits
  console.log(`[BrowSync] Sending ${allCookies.length} cookies (including tombstones)...`);
  for (let i = 0; i < allCookies.length; i += 100) {
    const chunk = allCookies.slice(i, i + 100);
    try {
      send({
        type: 'sync', browser: CURRENT_BROWSER_ID, category: 'cookies',
        payload: { kind: 'cookies', cookies: chunk },
        messageId: crypto.randomUUID(), timestamp: Date.now()
      });
      await new Promise(r => setTimeout(r, 50));
    } catch (e) {
      console.error('[BrowSync] Error sending cookie chunk:', e);
    }
  }
}

async function sendStorageSnapshot(storageType, site) {
  if (!(await canSyncState())) return;
  if (!chrome.scripting || !chrome.tabs) return;
  const tabs = await chrome.tabs.query({});
  const allItemsMap = new Map(); // Use Map to deduplicate by key+origin

  // 1. Get from currently open tabs
  for (const tab of tabs) {
    if (!tab.id || !tab.url || tab.url.startsWith('chrome') || tab.url.startsWith('about') || tab.url.startsWith('safari-extension')) continue;
    if (site && new URL(tab.url).hostname !== site && !new URL(tab.url).hostname.endsWith('.' + site)) continue;
    try {
      const results = await chrome.scripting.executeScript({
        target: { tabId: tab.id },
        func: type => {
          const storage = type === 'sessionStorage' ? sessionStorage : localStorage;
          const items = [];
          for (let i = 0; i < storage.length; i++) {
            const key = storage.key(i);
            items.push({ key, value: storage.getItem(key), origin: location.origin });
          }
          return items;
        },
        args: [storageType]
      });
      if (results?.[0]?.result) {
        results[0].result.forEach(item => {
          allItemsMap.set(`${item.origin}::${item.key}`, item);
        });
      }
    } catch (_) { }
  }

  // 2. Also inject items from our local tombstone cache to ensure deletions propagate
  const cacheData = await chrome.storage.local.get(null);
  for (const [key, value] of Object.entries(cacheData)) {
    if (key.startsWith(`tombstone_${storageType}_`)) {
      // It's a deletion tombstone
      const item = { key: value.key, value: null, origin: value.origin, _isBackup: true };
      if (site && !item.origin.includes(site)) continue;
      const mapKey = `${item.origin}::${item.key}`;
      if (!allItemsMap.has(mapKey)) {
        allItemsMap.set(mapKey, item);
      }
    } else if (key.startsWith(`sync_${storageType}_`) || key.startsWith(`backup_${storageType}_`)) {
      // It's a live cached item (or passively accumulated backup)
      const items = Array.isArray(value) ? value : [];
      for (const item of items) {
        if (site && !item.origin.includes(site)) continue;
        const mapKey = `${item.origin}::${item.key}`;
        item._isBackup = true;
        // If not in live tabs, OR if the current item is just a passive backup, the tombstone overrides it
        if (!allItemsMap.has(mapKey) || allItemsMap.get(mapKey)._isBackup) {
          allItemsMap.set(mapKey, item);
        }
      }
    }
  }

  const allItems = Array.from(allItemsMap.values());
  if (allItems.length === 0) return;
  console.log(`[BrowSync] Sending ${allItems.length} ${storageType} items (including backups)...`);
  for (let i = 0; i < allItems.length; i += 200) {
    send({
      type: 'sync', browser: CURRENT_BROWSER_ID, category: storageType,
      payload: { kind: storageType, [storageType]: allItems.slice(i, i + 200) },
      messageId: crypto.randomUUID(), timestamp: Date.now()
    });
  }
}

async function handlePullRequest(category, site, requestRaw = null) {
  console.log('[BrowSync] Received pull request for:', category, site);
  switch (category) {
    case 'bookmark_plan_context': {
      if (!chrome.bookmarks) return;
      await primaryRootsReady;
      const tree = await getTreeForRoots();
      refreshSystemRoots(tree);
      const { syncIdMap = {} } = await chrome.storage.local.get('syncIdMap');
      const targetFolder = requestRaw?.targetFolder || null;
      const scopeFolder = targetFolder ? await findBookmarkFolderByPath(targetFolder) : null;
      if (targetFolder && !scopeFolder) {
        send({ type: 'sync', browser: CURRENT_BROWSER_ID, category: 'bookmark_plan_context',
          payload: { kind: 'raw', raw: { requestId: requestRaw?.requestId || site || null,
            error: 'target folder missing or ambiguous' } }, messageId: crypto.randomUUID(), timestamp: Date.now() });
        break;
      }
      const nodes = [];
      const visit = children => {
        for (const [index, node] of (children || []).entries()) {
          nodes.push({ id: node.id, title: node.title || '', url: node.url ?? null,
            parentId: node.parentId ?? null, isFolder: !node.url, sortIndex: index,
            dateAdded: node.dateAdded ?? null, sourceBrowser: CURRENT_BROWSER_ID });
          visit(node.children);
        }
      };
      for (const root of tree?.[0]?.children || []) {
        if (rootRoleById.get(root.id)) {
          nodes.push({ id: root.id, title: root.title || '', url: null,
            parentId: root.parentId ?? null, isFolder: true, sortIndex: root.index ?? 0,
            dateAdded: root.dateAdded ?? null, sourceBrowser: CURRENT_BROWSER_ID });
          visit(root.children);
        }
      }
      const inputToken = crypto.randomUUID();
      appBookmarkPlanInputs.set(inputToken, { full: bookmarkTreeFingerprint(tree),
        outside: bookmarkOutsideScopeFingerprint(tree, scopeFolder?.id || null), scopeRootId: scopeFolder?.id || null });
      send({ type: 'sync', browser: CURRENT_BROWSER_ID, category: 'bookmark_plan_context',
        payload: { kind: 'raw', raw: { requestId: requestRaw?.requestId || site || null, inputToken, nodes,
          rootIds: { '1': localBarId, '2': localOtherId, '3': localMobileId || localOtherId },
          sourceToNativeIds: syncIdMap, scopeRootId: scopeFolder?.id || null } }, messageId: crypto.randomUUID(), timestamp: Date.now() });
      break;
    }
    case 'bookmark_backup':
    case 'bookmarks': {
      if (!chrome.bookmarks) return;
      await primaryRootsReady;
      const tree = await getTreeForRoots();
      refreshSystemRoots(tree);
      const storageData = await chrome.storage.local.get('syncIdMap');
      const syncIdMap = storageData.syncIdMap || {};
      const chromeToSafariId = new Map();
      for (const [safariId, chromeId] of Object.entries(syncIdMap)) {
        if (!chromeToSafariId.has(chromeId)) {
          chromeToSafariId.set(chromeId, safariId);
        }
      }

      const flat = [];
      const isBackupOnly = category === 'bookmark_backup';
      const backupRoots = isBackupOnly ? [
        { actualId: localBarId, snapshotId: 'browsync-root-bar', title: 'Bookmarks Bar' },
        { actualId: localOtherId, snapshotId: 'browsync-root-other', title: 'Other Bookmarks' },
        { actualId: localMobileId, snapshotId: 'browsync-root-mobile', title: 'Mobile Bookmarks' }
      ].filter(root => root.actualId) : [];
      const backupRootByActualId = new Map(backupRoots.map(root => [root.actualId, root]));
      if (isBackupOnly) {
        for (const root of backupRoots) {
          flat.push({
            id: root.snapshotId,
            title: root.title,
            url: null,
            parentId: '0',
            isFolder: true,
            dateAdded: Date.now(),
            sourceBrowser: CURRENT_BROWSER_ID
          });
        }
      }

      function traverse(nodes) {
        for (const [sortIndex, node] of nodes.entries()) {
          if (!systemRoots.has(node.id)) { // Skip root and system folders
            let normalizedParentId = node.parentId;
            if (isBackupOnly && backupRootByActualId.has(node.parentId)) normalizedParentId = backupRootByActualId.get(node.parentId).snapshotId;
            else if (rootRoleById.get(node.parentId)) normalizedParentId = rootRoleById.get(node.parentId);

            let mappedId = isBackupOnly ? node.id : (chromeToSafariId.get(node.id) || node.id);
            let mappedParentId = isBackupOnly ? normalizedParentId : (chromeToSafariId.get(normalizedParentId) || normalizedParentId);

            flat.push({ 
              id: mappedId, 
              title: node.title, 
              url: node.url, 
              parentId: mappedParentId,
              isFolder: !node.url, 
              sortIndex,
              dateAdded: node.dateAdded, 
              sourceBrowser: CURRENT_BROWSER_ID 
            });
          }
          // Unsynced roots (managed) are skipped together with their contents.
          const isUnsyncedRoot = rootRoleById.has(node.id) && !rootRoleById.get(node.id);
          if (node.children && !isUnsyncedRoot) traverse(node.children);
        }
      }
      if (isBackupOnly) {
        for (const root of backupRoots) {
          const subtree = await chrome.bookmarks.getSubTree(root.actualId).catch(() => []);
          traverse(subtree[0]?.children || []);
        }
      } else {
        traverse(tree);
      }
      console.log(`[BrowSync] Sending ${flat.length} bookmarks...`);
      send({
        type: 'sync', browser: CURRENT_BROWSER_ID, category: category === 'bookmark_backup' ? 'bookmark_backup' : 'bookmarks',
        payload: { kind: 'bookmarks', bookmarks: flat },
        messageId: crypto.randomUUID(), timestamp: Date.now()
      });
      break;
    }
    case 'browserData': {
      if (!(await canSyncState())) return;
      await sendCookiesSnapshot(site);
      await sendStorageSnapshot('localStorage', site);
      await sendStorageSnapshot('sessionStorage', site);
      break;
    }
    case 'cookies': {
      if (!(await canSyncState())) return;
      await sendCookiesSnapshot(site);
      break;
    }
    case 'browserState':
    case 'tabSharing': {
      if (!(await canShareTabs())) return;
      if (!chrome.tabs) return;
      const tabs = await chrome.tabs.query({});
      // Filter out incognito tabs for privacy, and non-HTTP(S) tabs, if it's tab sharing
      const filteredTabs = category === 'tabSharing' ? tabs.filter(t => !t.incognito && /^https?:\/\//i.test(t.url)) : tabs;
      console.log(`[BrowSync] Sending ${filteredTabs.length} tabs for ${category}...`);
      const mapped = filteredTabs.map(tab => ({
        id: String(tab.id), url: tab.url, title: tab.title || '', isActive: tab.active,
        windowId: String(tab.windowId), index: tab.index, favIconURL: tab.favIconUrl,
        sourceBrowser: CURRENT_BROWSER_ID, capturedAt: Date.now()
      }));
      send({
        type: 'sync', browser: CURRENT_BROWSER_ID, category: category,
        payload: { kind: 'tabs', tabs: mapped },
        messageId: crypto.randomUUID(), timestamp: Date.now()
      });
      break;
    }
    case 'localStorage':
    case 'sessionStorage': {
      if (!(await canSyncState())) return;
      await sendStorageSnapshot(category);
      break;
    }
  }
}

// A popup-initiated sync is a repair pull, not merely an upload from the
// currently open browser.  Asking the daemon for this site makes it return the
// cached state immediately and request fresh snapshots from the other browsers.
// Without this, "Sync Now" is a silent no-op whenever this browser has no new
// local cookies/storage to upload (or automatic sync is unavailable).
async function requestSiteStateSync(site) {
  if (!(await canSyncState())) return false;
  send({
    type: 'pull', browser: CURRENT_BROWSER_ID, category: 'browserData', site,
    messageId: crypto.randomUUID(), timestamp: Date.now()
  });
  await handlePullRequest('browserData', site);
  return true;
}

// ─── Bookmarks ───────────────────────────────────────────────────────────────

let localBarId = '1';
let localOtherId = '2';
let localMobileId = '3';
let systemRoots = new Set(['0', '1', '2', '3']);
// Every top-level node ID -> portable role: '1' bar, '2' other, '3' mobile,
// null for roots that are never synced (the enterprise managed folder, or the
// local-only twin of a root when Chrome also shows account-storage roots).
let rootRoleById = new Map([['1', '1'], ['2', '2'], ['3', '3']]);

// Role -> root ID chosen earlier. It is kept until that root disappears, so a
// root merely becoming empty or non-empty never flips which root is synced
// (a flip would duplicate bookmarks into the other root and drop deletions).
// Loaded before any tree is resolved; see primaryRootsReady.
let stickyPrimaryRoots = {};
let primaryRootsLoaded = false;
// Chrome IDs already paired with Safari bookmarks. On a first choice the root
// holding most of them wins, so upgrading users keep syncing the root they
// synced before instead of having everything recreated in the other one.
let pairedChromeIds = new Set();
// Root ID -> number of bookmarks and folders (all depths) last seen. Telling "the user moved
// their bookmarks to the twin root" from "the user deleted the last bookmark"
// needs the previous state, also across worker restarts.
let lastRootChildCounts = {};
const primaryRootsReady = (chrome.storage?.local
  ? chrome.storage.local.get(['bookmarkPrimaryRoots', 'syncIdMap', 'bookmarkRootChildCounts']).then(stored => {
      stickyPrimaryRoots = stored.bookmarkPrimaryRoots || {};
      pairedChromeIds = new Set(Object.values(stored.syncIdMap || {}));
      lastRootChildCounts = stored.bookmarkRootChildCounts || {};
    })
  : Promise.resolve()
).catch(() => {}).finally(() => { primaryRootsLoaded = true; });
// False until roots were resolved from a real tree in this worker; the
// built-in 1/2/3 defaults must not be trusted for removal events before that.
let systemRootsResolved = false;

// Tree reads used for root resolution are numbered. Concurrent callers can
// finish out of order; a tree read before a newer, already processed one
// must not change the remembered primary roots (it would undo a switch).
let treeReadSeq = 0;
let lastRootsTreeSeq = 0;
async function getTreeForRoots() {
  const seq = ++treeReadSeq;
  const tree = await chrome.bookmarks.getTree();
  if (tree) tree.rootsReadSeq = seq;
  return tree;
}

// Chrome can replace its permanent folders while this worker is alive (e.g.
// signing in moves bookmarks into account storage and the bar/other folders
// get new IDs). Roots must therefore be re-resolved from every fresh tree, by
// folderType rather than by ID, or the new roots leak out as ordinary folders.
function refreshSystemRoots(tree) {
  const topLevel = tree?.[0]?.children || [];
  const legacyRoles = ['1', '2', '3'];
  // Position is only a fallback for trees with neither folderType nor the
  // classic IDs; otherwise an unknown root at index 0 would claim the bar role.
  const hasLegacyIds = topLevel.some(node => legacyRoles.includes(node.id));
  const roleOf = (node, index) => {
    switch (node.folderType) {
      case 'bookmarks-bar': return '1';
      case 'other': return '2';
      case 'mobile': return '3';
      case 'managed': return null;
    }
    if (legacyRoles.includes(node.id)) return node.id;
    return hasLegacyIds ? null : (legacyRoles[index] || null);
  };
  // When local and account roots coexist, exactly one root per role is
  // synced. Mapping both to one role would move local-only bookmarks into the
  // account on the next round trip, and full mirrors would prune them.
  // The previously chosen root stays primary while it exists. It is only
  // replaced when it disappeared, or when its bookmarks moved to the twin:
  // it went from non-empty to empty while the twin grew (Chrome moving
  // everything into account storage, or the user moving it all back). The
  // primary merely becoming empty, with the twin unchanged, is the user
  // deleting their last bookmark there; switching then would drop that
  // deletion and pull the twin's bookmarks into sync. A new choice ranks by,
  // in order: bookmarks already paired with Safari, holding any bookmarks,
  // and being the account root.
  const readSeq = tree?.rootsReadSeq;
  const isLatestTree = readSeq === undefined || readSeq >= lastRootsTreeSeq;
  if (readSeq !== undefined && isLatestTree) lastRootsTreeSeq = readSeq;
  // All descendants, so moving bookmarks into a folder of the twin counts.
  const childCount = node => {
    let count = 0;
    const walk = nodes => { for (const n of nodes || []) { count++; walk(n.children); } };
    walk(node.children);
    return count;
  };
  const pairedCount = node => {
    let count = 0;
    const walk = nodes => { for (const n of nodes || []) { if (pairedChromeIds.has(n.id)) count++; walk(n.children); } };
    walk(node.children);
    return count;
  };
  const rankKey = node => [pairedCount(node), node.children?.length ? 1 : 0, node.syncing ? 1 : 0];
  const outranks = (a, b) => {
    const [x, y] = [rankKey(a), rankKey(b)];
    for (let i = 0; i < x.length; i++) if (x[i] !== y[i]) return x[i] > y[i];
    return false;
  };
  const candidates = {};
  topLevel.forEach((node, index) => {
    const role = roleOf(node, index);
    if (role) (candidates[role] ||= []).push(node);
  });
  const primary = {};
  const undecided = [];
  const emptySticky = [];
  let movedToStorage = null;
  for (const [role, nodes] of Object.entries(candidates)) {
    const sticky = nodes.find(node => node.id === stickyPrimaryRoots[role]);
    let movedAway = false;
    if (sticky && childCount(sticky) === 0) {
      const before = lastRootChildCounts[sticky.id];
      if (before === undefined) {
        // Remembered before child counts were recorded: only Chrome's own
        // migration into account storage can be recognized.
        movedAway = !sticky.syncing && nodes.some(node => node !== sticky && node.syncing && childCount(node) > 0);
      } else {
        // The twin must have gained at least what the primary lost; a
        // smaller gain (e.g. Chrome sync adding one remote bookmark while the
        // user deleted everything locally) is not a move.
        movedAway = before > 0 && nodes.some(node => node !== sticky && childCount(node) - (lastRootChildCounts[node.id] || 0) >= before);
      }
    }
    if (sticky && !movedAway) {
      primary[role] = sticky;
      if (childCount(sticky) === 0 && nodes.length > 1) emptySticky.push(role);
    } else if (nodes.length > 1 && nodes.every(node => childCount(node) === 0)) {
      undecided.push(role);
    } else {
      primary[role] = nodes.reduce((best, node) => (outranks(node, best) ? node : best));
      if (movedAway) movedToStorage = Boolean(primary[role].syncing);
    }
  }
  // When bookmarks moved to the other storage (e.g. Chrome's migration into
  // the account), roles whose remembered root is empty follow; otherwise an
  // empty local "Other Bookmarks" would stay primary while Chrome shows, and
  // the user fills, the account one.
  if (movedToStorage !== null) {
    for (const role of emptySticky) {
      const twin = candidates[role].find(node => Boolean(node.syncing) === movedToStorage);
      if (twin) primary[role] = twin;
    }
  }
  // A role whose roots are all empty follows the storage (local or account)
  // already chosen for the other roles, so a user's bookmarks are not split
  // between the device and the Google account.
  const chosenStorage = Object.values(primary).map(node => Boolean(node.syncing));
  for (const role of undecided) {
    const nodes = candidates[role];
    primary[role] = (chosenStorage.length && nodes.find(node => Boolean(node.syncing) === chosenStorage[0]))
      || nodes.reduce((best, node) => (outranks(node, best) ? node : best));
  }
  if (primaryRootsLoaded && topLevel.length && isLatestTree) {
    const counts = Object.fromEntries(topLevel.map(node => [node.id, childCount(node)]));
    const countsChanged = Object.keys({ ...counts, ...lastRootChildCounts }).some(id => counts[id] !== lastRootChildCounts[id]);
    if (countsChanged) {
      lastRootChildCounts = counts;
      chrome.storage?.local?.set({ bookmarkRootChildCounts: counts })?.catch(() => {});
    }
  }
  // A stale tree may resolve roles for its caller but never changes the
  // remembered choice.
  if (primaryRootsLoaded && topLevel.length && isLatestTree) {
    const chosen = Object.fromEntries(Object.entries(primary).map(([role, node]) => [role, node.id]));
    const changed = Object.keys({ ...chosen, ...stickyPrimaryRoots }).some(role => chosen[role] !== stickyPrimaryRoots[role]);
    if (changed) {
      stickyPrimaryRoots = chosen;
      chrome.storage?.local?.set({ bookmarkPrimaryRoots: chosen })?.catch(() => {});
    }
  }
  if (topLevel.length) {
    const primaryIds = new Map(Object.entries(primary).map(([role, node]) => [node.id, role]));
    rootRoleById = new Map(topLevel.map(node => [node.id, primaryIds.get(node.id) || null]));
    systemRootsResolved = true;
  }
  localBarId = primary['1']?.id || localBarId || '1';
  localOtherId = primary['2']?.id || localOtherId || '2';
  localMobileId = primary['3']?.id || '3';
  // Users cannot create nodes directly under '0', so every top-level node is a system root.
  systemRoots = new Set(['0', localBarId, localOtherId, localMobileId, ...topLevel.map(node => node.id)]);
  reportSystemRootsIfChanged(topLevel);
  return topLevel;
}

// Diagnostics for root swaps. Only structural metadata leaves the browser:
// never titles, URLs or the tree itself, because the app persists it in logs.
// Reports are serialized: tree reads happen concurrently, and parallel
// storage round-trips would report the same change twice.
let rootReportQueue = Promise.resolve();
let lastReportedRootSignature = null;
function reportSystemRootsIfChanged(topLevel) {
  rootReportQueue = rootReportQueue.then(() => reportSystemRootsNow(topLevel)).catch(() => {});
}

async function reportSystemRootsNow(topLevel) {
  if (!topLevel.length) return;
  const roots = topLevel.map(node => ({
    id: node.id,
    type: node.folderType || 'unknown',
    role: rootRoleById.get(node.id) || 'unsynced',
    syncing: Boolean(node.syncing),
    children: node.children?.length ?? 0
  }));
  // Persisted so MV3 worker restarts do not re-report an unchanged layout.
  const signature = roots.map(root => `${root.id}:${root.type}:${root.role}:${root.syncing}`).join('|');
  if (signature === lastReportedRootSignature) return;
  const stored = await chrome.storage.local.get('bookmarkRootSignature').catch(() => ({}));
  lastReportedRootSignature = signature;
  if (stored.bookmarkRootSignature === signature) return;
  await chrome.storage.local.set({ bookmarkRootSignature: signature }).catch(() => {});
  send({
    type: 'sync',
    browser: CURRENT_BROWSER_ID,
    category: 'bookmark_roots',
    payload: { kind: 'raw', raw: { roots, previous: stored.bookmarkRootSignature || null } },
    messageId: crypto.randomUUID(),
    timestamp: Date.now()
  });
}


if (chrome.bookmarks) {
  primaryRootsReady.then(() => getTreeForRoots()).then(refreshSystemRoots).catch(()=>{});
}

let isApplyingSync = false;
// Overlapping writes (an incoming removal during a long apply) each hold the
// flag; it clears only after the last one, so neither unmasks the other's
// self-generated bookmark events.
let applyingSyncCount = 0;
function beginApplyingSync() {
  applyingSyncCount++;
  isApplyingSync = true;
}
function endApplyingSyncLater() {
  setTimeout(releaseApplyingSyncNow, 2000);
}
function releaseApplyingSyncNow() {
  applyingSyncCount = Math.max(0, applyingSyncCount - 1);
  isApplyingSync = applyingSyncCount > 0;
  runQueuedBookmarkSync();
}
// Bookmark writes (and bookmark pulls) that arrived while another write was
// being applied, in arrival order. None is dropped or replaced: a removal
// batch followed by a full sync must both run, in that order.
const queuedBookmarkSyncs = [];
function runQueuedBookmarkSync() {
  // A write sets the flag synchronously when it starts, which stops the
  // loop; a pull does not, so the next item can follow it.
  while (!isApplyingSync && queuedBookmarkSyncs.length) {
    const next = queuedBookmarkSyncs.shift();
    next();
  }
}

function localizedRootLabels() {
  return {
    bar: new Set(['browsync-root-bar', 'browsync-root-favorites', 'Bookmarks Bar', 'Bookmarks Toolbar', 'Favorites', 'Favorites Bar', 'Favorites bar', '书签栏', '收藏夹栏', '書籤列', '收藏列', 'Lesezeichenleiste', 'Barra de favoritos', 'Barre de favoris', 'Barra dei preferiti', 'ブックマークバー', '북마크 바']),
    menu: new Set(['browsync-root-menu', 'Bookmarks Menu', '书签菜单', '書籤選單', 'Lesezeichenmenü', 'Menú de marcadores', 'Menu des signets', 'Menu preferiti', 'ブックマークメニュー', '북마크 메뉴']),
    other: new Set(['browsync-root-other', 'Other Bookmarks', 'Other Favorites', 'Other favorites', 'Other Favourites', 'Other favourites', '其他书签', '其他收藏夹', '其他收藏', '其他書籤', 'Andere Lesezeichen', 'Otros marcadores', 'Autres favoris', 'Altri preferiti', 'その他のブックマーク', '기타 북마크']),
    mobile: new Set(['browsync-root-mobile', 'Mobile Bookmarks', '移动书签', '移动设备书签', '行動裝置書籤', 'Mobile Lesezeichen', 'Marcadores móviles', 'Favoris mobiles', 'Segnalibri mobili', 'モバイルブックマーク', '모바일 북마크'])
  };
}

async function findBookmarkFolderByPath(folderPath) {
  if (!folderPath) return null;
  const parts = folderPath.split('/').map(p => p.trim()).filter(Boolean);
  if (!parts.length) return null;
  await primaryRootsReady;
  const tree = await getTreeForRoots();
  refreshSystemRoots(tree);
  let candidates = tree[0]?.children || [];
  let current = null;
  const labels = localizedRootLabels();
  const first = parts[0];
  if (labels.bar.has(first)) current = candidates.find(node => node.id === localBarId) || null;
  else if (labels.menu.has(first) || labels.other.has(first)) current = candidates.find(node => node.id === localOtherId) || null;
  else if (labels.mobile.has(first)) current = candidates.find(node => node.id === localMobileId) || null;

  if (current) {
    parts.shift();
    if (!parts.length) return current;
    candidates = await chrome.bookmarks.getChildren(current.id).catch(() => []);
  }

  for (const part of parts) {
    const matches = candidates.filter(node => !node.url && node.title === part);
    if (matches.length !== 1) return null;
    current = matches[0];
    candidates = await chrome.bookmarks.getChildren(current.id).catch(() => []);
  }
  return current;
}

async function currentBookmarkSyncFolderPath() {
  const { appSettings } = await chrome.storage.local.get('appSettings').catch(() => ({}));
  const folders = appSettings?.bookmarkSyncFolders || {};
  return folders[CURRENT_BROWSER_ID] || folders[DETECTED_BROWSER] || null;
}

async function isNodeInsideFolder(nodeId, folderId) {
  if (!folderId) return true;
  let currentId = nodeId;
  const seen = new Set();
  while (currentId && !seen.has(currentId)) {
    if (currentId === folderId) return true;
    seen.add(currentId);
    const nodes = await chrome.bookmarks.get(currentId).catch(() => []);
    const node = nodes && nodes[0];
    if (!node) return false;
    currentId = node.parentId;
  }
  return false;
}

async function isBookmarkEventInSelectedFolder(event = {}) {
  const folderPath = await currentBookmarkSyncFolderPath();
  if (!folderPath) return true;
  const folder = await findBookmarkFolderByPath(folderPath);
  if (!folder) {
    send({
      type: 'sync',
      browser: CURRENT_BROWSER_ID,
      category: 'bookmark_folder_missing',
      payload: { kind: 'raw', raw: { folder: folderPath } },
      messageId: crypto.randomUUID(),
      timestamp: Date.now()
    });
    return false;
  }
  const ids = [event.id, event.parentId, event.oldParentId, event.newParentId].filter(Boolean);
  for (const id of ids) {
    if (await isNodeInsideFolder(id, folder.id)) return true;
  }
  return false;
}

// True when nodeId lives under a synced root. Bookmarks in unsynced roots
// must never be reported to the app (which falls back to URL/title matching)
// nor touched by incoming syncs.
async function isUnderSyncedRoot(nodeId) {
  let currentId = nodeId;
  const seen = new Set();
  while (currentId && currentId !== '0' && !seen.has(currentId)) {
    seen.add(currentId);
    const node = (await chrome.bookmarks.get(currentId).catch(() => []))[0];
    if (!node) return false;
    if (node.parentId === '0') {
      // Judge by the roles in effect when the event happened: removing the
      // last bookmark of the primary root may make its twin primary on the
      // next resolution, but that removal still belongs to the synced root.
      // Resolve only if roles were never resolved or this root is unknown.
      if (!systemRootsResolved || !rootRoleById.has(node.id)) {
        await primaryRootsReady;
        // A worker woken by this very event has no roles yet; the persisted
        // choice reflects the state before the event (the removal may have
        // just emptied the primary root).
        if (!systemRootsResolved && Object.keys(stickyPrimaryRoots).length) {
          return Object.values(stickyPrimaryRoots).includes(node.id);
        }
        // Always a fresh read: a cached tree could persist a stale choice.
        refreshSystemRoots(await getTreeForRoots());
      }
      return Boolean(rootRoleById.get(node.id));
    }
    currentId = node.parentId;
  }
  return false;
}

// IDs of every node under a synced root in the given tree.
function syncedNodeIds(tree) {
  const ids = new Set();
  const collect = nodes => {
    for (const node of nodes || []) {
      ids.add(node.id);
      collect(node.children);
    }
  };
  for (const root of tree?.[0]?.children || []) {
    if (rootRoleById.get(root.id)) collect(root.children);
  }
  return ids;
}

function queueRemovedBookmark(deletedBm) {
  // MV3 may suspend this worker before an in-memory timer fires. The native
  // app already buffers per-browser events and guards large deletion bursts.
  console.log('[BrowSync] Explicit bookmark removed:', deletedBm);
  send({
    type: 'sync',
    browser: CURRENT_BROWSER_ID,
    category: 'bookmarks_removed',
    payload: { kind: 'bookmarksRemoved', bookmarksRemoved: deletedBm },
    messageId: crypto.randomUUID(),
    timestamp: Date.now()
  });
}

async function handleBookmarkChange(reason, event = {}) {
  if (isApplyingSync) return;
  if (!(await isBookmarkEventInSelectedFolder(event))) {
    console.log(`[BrowSync] Ignored bookmark ${reason} outside selected sync folder`);
    return;
  }
  
  send({
    type: 'sync',
    browser: CURRENT_BROWSER_ID,
    category: 'bookmark_changed',
    payload: { kind: 'raw', raw: { reason } },
    messageId: crypto.randomUUID(),
    timestamp: Date.now()
  });
}

if (chrome.bookmarks) {
  chrome.bookmarks.onCreated.addListener((id, node) => handleBookmarkChange('created', { id, parentId: node?.parentId }));
  chrome.bookmarks.onRemoved.addListener(async (id, removeInfo) => {
    if (isApplyingSync) return;
    // Chrome swapping its permanent folders is not a user deletion.
    if (systemRoots.has(id) || removeInfo.parentId === '0') return;
    if (!(await isUnderSyncedRoot(removeInfo.parentId))) return;
    if (!(await isBookmarkEventInSelectedFolder({ id, parentId: removeInfo.parentId || removeInfo.node?.parentId }))) {
      console.log('[BrowSync] Ignored bookmark removal outside selected sync folder');
      return;
    }
    
    // Explicitly send the removed bookmark to the server
    const storageData = await chrome.storage.local.get('syncIdMap');
    const syncIdMap = storageData.syncIdMap || {};
    const chromeToSafariId = new Map();
    for (const [safariId, chromeId] of Object.entries(syncIdMap)) {
      if (!chromeToSafariId.has(chromeId)) {
        chromeToSafariId.set(chromeId, safariId);
      }
    }
    
    const mappedId = chromeToSafariId.get(id) || id;
    // Also map the parentId so Safari can use it for context
    const rawParentId = removeInfo.parentId || removeInfo.node?.parentId;
    let mappedParentId = rawParentId;
    if (rootRoleById.get(rawParentId)) mappedParentId = rootRoleById.get(rawParentId);

    const deletedBm = {
      id: mappedId,
      title: removeInfo.node.title,
      url: removeInfo.node.url || null,
      isFolder: !removeInfo.node.url,
      parentId: mappedParentId || null,
      sourceBrowser: CURRENT_BROWSER_ID
    };
    
    queueRemovedBookmark(deletedBm);
    
    // Do not also emit bookmark_changed: this explicit removal is authoritative.
  });
  chrome.bookmarks.onChanged.addListener((id) => handleBookmarkChange('changed', { id }));
  chrome.bookmarks.onMoved.addListener((id, moveInfo) => handleBookmarkChange('moved', { id, oldParentId: moveInfo?.oldParentId, newParentId: moveInfo?.parentId }));
}

// ─── Cookies ─────────────────────────────────────────────────────────────────

// "cookies" is an optional permission: chrome.cookies is undefined until the
// user grants it. It becomes defined immediately once granted, even in an
// already-running service worker, so this must be re-attempted after grant
// (see attachOptionalEventListeners below) rather than only at startup.
let cookiesListenerAttached = false;
function attachCookiesListener() {
  if (cookiesListenerAttached || !chrome.cookies) return;
  cookiesListenerAttached = true;
  chrome.cookies.onChanged.addListener(async ({ cookie, removed, cause }) => {
    if (!(await canSyncState())) return;
    if (cause !== 'explicit' && cause !== 'overwrite') return;

    const cookieKey = cookieIdentity(cookie);
    if (applyingCookies.has(cookieKey)) return;
    const updatedAt = Date.now();
    await setCookieTimestamp(cookie, updatedAt);

    const payloadCookie = {
      name: cookie.name,
      value: cookie.value,
      domain: cookie.domain,
      path: cookie.path,
      expirationDate: cookie.expirationDate,
      secure: cookie.secure,
      httpOnly: cookie.httpOnly,
      hostOnly: cookie.hostOnly,
      sameSite: cookie.sameSite,
      removed: removed,
      updatedAt
    };

    const tKey = `tombstone_cookies_${cookieIdentity(cookie)}`;
    if (removed) {
      chrome.storage.local.set({ [tKey]: payloadCookie }).catch(() => { });
    } else {
      chrome.storage.local.remove(tKey).catch(() => { });
    }
    cookieSyncQueue.set(cookieKey, payloadCookie);
    if (cookieSyncTimer) clearTimeout(cookieSyncTimer);
    cookieSyncTimer = setTimeout(() => {
      const cookiesToSend = Array.from(cookieSyncQueue.values());
      cookieSyncQueue.clear();
      send({
        type: 'sync',
        browser: CURRENT_BROWSER_ID,
        site: '*',
        category: 'cookies',
        payload: {
          kind: 'cookies',
          cookies: cookiesToSend
        },
        messageId: crypto.randomUUID(),
        timestamp: Date.now()
      });
    }, 500);
  });
}
attachCookiesListener();

async function applyCookieSync(cookies, sourceBrowser = 'unknown') {
  if (!(await canSyncState())) return;
  let successCount = 0;
  let failCount = 0;
  const failures = [];
  if (!chrome.cookies) return;
  const localTimestamps = await getCookieTimestamps();
  const localCookies = new Set((await chrome.cookies.getAll({})).map(cookieIdentity));
  for (const cookie of cookies) {
    const baseDomain = cookie.domain.startsWith('.') ? cookie.domain.slice(1) : cookie.domain;
    const isIPAddress = /^\d{1,3}(?:\.\d{1,3}){3}$/.test(baseDomain);
    const urlsToTry = (baseDomain === 'localhost' || isIPAddress)
      ? [`http://${baseDomain}${cookie.path || '/'}`, `https://${baseDomain}${cookie.path || '/'}`]
      : [`https://${baseDomain}${cookie.path || '/'}`];
      
    const cookieKey = cookieIdentity(cookie);
    const updatedAt = cookie.updatedAt || Date.now();

    // Never overwrite or delete an existing local cookie with a snapshot that
    // is not newer. This preserves a freshly authenticated session when a
    // second browser reloads and returns the same (or older) state.
    if (localCookies.has(cookieKey) && (localTimestamps[cookieKey] || 0) >= updatedAt) {
      console.warn(`[BrowSync] Ignored stale remote cookie ${cookie.removed ? 'deletion' : 'update'}: ${cookie.domain}${cookie.path || '/'}::${cookie.name} from ${sourceBrowser}`);
      continue;
    }
    applyingCookies.add(cookieKey);

    if (cookie.removed) {
      console.warn(`[BrowSync] Applying remote cookie deletion: ${cookie.domain}${cookie.path || '/'}::${cookie.name} from ${sourceBrowser}`);
      try {
        for (const testUrl of urlsToTry) {
          await chrome.cookies.remove({ url: testUrl, name: cookie.name }).catch(() => {});
        }
        successCount++;
        await setCookieTimestamp(cookie, updatedAt);
        const tKey = `tombstone_cookies_${cookieIdentity(cookie)}`;
        await chrome.storage.local.set({ [tKey]: { ...cookie, updatedAt } }).catch(() => {});
      } catch (e) {
        failCount++;
        failures.push(`${cookie.domain}${cookie.path}::${cookie.name} remove failed`);
      }
      setTimeout(() => applyingCookies.delete(cookieKey), 1000);
      continue;
    } else {
      console.warn(`[BrowSync] Applying remote cookie update: ${cookie.domain}${cookie.path || '/'}::${cookie.name} from ${sourceBrowser}`);
      const tKey = `tombstone_cookies_${cookieIdentity(cookie)}`;
      chrome.storage.local.remove(tKey).catch(() => { });
    }

    const base = {
      name: cookie.name,
      value: cookie.value,
      path: cookie.path || '/',
      httpOnly: cookie.httpOnly,
    };
    // Session cookies have no expirationDate. Omitting the field (rather than
    // passing undefined) is required by some browser cookie API bridges.
    if (Number.isFinite(cookie.expirationDate)) base.expirationDate = cookie.expirationDate;
    const validSameSite = ['no_restriction', 'lax', 'strict'];
    if (cookie.sameSite && validSameSite.includes(cookie.sameSite)) {
      base.sameSite = cookie.sameSite;
    }

    const cleanDomain = cookie.domain.startsWith('.') ? cookie.domain.slice(1) : cookie.domain;
    const baseOpts = { ...base, secure: cookie.secure };
    if (baseOpts.sameSite === 'no_restriction') baseOpts.secure = true;
    
    // Workarounds for Safari 18.0+ bugs and strict localhost cookie policies
    if (cleanDomain === 'localhost' || cleanDomain.startsWith('127.0.0.')) {
      delete baseOpts.expirationDate; // Safari 18.0+ fails if expirationDate is set
      baseOpts.secure = false;        // Safari rejects secure cookies on http://localhost
      delete baseOpts.sameSite;       // sameSite often requires secure, creating a conflict
    }

    let strategies;
    if (cookie.hostOnly === true) {
      strategies = [{ ...baseOpts }];
    } else if (cookie.hostOnly === false) {
      strategies = cookie.domain.startsWith('.')
        ? [
          { ...baseOpts, domain: cookie.domain },
          { ...baseOpts, domain: cleanDomain },
          { ...baseOpts, secure: !baseOpts.secure, domain: cookie.domain },
          { ...baseOpts }
        ]
        : [
          { ...baseOpts, domain: cleanDomain },
          { ...baseOpts },
          { ...baseOpts, secure: !baseOpts.secure }
        ];
    } else {
      strategies = cookie.domain.startsWith('.')
        ? [
          { ...baseOpts, domain: cookie.domain },
          { ...baseOpts, domain: cleanDomain },
          { ...baseOpts },
          { ...baseOpts, secure: !baseOpts.secure, domain: cookie.domain }
        ]
        : [
          { ...baseOpts },
          { ...baseOpts, domain: cleanDomain },
          { ...baseOpts, secure: !baseOpts.secure }
        ];
    }

    let ok = false;
    let appliedCookie = null;
    for (const testUrl of urlsToTry) {
      if (ok) break;
      for (const opts of strategies) {
        try {
          const result = await chrome.cookies.set({ ...opts, url: testUrl });
          if (result) { ok = true; appliedCookie = result; break; }
        } catch (_) { }
      }
    }
    if (ok) {
      successCount++;
      await setCookieTimestamp(cookie, updatedAt);
      if (cookie.domain.includes('github.com')) {
        failures.push(`ok ${appliedCookie?.domain || cookie.domain}${appliedCookie?.path || cookie.path}::${cookie.name} hostOnly=${appliedCookie?.hostOnly}`);
      }
    } else {
      failCount++;
      failures.push(`${cookie.domain}${cookie.path}::${cookie.name}`);
      console.warn(`[BrowSync] Failed to set cookie: ${cookie.name} @ ${cookie.domain} secure=${cookie.secure} httpOnly=${cookie.httpOnly} sameSite=${cookie.sameSite}`);
    }
    setTimeout(() => applyingCookies.delete(cookieKey), 1000);
  }
  if (successCount === 0 && failCount === 0) return;
  console.log(`[BrowSync] Cookie sync done: ${successCount} set, ${failCount} failed`);
  send({
    type: 'sync',
    browser: CURRENT_BROWSER_ID,
    category: 'cookie_apply_result',
    payload: {
      kind: 'raw',
      raw: {
        summary: `${successCount} set, ${failCount} failed${failures.length ? `; details: ${failures.slice(0, 8).join(', ')}` : ''}`
      }
    },
    messageId: crypto.randomUUID(),
    timestamp: Date.now()
  });
}

// ─── Content script relay (localStorage / sessionStorage) ───────────────────

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === 'UPDATE_SETTING') {
    send({
      type: 'settings',
      browser: CURRENT_BROWSER_ID,
      payload: { kind: 'raw', raw: { [message.setting]: message.value } },
      messageId: crypto.randomUUID(),
      timestamp: Date.now()
    });
    // Await the storage write (and the reconcile it triggers) before
    // responding. The popup's updateOptionalFeature() awaits this response
    // before requesting the optional permission, so by the time
    // chrome.permissions.request() resolves and fires permissions.onAdded,
    // this write has already landed — otherwise reconcileOptionalFeaturePermissions
    // (triggered by onAdded) can read stale settings and immediately revoke
    // the permission that was just granted.
    (async () => {
      const { appSettings } = await chrome.storage.local.get('appSettings');
      let settings = appSettings || {};
      const browserId = DETECTED_BROWSER;
      if (message.setting === 'bookmarkSync') {
         if (!settings.bookmarkParticipatingBrowsers) settings.bookmarkParticipatingBrowsers = {};
         settings.bookmarkParticipatingBrowsers[browserId] = message.value;
      } else if (message.setting === 'stateSync') {
        if (!settings.stateParticipatingBrowsers) settings.stateParticipatingBrowsers = {};
        settings.stateParticipatingBrowsers[browserId] = message.value;
      } else if (message.setting === 'tabSharing') {
         if (!settings.tabSharingParticipatingBrowsers) settings.tabSharingParticipatingBrowsers = {};
         settings.tabSharingParticipatingBrowsers[browserId] = message.value;
      } else if (message.setting === 'routerDefault' && message.value === true) {
         settings.routerDefault = browserId;
      }
      await chrome.storage.local.set({ appSettings: settings });
      await reconcileStateContentScript();
      sendResponse({ ok: true });
    })();
    return true;
  }
  
  if (message.type === 'UPDATE_SITE_SETTING') {
    send({
      type: 'settings', browser: CURRENT_BROWSER_ID,
      payload: { kind: 'raw', raw: { toggleSiteSync: { domain: message.domain, value: message.value } } },
      messageId: crypto.randomUUID(), timestamp: Date.now()
    });
    sendResponse({ ok: true });
    return true;
  }
  
  if (message.type === 'UPDATE_SITE_STRATEGY') {
    send({
      type: 'settings', browser: CURRENT_BROWSER_ID,
      payload: { kind: 'raw', raw: { updateSiteStrategy: { domain: message.domain, strategy: message.strategy } } },
      messageId: crypto.randomUUID(), timestamp: Date.now()
    });
    sendResponse({ ok: true });
    return true;
  }
  
  if (message.type === 'UPDATE_SITE_SOURCE_BROWSER') {
    send({
      type: 'settings', browser: CURRENT_BROWSER_ID,
      payload: { kind: 'raw', raw: { updateSiteSourceBrowser: { domain: message.domain, browser: message.browser } } },
      messageId: crypto.randomUUID(), timestamp: Date.now()
    });
    sendResponse({ ok: true });
    return true;
  }
  
  if (message.type === 'SYNC_SITE_DATA') {
    requestSiteStateSync(message.domain)
      .then(didRequest => sendResponse({ ok: didRequest }))
      .catch(error => sendResponse({ ok: false, error: String(error) }));
    return true;
  }
  

  if (message.type === 'OPEN_SETTINGS') {
    send({
      type: 'open_settings',
      browser: CURRENT_BROWSER_ID,
      messageId: crypto.randomUUID(),
      timestamp: Date.now()
    });
    sendResponse({ ok: true });
    return true;
  }

  if (message.type === 'OPEN_URL_IN_BROWSER') {
    send({
      type: 'open_url',
      browser: CURRENT_BROWSER_ID,
      payload: { kind: 'raw', raw: { targetBrowser: message.browser, url: message.url } },
      messageId: crypto.randomUUID(),
      timestamp: Date.now()
    });
    sendResponse({ ok: true });
    return true;
  }

  if (message.type === 'PULL_TAB_SHARING') {
    send({
      type: 'pull',
      browser: CURRENT_BROWSER_ID,
      category: 'tabSharing',
      messageId: crypto.randomUUID(),
      timestamp: Date.now()
    });
    sendResponse({ ok: true });
    return true;
  }

  (async () => {
    if (message.source !== 'browsync-content') return;
    if (message.type === 'heartbeat_ping') return;
    if (message.type === 'backup_storage') {
      if (!(await canSyncState())) return;
      const { storageType, items } = message;
      if (!items || items.length === 0) return;
      const origin = items[0].origin;
      if (!origin) return;
      const key = `backup_${storageType}_${origin}`;
      await chrome.storage.local.set({ [key]: items }).catch(e => console.warn('[BrowSync] Failed to store backup items:', e));
      console.log(`[BrowSync] Passively accumulated ${items.length} ${storageType} items for ${origin}`);
      return;
    }

    if (message.type !== 'storage_change') return;
    if (!(await canSyncState())) return;

    // Record tombstones for deleted items
    for (const item of message.items) {
      const tKey = `tombstone_${message.storageType}_${item.origin}::${item.key}`;
      if (item.value === null || item.key === '__clear__') {
        await chrome.storage.local.set({ [tKey]: { ...item, timestamp: Date.now() } });
      } else {
        await chrome.storage.local.remove(tKey).catch(() => {});
      }
    }

    send({
      type: 'sync',
      browser: DETECTED_BROWSER,
      site: sender.tab?.url ? safeHostname(sender.tab.url) : '*',
      category: message.storageType,
      payload: {
        kind: message.storageType,
        [message.storageType]: message.items,
      },
      messageId: crypto.randomUUID(),
      timestamp: Date.now(),
    });
    sendResponse({ ok: true });
  })();
  return true;
});

async function broadcastToContentScripts(category, items, site) {
  if (!(await canSyncState())) return;
  if (!chrome.tabs) return;
  const tabs = await chrome.tabs.query({});
  for (const tab of tabs) {
    if (!tab.url || !tab.id) continue;
    if (site && site !== '*' && safeHostname(tab.url) !== site) continue;
    try {
      await chrome.tabs.sendMessage(tab.id, {
        source: 'browsync-background',
        type: 'apply_storage',
        storageType: category,
        items,
      });
    } catch (_) { }
  }
}

// ─── Tabs ────────────────────────────────────────────────────────────────────

let tabDebounceTimer = null;
const recentSitePulls = new Map();
const pendingSiteReloads = new Map();
const navigationSyncSites = new Map();

function syncDomainForHostname(hostname) {
  const parts = hostname.toLowerCase().split('.');
  if (parts.length <= 2 || /^\d{1,3}(\.\d{1,3}){3}$/.test(hostname)) return hostname;
  const secondLevel = parts[parts.length - 2];
  if (['co', 'com', 'org', 'net', 'edu', 'gov', 'ac', 'ne'].includes(secondLevel)) {
    return parts.slice(-3).join('.');
  }
  return parts.slice(-2).join('.');
}

function isSiteStateSyncEnabled(site, appSettings) {
  const syncDisabledDomains = appSettings.syncDisabledDomains || [];
  const isSystemDisabled = syncDisabledDomains.some(domain =>
    syncDomainForHostname(String(domain || '').replace(/^\./, '').toLowerCase()) === site
  );
  if (isSystemDisabled) return false;

  const websiteSettings = appSettings.websiteSettings || [];
  const isListed = websiteSettings.some(setting =>
    syncDomainForHostname(String(setting.domain || '').replace(/^\./, '').toLowerCase()) === site
  );
  return appSettings.websiteListPolicy === 'block_list' ? !isListed : isListed;
}

function cookieMatchesSite(cookie, site) {
  const domain = (cookie.domain || '').replace(/^\./, '').toLowerCase();
  return domain === site || site.endsWith(`.${domain}`);
}

async function showStateSyncUpdatePrompt(cookies) {
  const liveCookies = cookies.filter(cookie => cookie.removed !== true);
  if (liveCookies.length === 0) return;

  // A state update can arrive long after a tab's navigation pull completed.
  // Do not rely solely on pendingSiteReloads here: it is only a pull-tracking
  // aid, not a list of currently open pages. Otherwise Safari login changes
  // reach Chrome and are applied, but an already-open matching tab never gets
  // the reload banner.
  const updatedSites = new Set(liveCookies.map(cookie =>
    syncDomainForHostname((cookie.domain || '').replace(/^\./, '').toLowerCase())
  ));
  const tabIdsToPrompt = new Set();

  for (const [tabId, site] of pendingSiteReloads) {
    if (!updatedSites.has(site)) continue;
    pendingSiteReloads.delete(tabId);
    tabIdsToPrompt.add(tabId);
  }

  const openTabs = await chrome.tabs.query({}).catch(() => []);
  for (const tab of openTabs) {
    if (!tab.id || !tab.url) continue;
    if (updatedSites.has(syncDomainForHostname(safeHostname(tab.url)))) {
      tabIdsToPrompt.add(tab.id);
    }
  }

  await Promise.all([...tabIdsToPrompt].map(async tabId => {
    const tab = await chrome.tabs.get(tabId).catch(() => null);
    if (!tab?.url || !updatedSites.has(syncDomainForHostname(safeHostname(tab.url)))) return;
    await chrome.tabs.sendMessage(tabId, {
      source: 'browsync-background',
      type: 'state_sync_updated'
    }).catch(() => {});
  }));
}

async function requestCurrentSiteState(tabId, url) {
  if (!(await canSyncState())) return;
  if (!url.startsWith('http://') && !url.startsWith('https://')) return;
  const site = syncDomainForHostname(safeHostname(url));
  if (site === '*') return;

  const now = Date.now();
  const tabSiteKey = `${tabId}:${site}`;
  if (now - (recentSitePulls.get(site) || 0) < 5000) return;
  if (navigationSyncSites.has(tabSiteKey)) return;

  const { appSettings = {} } = await chrome.storage.local.get('appSettings');
  if (appSettings.automaticSync !== true || appSettings.stateParticipatingBrowsers?.[DETECTED_BROWSER] !== true) return;
  if (!isSiteStateSyncEnabled(site, appSettings)) return;

  recentSitePulls.set(site, now);
  navigationSyncSites.set(tabSiteKey, now);
  pendingSiteReloads.set(tabId, site);
  send({
    type: 'pull', browser: CURRENT_BROWSER_ID, category: 'browserData', site,
    messageId: crypto.randomUUID(), timestamp: now
  });
}

// "tabs" is an optional permission: chrome.tabs is undefined until the user
// grants it. See attachCookiesListener above for why this is a function
// re-attempted after grant instead of a one-time top-level check.
let tabsListenerAttached = false;
function attachTabsListener() {
  if (tabsListenerAttached || !chrome.tabs) return;
  tabsListenerAttached = true;
  chrome.tabs.onUpdated.addListener(async (tabId, changeInfo, tab) => {
    if (changeInfo.status === 'loading' && tab.url) {
      pendingSiteReloads.delete(tabId);
      // Do not re-pull on form POSTs or redirects in this tab: that can replace
      // a freshly issued session cookie with stale state from another browser.
      void requestCurrentSiteState(tabId, tab.url);
    }
    if (changeInfo.status !== 'complete' || !tab.url) return;
    if (!(await canShareTabs())) return;
    
    if (tabDebounceTimer) clearTimeout(tabDebounceTimer);
    tabDebounceTimer = setTimeout(() => {
      send({
        type: 'sync',
        browser: DETECTED_BROWSER,
        site: safeHostname(tab.url),
        category: 'browserState',
        payload: {
          kind: 'tabs',
          tabs: [{
            id: String(tabId),
            url: tab.url,
            title: tab.title || '',
            isActive: tab.active,
            windowId: String(tab.windowId),
            index: tab.index,
            favIconURL: tab.favIconUrl,
            sourceBrowser: DETECTED_BROWSER,
            capturedAt: Date.now(),
          }]
        },
        messageId: crypto.randomUUID(),
        timestamp: Date.now(),
      });
    }, 10000);
  });

  chrome.tabs.onRemoved.addListener((tabId) => {
    pendingSiteReloads.delete(tabId);
    for (const key of navigationSyncSites.keys()) {
      if (key.startsWith(`${tabId}:`)) navigationSyncSites.delete(key);
    }
  });
}
attachTabsListener();

// ─── Alarms ──────────────────────────────────────────────────────────────────

if (chrome.alarms) {
  chrome.alarms.onAlarm.addListener(async (alarm) => {
    if (alarm.name === HEARTBEAT_ALARM) {
      send({ type: 'heartbeat', timestamp: Date.now() });
    } else if (alarm.name === RECONNECT_ALARM) {
      await connect();
    }
  });
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

function safeHostname(urlStr) {
  try { return new URL(urlStr).hostname; } catch { return '*'; }
}

// ─── Startup ─────────────────────────────────────────────────────────────────

// Users can change optional permissions from the browser's extension settings.
// Keep the persistent content script in sync even when the popup is closed.
if (chrome.permissions?.onAdded) {
  chrome.permissions.onAdded.addListener(() => {
    attachCookiesListener();
    attachTabsListener();
    void reconcileStateContentScript();
  });
}
if (chrome.permissions?.onRemoved) {
  chrome.permissions.onRemoved.addListener(() => void reconcileStateContentScript());
}

chrome.runtime.onStartup.addListener(() => {
  chrome.storage.local.set({ wsState: 'closed' }).catch(() => { }).then(() => {
    void reconcileStateContentScript();
    connect();
  });
});
chrome.runtime.onInstalled.addListener(() => {
  void reconcileStateContentScript();
  connect();
});
connect();
