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

function cookieIdentity(cookie) {
  return `${cookie.domain}::${cookie.path || '/'}::${cookie.name}`;
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
  const ua = navigator.userAgent;
  if (ua.includes('Edg/')) return 'edge';
  if (ua.includes('Safari/') && !ua.includes('Chrome/')) return 'safari';
  if (ua.includes('Brave/') || navigator.brave) return 'brave';
  // Arc detection: check for Arc-specific APIs
  return 'chrome';
}

const DETECTED_BROWSER = detectBrowserId();
const INSTANCE_ID = `${DETECTED_BROWSER}-main`;

// ─── WebSocket management ────────────────────────────────────────────────────

let ws = null;
let isConnecting = false;
let reconnectDelay = 1000;

async function connect() {
  if (isConnecting || (ws && ws.readyState === WebSocket.OPEN)) return;
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

    send({ type: 'register', browser: DETECTED_BROWSER, instanceId: INSTANCE_ID });
    send({ type: 'pull' });

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
      handleIncoming(msg);
    } catch (e) {
      console.warn('[BrowSync] Parse error:', e);
    }
  };
}

function send(message) {
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(message));
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
    chrome.action.setBadgeText({ text: 'SYNC' });
    chrome.action.setBadgeBackgroundColor({ color: '#3b82f6' });
    chrome.action.setBadgeTextColor({ color: '#ffffff' });
    setTimeout(() => updateBadge(), 2000);
    return;
  }
  
  if (ws && ws.readyState === WebSocket.OPEN) {
    chrome.action.setBadgeText({ text: 'ON' }).catch(() => {});
    chrome.action.setBadgeBackgroundColor({ color: '#22c55e' }).catch(() => {});
    chrome.action.setBadgeTextColor({ color: '#ffffff' }).catch(() => {});
  } else {
    chrome.action.setBadgeText({ text: 'OFF' }).catch(() => {});
    chrome.action.setBadgeBackgroundColor({ color: '#94a3b8' }).catch(() => {});
    chrome.action.setBadgeTextColor({ color: '#ffffff' }).catch(() => {});
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
    case 'ack':
      // Acknowledged
      break;
  }
}

async function applySync(message) {
  updateBadge('syncing');
  const { category, payload } = message;

  // Empty payload means it's a pull request from the App
  if (!payload || (payload.kind === 'raw' && Object.keys(payload.raw || {}).length === 0)) {
    await handlePullRequest(category);
    return;
  }

  switch (category) {
    case 'bookmarks':
      console.log(`[BrowSync] Applying ${(payload.bookmarks || []).length} bookmarks... isFullMirror: ${message.isFullMirror}`);
      await applyBookmarkSync(payload.bookmarks || [], message.isFullMirror);
      break;
    case 'bookmarks_removed':
      if (chrome.bookmarks && payload.bookmark) {
        const bm = payload.bookmark;
        console.log(`[BrowSync] Removing bookmark title ${bm.title}`);
        try {
          await chrome.bookmarks.removeTree(bm.id);
        } catch(e) {
          if (bm.url) {
            const results = await chrome.bookmarks.search({ url: bm.url });
            for (const r of results) {
               if (r.title === bm.title) {
                 await chrome.bookmarks.remove(r.id).catch(()=>{});
                 break;
               }
            }
          } else {
            const tree = await chrome.bookmarks.getTree();
            let foundFolderId = null;
            function searchFolder(nodes) {
              for (const n of nodes) {
                if (!n.url && n.title === bm.title) foundFolderId = n.id;
                if (n.children && !foundFolderId) searchFolder(n.children);
              }
            }
            searchFolder(tree);
            if (foundFolderId) await chrome.bookmarks.removeTree(foundFolderId).catch(()=>{});
          }
        }
      }
      break;
    case 'localStorage':
    case 'sessionStorage': {
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
      await applyCookieSync(payload.cookies || []);
      break;
  }
}

async function sendCookiesSnapshot() {
  console.log('[BrowSync] Processing full cookie pull request...');
  if (!chrome.cookies) return;
  const timestamps = await getCookieTimestamps();
  const cookies = await chrome.cookies.getAll({});
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
    if (key.startsWith('tombstone_cookies_') && value) {
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
        type: 'sync', browser: DETECTED_BROWSER, category: 'cookies',
        payload: { kind: 'cookies', cookies: chunk },
        messageId: crypto.randomUUID(), timestamp: Date.now()
      });
      await new Promise(r => setTimeout(r, 50));
    } catch (e) {
      console.error('[BrowSync] Error sending cookie chunk:', e);
    }
  }
}

async function sendStorageSnapshot(storageType) {
  if (!chrome.scripting || !chrome.tabs) return;
  const tabs = await chrome.tabs.query({});
  const allItemsMap = new Map(); // Use Map to deduplicate by key+origin

  // 1. Get from currently open tabs
  for (const tab of tabs) {
    if (!tab.id || !tab.url || tab.url.startsWith('chrome') || tab.url.startsWith('about') || tab.url.startsWith('safari-extension')) continue;
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

  // 2. Get from passive backups and tombstones in storage.local
  const allStorage = await chrome.storage.local.get(null);
  for (const [key, value] of Object.entries(allStorage)) {
    if (key.startsWith(`backup_${storageType}_`) && Array.isArray(value)) {
      value.forEach(item => {
        const mapKey = `${item.origin}::${item.key}`;
        // Add backup only if not in live tabs
        if (!allItemsMap.has(mapKey)) {
          allItemsMap.set(mapKey, { ...item, _isBackup: true });
        }
      });
    }
  }

  for (const [key, value] of Object.entries(allStorage)) {
    if (key.startsWith(`tombstone_${storageType}_`) && value) {
      const mapKey = `${value.origin}::${value.key}`;
      // If not in live tabs, OR if the current item is just a passive backup, the tombstone overrides it
      if (!allItemsMap.has(mapKey) || allItemsMap.get(mapKey)._isBackup) {
        allItemsMap.set(mapKey, value);
      }
    }
  }

  const allItems = Array.from(allItemsMap.values());
  if (allItems.length === 0) return;
  console.log(`[BrowSync] Sending ${allItems.length} ${storageType} items (including backups)...`);
  for (let i = 0; i < allItems.length; i += 200) {
    send({
      type: 'sync', browser: DETECTED_BROWSER, category: storageType,
      payload: { kind: storageType, [storageType]: allItems.slice(i, i + 200) },
      messageId: crypto.randomUUID(), timestamp: Date.now()
    });
  }
}

async function handlePullRequest(category) {
  console.log('[BrowSync] Received pull request for:', category);
  switch (category) {
    case 'bookmarks': {
      if (!chrome.bookmarks) return;
      const tree = await chrome.bookmarks.getTree();
      const flat = [];
      function traverse(nodes) {
        for (const node of nodes) {
          if (node.id !== '0') { // Skip root
            flat.push({ 
              id: node.id, 
              title: node.title, 
              url: node.url, 
              parentId: node.parentId,
              isFolder: !node.url, 
              dateAdded: node.dateAdded, 
              sourceBrowser: DETECTED_BROWSER 
            });
          }
          if (node.children) traverse(node.children);
        }
      }
      traverse(tree);
      console.log(`[BrowSync] Sending ${flat.length} bookmarks...`);
      send({
        type: 'sync', browser: DETECTED_BROWSER, category: 'bookmarks',
        payload: { kind: 'bookmarks', bookmarks: flat },
        messageId: crypto.randomUUID(), timestamp: Date.now()
      });
      break;
    }
    case 'browserData': {
      await sendCookiesSnapshot();
      await sendStorageSnapshot('localStorage');
      await sendStorageSnapshot('sessionStorage');
      break;
    }
    case 'cookies': {
      await sendCookiesSnapshot();
      break;
    }
    case 'browserState': {
      if (!chrome.tabs) return;
      const tabs = await chrome.tabs.query({});
      console.log(`[BrowSync] Sending ${tabs.length} tabs...`);
      const mapped = tabs.map(tab => ({
        id: String(tab.id), url: tab.url, title: tab.title || '', isActive: tab.active,
        windowId: String(tab.windowId), index: tab.index, favIconURL: tab.favIconUrl,
        sourceBrowser: DETECTED_BROWSER, capturedAt: Date.now()
      }));
      send({
        type: 'sync', browser: DETECTED_BROWSER, category: 'browserState',
        payload: { kind: 'tabs', tabs: mapped },
        messageId: crypto.randomUUID(), timestamp: Date.now()
      });
      break;
    }
    case 'localStorage':
    case 'sessionStorage': {
      await sendStorageSnapshot(category);
      break;
    }
  }
}

// ─── Bookmarks ───────────────────────────────────────────────────────────────

let isApplyingSync = false;

async function applyBookmarkSync(bookmarks, isFullMirror = false) {
  if (isApplyingSync) return;
  isApplyingSync = true;
  try {
  if (!chrome.bookmarks) return;

  console.log(`[BrowSync] applyBookmarkSync: ${bookmarks.length} bookmarks, isFullMirror=${isFullMirror}`);

  // STEP 1: If full mirror, snapshot current Chrome state and send back as backup
  if (isFullMirror) {
    const preTree = await chrome.bookmarks.getTree();
    const snapshot = [];
    function flatForBackup(nodes) {
      for (const node of nodes) {
        if (node.id !== '0') {
          snapshot.push({
            id: node.id,
            title: node.title || '',
            url: node.url || null,
            parentId: node.parentId || null,
            isFolder: !node.url,
            inBookmarksBar: node.parentId === '1',
            dateAdded: (node.dateAdded || Date.now()) / 1000,
            sourceBrowser: DETECTED_BROWSER
          });
        }
        if (node.children) flatForBackup(node.children);
      }
    }
    flatForBackup(preTree);
    console.log(`[BrowSync] Sending pre-sync backup: ${snapshot.length} items`);
    send({
      type: 'sync',
      browser: DETECTED_BROWSER,
      category: 'bookmark_backup',
      payload: { kind: 'bookmarks', bookmarks: snapshot },
      messageId: crypto.randomUUID(),
      timestamp: Date.now()
    });
  }

  const idMap = new Map(); // incoming id -> local chrome id
  idMap.set('1', '1'); // Map root to Bookmarks Bar
  idMap.set(null, '1');
  idMap.set(undefined, '1');

  // Build a tree to process parents before children
  const byParent = new Map();
  const rootsBar = [];
  const rootsOther = [];

  for (const bm of bookmarks) {
    if (!bm.parentId || bm.parentId === '1' || bm.parentId === '0') {
      rootsBar.push(bm);
    } else if (bm.parentId === '2') {
      rootsOther.push(bm);
    } else {
      if (!byParent.has(bm.parentId)) byParent.set(bm.parentId, []);
      byParent.get(bm.parentId).push(bm);
    }
  }

  async function processNodes(nodes, localParentId) {
    for (const bm of nodes) {
      let existingNode = null;
      if (bm.isFolder) {
        const children = await chrome.bookmarks.getChildren(localParentId);
        existingNode = children.find(c => !c.url && c.title === bm.title);
      } else if (bm.url) {
        const searchResults = await chrome.bookmarks.search({ url: bm.url });
        existingNode = searchResults.find(r => r.parentId === localParentId);
      }

      let localId;
      if (existingNode) {
        localId = existingNode.id;
        if (existingNode.title !== bm.title || (!bm.isFolder && existingNode.url !== bm.url)) {
          await chrome.bookmarks.update(localId, { title: bm.title, url: bm.isFolder ? undefined : bm.url }).catch(()=>{});
        }
        if (existingNode.parentId !== localParentId) {
          await chrome.bookmarks.move(localId, { parentId: localParentId }).catch(()=>{});
        }
      } else {
        const created = await chrome.bookmarks.create({
          parentId: localParentId,
          title: bm.title,
          url: bm.isFolder ? undefined : bm.url
        });
        localId = created.id;
      }

      idMap.set(bm.id, localId);

      if (bm.isFolder && byParent.has(bm.id)) {
        await processNodes(byParent.get(bm.id), localId);
      }
    }
  }

  await processNodes(rootsBar, '1');
  await processNodes(rootsOther, '2');

  // STEP 2: Prune items not in incoming payload
  if (isFullMirror) {
    const mappedLocalIds = new Set(Array.from(idMap.values()));
    // Always keep system roots
    mappedLocalIds.add('0');
    mappedLocalIds.add('1');
    mappedLocalIds.add('2');
    mappedLocalIds.add('3'); // Mobile bookmarks in some browsers

    console.log(`[BrowSync] Pruning. Mapped local IDs: ${mappedLocalIds.size}`);

    const freshTree = await chrome.bookmarks.getTree();

    async function pruneTree(nodes) {
      for (const node of nodes) {
        if (!mappedLocalIds.has(node.id)) {
          console.log(`[BrowSync] Pruning: deleting "${node.title}" (${node.id})`);
          try {
            await chrome.bookmarks.removeTree(node.id);
          } catch(e) {
            try { await chrome.bookmarks.remove(node.id); } catch(_) {}
          }
          // Don't recurse into deleted nodes
        } else if (node.children) {
          await pruneTree(node.children);
        }
      }
    }

    // Prune inside all safe system roots: id=1, id=2, id=3
    const rootsToPrune = ['1', '2', '3'];
    for (const rootId of rootsToPrune) {
      const rootNode = freshTree[0]?.children?.find(c => c.id === rootId);
      if (rootNode?.children) {
        await pruneTree(rootNode.children);
      }
    }
    console.log('[BrowSync] Pruning complete');
  } } finally {
    setTimeout(() => { isApplyingSync = false; }, 2000);
  }
}

if (chrome.bookmarks) {
  chrome.bookmarks.onCreated.addListener(async (id, bookmark) => {
    if (isApplyingSync) return;
    send({
      type: 'sync',
      browser: DETECTED_BROWSER,
      site: bookmark.url ? safeHostname(bookmark.url) : 'folder',
      category: 'bookmarks',
      payload: {
        kind: 'bookmarks',
        bookmarks: [{ 
          id, 
          title: bookmark.title, 
          url: bookmark.url, 
          parentId: bookmark.parentId,
          isFolder: !bookmark.url, 
          dateAdded: Date.now(), 
          sourceBrowser: DETECTED_BROWSER 
        }]
      },
      messageId: crypto.randomUUID(),
      timestamp: Date.now(),
    });
  });

  chrome.bookmarks.onRemoved.addListener((id, removeInfo) => {
    if (isApplyingSync) return;
    send({
      type: 'sync',
      browser: DETECTED_BROWSER,
      category: 'bookmarks_removed',
      payload: { 
        kind: 'bookmarks_removed', 
        bookmark: {
          id,
          title: removeInfo.node.title,
          url: removeInfo.node.url || null,
          parentId: removeInfo.parentId,
          isFolder: !removeInfo.node.url,
          sourceBrowser: DETECTED_BROWSER,
          dateAdded: removeInfo.node.dateAdded || Date.now()
        }
      },
      messageId: crypto.randomUUID(),
      timestamp: Date.now(),
    });
  });

  let bookmarkSyncTimer = null;
  function triggerFullBookmarkSync() {
    if (isApplyingSync) return;
    if (bookmarkSyncTimer) clearTimeout(bookmarkSyncTimer);
    bookmarkSyncTimer = setTimeout(() => {
      handlePullRequest('bookmarks');
    }, 1000);
  }

  chrome.bookmarks.onChanged.addListener(() => {
    triggerFullBookmarkSync();
  });

  chrome.bookmarks.onMoved.addListener(() => {
    triggerFullBookmarkSync();
  });
}

// ─── Cookies ─────────────────────────────────────────────────────────────────

if (chrome.cookies) {
  chrome.cookies.onChanged.addListener(async ({ cookie, removed, cause }) => {
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
        browser: DETECTED_BROWSER,
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

async function applyCookieSync(cookies) {
  let successCount = 0;
  let failCount = 0;
  const failures = [];
  if (!chrome.cookies) return;
  for (const cookie of cookies) {
    const baseDomain = cookie.domain.startsWith('.') ? cookie.domain.slice(1) : cookie.domain;
    const url = `https://${baseDomain}${cookie.path}`;
    const cookieKey = cookieIdentity(cookie);
    const updatedAt = cookie.updatedAt || Date.now();
    applyingCookies.add(cookieKey);

    if (cookie.removed) {
      try {
        await chrome.cookies.remove({ url, name: cookie.name });
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
      const tKey = `tombstone_cookies_${cookieIdentity(cookie)}`;
      chrome.storage.local.remove(tKey).catch(() => { });
    }

    const base = {
      url,
      name: cookie.name,
      value: cookie.value,
      path: cookie.path,
      expirationDate: cookie.expirationDate,
      httpOnly: cookie.httpOnly,
    };
    const validSameSite = ['no_restriction', 'lax', 'strict'];
    if (cookie.sameSite && validSameSite.includes(cookie.sameSite)) {
      base.sameSite = cookie.sameSite;
    }

    const cleanDomain = cookie.domain.startsWith('.') ? cookie.domain.slice(1) : cookie.domain;
    const baseOpts = { ...base, secure: cookie.secure };
    if (baseOpts.sameSite === 'no_restriction') baseOpts.secure = true;

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
    for (const opts of strategies) {
      try {
        const result = await chrome.cookies.set(opts);
        if (result) { ok = true; appliedCookie = result; break; }
      } catch (_) { }
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
  console.log(`[BrowSync] Cookie sync done: ${successCount} set, ${failCount} failed`);
  send({
    type: 'sync',
    browser: DETECTED_BROWSER,
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
  (async () => {
    if (message.source !== 'browsync-content') return;
    if (message.type === 'heartbeat_ping') return;
    if (message.type === 'backup_storage') {
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

if (chrome.tabs) {
  chrome.tabs.onUpdated.addListener(async (tabId, changeInfo, tab) => {
    if (changeInfo.status !== 'complete' || !tab.url) return;
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
  });
}

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

chrome.runtime.onStartup.addListener(() => {
  chrome.storage.local.set({ wsState: 'closed' }).catch(() => { }).then(() => connect());
});
chrome.runtime.onInstalled.addListener(() => connect());
connect();
