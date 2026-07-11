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
chrome.storage.local.set({ currentBrowserId: DETECTED_BROWSER }).catch(() => {});

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
    // An install action may be the first event after Safari wakes the
    // extension. Keep it until the daemon connection is registered.
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
    chrome.action.setBadgeText({ text: 'SYNC' });
    chrome.action.setBadgeBackgroundColor({ color: '#3b82f6' });
    if (chrome.action.setBadgeTextColor) {
      try { chrome.action.setBadgeTextColor({ color: '#ffffff' }); } catch (e) {}
    }
    setTimeout(() => updateBadge(), 2000);
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
          if (raw.tabSharingEnabled !== undefined) settings.tabSharingEnabled = raw.tabSharingEnabled;
          if (raw.stateParticipatingBrowsers) settings.stateParticipatingBrowsers = raw.stateParticipatingBrowsers;
          if (raw.bookmarkParticipatingBrowsers) settings.bookmarkParticipatingBrowsers = raw.bookmarkParticipatingBrowsers;
          if (raw.bookmarkSyncFolders) settings.bookmarkSyncFolders = raw.bookmarkSyncFolders;
          if (raw.tabSharingParticipatingBrowsers) settings.tabSharingParticipatingBrowsers = raw.tabSharingParticipatingBrowsers;
          if (raw.websiteListPolicy !== undefined) settings.websiteListPolicy = raw.websiteListPolicy;
          if (raw.websiteSettings !== undefined) settings.websiteSettings = raw.websiteSettings;
          if (raw.installedBrowsers !== undefined) settings.installedBrowsers = raw.installedBrowsers;
          if (raw.syncDisabledDomains !== undefined) settings.syncDisabledDomains = raw.syncDisabledDomains;
          chrome.storage.local.set({ appSettings: settings });
        });
      }
      break;
    case 'pull':
      await handlePullRequest(message.category, message.site);
      break;
    case 'ack':
      // Acknowledged
      break;
  }
}

async function applySync(message) {
  const { category, payload } = message;
  updateBadge('syncing');

  // Empty payload means it's a pull request from the App
  if (!payload || (payload.kind === 'raw' && Object.keys(payload.raw || {}).length === 0)) {
    await handlePullRequest(category);
    return;
  }

  switch (category) {
    case 'bookmarks':
      console.log(`[BrowSync] Applying ${(payload.bookmarks || []).length} bookmarks... isFullMirror: ${message.isFullMirror}`);
      await applyBookmarkSync(payload.bookmarks || [], message.isFullMirror, message.targetBookmarkFolder || null);
      break;
    case 'bookmarks_removed':
      if (chrome.bookmarks && payload.bookmark) {
        const bm = payload.bookmark;
        console.log(`[BrowSync] Removing bookmark title ${bm.title}`);
        
        const storageData = await chrome.storage.local.get('syncIdMap');
        const syncIdMap = storageData.syncIdMap || {};
        const chromeId = syncIdMap[bm.id];
        let targetId = chromeId || bm.id;
        const targetFolder = message.targetBookmarkFolder ? await findBookmarkFolderByPath(message.targetBookmarkFolder) : null;
        if (message.targetBookmarkFolder && !targetFolder) {
          send({
            type: 'sync',
            browser: DETECTED_BROWSER,
            category: 'bookmark_folder_missing',
            payload: { kind: 'raw', raw: { folder: message.targetBookmarkFolder } },
            messageId: crypto.randomUUID(),
            timestamp: Date.now()
          });
          break;
        }

        async function isInsideRemovalTarget(nodeId) {
          if (!targetFolder) return true;
          let currentId = nodeId;
          const seen = new Set();
          while (currentId && !seen.has(currentId)) {
            if (currentId === targetFolder.id) return true;
            seen.add(currentId);
            const nodes = await chrome.bookmarks.get(currentId).catch(() => []);
            const node = nodes && nodes[0];
            if (!node) return false;
            currentId = node.parentId;
          }
          return false;
        }
        
        isApplyingSync = true;
        try {
          if (await isInsideRemovalTarget(targetId)) {
            await chrome.bookmarks.removeTree(targetId);
          } else {
            throw new Error('Mapped bookmark is outside selected sync folder');
          }
        } catch(e) {
          if (bm.url) {
            const results = await chrome.bookmarks.search({ url: bm.url });
            for (const r of results) {
               if (r.title === bm.title && await isInsideRemovalTarget(r.id)) {
                 await chrome.bookmarks.remove(r.id).catch(()=>{});
                 break;
               }
            }
          } else {
            const tree = targetFolder ? (await chrome.bookmarks.getSubTree(targetFolder.id).catch(() => []))[0]?.children || [] : await chrome.bookmarks.getTree();
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
        setTimeout(() => { isApplyingSync = false; }, 2000);
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
    case 'tabSharing':
      // Store remote tabs in local storage for popup.js to read
      if (payload.kind === 'tabs') {
        const tabs = payload.tabs || [];
        const browserId = message.browser;
        if (browserId && browserId !== DETECTED_BROWSER) {
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

async function sendCookiesSnapshot(site) {
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

async function sendStorageSnapshot(storageType, site) {
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
      type: 'sync', browser: DETECTED_BROWSER, category: storageType,
      payload: { kind: storageType, [storageType]: allItems.slice(i, i + 200) },
      messageId: crypto.randomUUID(), timestamp: Date.now()
    });
  }
}

async function handlePullRequest(category, site) {
  console.log('[BrowSync] Received pull request for:', category, site);
  switch (category) {
    case 'bookmark_backup':
    case 'bookmarks': {
      if (!chrome.bookmarks) return;
      const tree = await chrome.bookmarks.getTree();
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
            sourceBrowser: DETECTED_BROWSER
          });
        }
      }

      function traverse(nodes) {
        for (const [sortIndex, node] of nodes.entries()) {
          if (!systemRoots.has(node.id)) { // Skip root and system folders
            let normalizedParentId = node.parentId;
            if (isBackupOnly && backupRootByActualId.has(node.parentId)) normalizedParentId = backupRootByActualId.get(node.parentId).snapshotId;
            else if (node.parentId === localBarId) normalizedParentId = '1';
            else if (node.parentId === localOtherId) normalizedParentId = '2';
            else if (node.parentId === localMobileId) normalizedParentId = '3';
            else if (node.parentId === '0') normalizedParentId = '1';

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
              sourceBrowser: DETECTED_BROWSER 
            });
          }
          if (node.children) traverse(node.children);
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
        type: 'sync', browser: DETECTED_BROWSER, category: category === 'bookmark_backup' ? 'bookmark_backup' : 'bookmarks',
        payload: { kind: 'bookmarks', bookmarks: flat },
        messageId: crypto.randomUUID(), timestamp: Date.now()
      });
      break;
    }
    case 'browserData': {
      await sendCookiesSnapshot(site);
      await sendStorageSnapshot('localStorage', site);
      await sendStorageSnapshot('sessionStorage', site);
      break;
    }
    case 'cookies': {
      await sendCookiesSnapshot(site);
      break;
    }
    case 'browserState':
    case 'tabSharing': {
      if (!chrome.tabs) return;
      const tabs = await chrome.tabs.query({});
      // Filter out incognito tabs for privacy, and non-HTTP(S) tabs, if it's tab sharing
      const filteredTabs = category === 'tabSharing' ? tabs.filter(t => !t.incognito && /^https?:\/\//i.test(t.url)) : tabs;
      console.log(`[BrowSync] Sending ${filteredTabs.length} tabs for ${category}...`);
      const mapped = filteredTabs.map(tab => ({
        id: String(tab.id), url: tab.url, title: tab.title || '', isActive: tab.active,
        windowId: String(tab.windowId), index: tab.index, favIconURL: tab.favIconUrl,
        sourceBrowser: DETECTED_BROWSER, capturedAt: Date.now()
      }));
      send({
        type: 'sync', browser: DETECTED_BROWSER, category: category,
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

let localBarId = '1';
let localOtherId = '2';
let localMobileId = '3';
let systemRoots = new Set(['0', '1', '2', '3']);

if (chrome.bookmarks) {
  chrome.bookmarks.getTree().then(tree => {
    send({
      type: 'sync',
      browser: DETECTED_BROWSER,
      category: 'DEBUG_TREE',
      payload: tree[0],
      messageId: 'debug-tree',
      timestamp: Date.now()
    });
  });
}


if (chrome.bookmarks) {
  chrome.bookmarks.getTree().then(tree => {
    const localRoots = tree[0]?.children || [];
    localBarId = localRoots.find(node => node.id === '1')?.id || localRoots[0]?.id || '1';
    localOtherId = localRoots.find(node => node.id === '2')?.id || localRoots[1]?.id || '2';
    localMobileId = localRoots.find(node => node.id === '3')?.id || localRoots[2]?.id || '3';
    systemRoots = new Set(['0', localBarId, localOtherId, localMobileId]);
  }).catch(()=>{});
}

let isApplyingSync = false;

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
  const tree = await chrome.bookmarks.getTree();
  const localRoots = tree[0]?.children || [];
  localBarId = localRoots.find(node => node.id === '1')?.id || localRoots[0]?.id || localBarId || '1';
  localOtherId = localRoots.find(node => node.id === '2')?.id || localRoots[1]?.id || localOtherId || '2';
  localMobileId = localRoots.find(node => node.id === '3')?.id || localRoots[2]?.id || localMobileId || '3';
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
    current = candidates.find(node => !node.url && node.title === part);
    if (!current) return null;
    candidates = await chrome.bookmarks.getChildren(current.id).catch(() => []);
  }
  return current;
}

async function currentBookmarkSyncFolderPath() {
  const { appSettings } = await chrome.storage.local.get('appSettings').catch(() => ({}));
  const folders = appSettings?.bookmarkSyncFolders || {};
  return folders[DETECTED_BROWSER] || null;
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
      browser: DETECTED_BROWSER,
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

async function applyBookmarkSync(bookmarks, isFullMirror = false, targetBookmarkFolder = null) {
  if (isApplyingSync) return;
  isApplyingSync = true;
  try {
  if (!chrome.bookmarks) return;

  console.log(`[BrowSync] applyBookmarkSync: ${bookmarks.length} bookmarks, isFullMirror=${isFullMirror}, targetBookmarkFolder=${targetBookmarkFolder || '(root)'}`);

  // Ensure system roots are up to date
  const localTree = await chrome.bookmarks.getTree();
  const localRoots = localTree[0]?.children || [];
  localBarId = localRoots.find(node => node.id === '1')?.id || localRoots[0]?.id || '1';
  localOtherId = localRoots.find(node => node.id === '2')?.id || localRoots[1]?.id || '2';
  localMobileId = localRoots.find(node => node.id === '3')?.id || localRoots[2]?.id || '3';
  systemRoots = new Set(['0', localBarId, localOtherId, localMobileId]);
  let targetRootId = null;
  if (targetBookmarkFolder) {
    const targetFolder = await findBookmarkFolderByPath(targetBookmarkFolder);
    if (!targetFolder) {
      console.warn(`[BrowSync] Selected bookmark folder no longer exists: ${targetBookmarkFolder}`);
      send({
        type: 'sync',
        browser: DETECTED_BROWSER,
        category: 'bookmark_folder_missing',
        payload: { kind: 'raw', raw: { folder: targetBookmarkFolder } },
        messageId: crypto.randomUUID(),
        timestamp: Date.now()
      });
      return;
    }
    targetRootId = targetFolder.id;
  }

  async function isInsideTargetFolder(nodeId) {
    if (!targetRootId) return true;
    let currentId = nodeId;
    const seen = new Set();
    while (currentId && !seen.has(currentId)) {
      if (currentId === targetRootId) return true;
      seen.add(currentId);
      const nodes = await chrome.bookmarks.get(currentId).catch(() => []);
      const node = nodes && nodes[0];
      if (!node) return false;
      currentId = node.parentId;
    }
    return false;
  }

  // STEP 1: If full mirror, snapshot current Chrome state and send back as backup
  if (isFullMirror) {
    const preTree = await chrome.bookmarks.getTree();
    const snapshot = [];
    function flatForBackup(nodes) {
      for (const node of nodes) {
        if (node.id !== '0' && node.id !== '1' && node.id !== '2' && node.id !== '3') {
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

  // Load persistent map of Safari ID -> Chrome ID to handle renames
  const storageData = await chrome.storage.local.get('syncIdMap');
  const syncIdMap = storageData.syncIdMap || {};
  const idMap = new Map(Object.entries(syncIdMap));
  
  // Always enforce root mappings
  idMap.set('1', localBarId);
  idMap.set('2', localOtherId);
  idMap.set('3', localMobileId);
  idMap.set('0', '0');
  idMap.set(null, localBarId);
  idMap.set(undefined, localBarId);
  idMap.set(localBarId, localBarId);
  idMap.set(localOtherId, localOtherId);
  idMap.set(localMobileId, localMobileId);

  // Build a tree to process parents before children
  const byParent = new Map();
  const rootsBar = [];
  const rootsOther = [];

  const ignoreIds = new Set(['0', '1', '2', '3', localBarId, localOtherId, localMobileId]);

  for (const bm of bookmarks) {
    if (ignoreIds.has(bm.id)) continue; // Defensively ignore system folders
    
    let effectiveParent = bm.parentId;
    if (targetRootId && (!effectiveParent || effectiveParent === '1' || effectiveParent === '0' || effectiveParent === '2' || effectiveParent === localBarId || effectiveParent === localOtherId)) {
      rootsBar.push(bm);
    } else if (!effectiveParent || effectiveParent === '1' || effectiveParent === '0' || effectiveParent === localBarId) {
      rootsBar.push(bm);
    } else if (effectiveParent === '2' || effectiveParent === localOtherId) {
      rootsOther.push(bm);
    } else {
      if (!byParent.has(effectiveParent)) byParent.set(effectiveParent, []);
      byParent.get(effectiveParent).push(bm);
    }
  }

  async function processNodes(nodes, localParentId) {
    // Keep folders and bookmarks in one user-defined sibling sequence.
    const orderedNodes = nodes
      .map((bm, fallbackIndex) => ({ bm, fallbackIndex }))
      .sort((a, b) => (a.bm.sortIndex ?? a.fallbackIndex) - (b.bm.sortIndex ?? b.fallbackIndex) || a.fallbackIndex - b.fallbackIndex);
    for (let i = 0; i < orderedNodes.length; i++) {
      const bm = orderedNodes[i].bm;
      let existingNode = null;
      
      // 1. Try to find by persistent ID mapping first (handles renames/moves perfectly)
      if (idMap.has(bm.id)) {
        const mappedId = idMap.get(bm.id);
        const results = await chrome.bookmarks.get(mappedId).catch(() => []);
        if (results && results.length > 0) {
          if (await isInsideTargetFolder(results[0].id)) {
            existingNode = results[0];
          } else {
            idMap.delete(bm.id);
          }
        } else {
          idMap.delete(bm.id); // Stale map
        }
      }
      
      // 2. Fallback to title/url matching
      if (!existingNode) {
        if (bm.isFolder) {
          const children = await chrome.bookmarks.getChildren(localParentId).catch(() => []);
          existingNode = children.find(c => !c.url && c.title === bm.title);
        } else if (bm.url) {
          const searchResults = await chrome.bookmarks.search({ url: bm.url });
          existingNode = searchResults.find(r => r.parentId === localParentId);
          if (!existingNode && !targetRootId && searchResults.length > 0) {
            existingNode = searchResults[0];
          }
        }
      }

      let localId;
      if (existingNode) {
        localId = existingNode.id;
        if (existingNode.title !== bm.title || (!bm.isFolder && existingNode.url !== bm.url)) {
          await chrome.bookmarks.update(localId, { title: bm.title, url: bm.isFolder ? undefined : bm.url }).catch(()=>{});
        }
        if (existingNode.parentId !== localParentId) {
          await chrome.bookmarks.move(localId, { parentId: localParentId, index: i }).catch(()=>{});
        } else if (existingNode.index !== i) {
          await chrome.bookmarks.move(localId, { index: i }).catch(()=>{});
        }
      } else {
        const created = await chrome.bookmarks.create({
          parentId: localParentId,
          title: bm.title,
          url: bm.isFolder ? undefined : bm.url,
          index: i
        });
        localId = created.id;
      }

      idMap.set(bm.id, localId);

      if (bm.isFolder && byParent.has(bm.id)) {
        await processNodes(byParent.get(bm.id), localId);
      }
    }
  }

  await processNodes(rootsBar, targetRootId || localBarId);
  if (!targetRootId) {
    await processNodes(rootsOther, localOtherId);
  }
  
  // Persist mapping to prevent duplicates/deletions on restart or subsequent syncs
  await chrome.storage.local.set({ syncIdMap: Object.fromEntries(idMap) });


  // STEP 2: Prune items not in incoming payload
  if (isFullMirror) {
    const incomingSafariIds = new Set(bookmarks.map(b => b.id));
    const mappedLocalIds = new Set();
    for (const [safariId, chromeId] of idMap.entries()) {
      if (incomingSafariIds.has(safariId)) {
        mappedLocalIds.add(chromeId);
      }
    }
    
    // Always keep system roots
    mappedLocalIds.add('0');
    mappedLocalIds.add(localBarId);
    mappedLocalIds.add(localOtherId);
    if (localMobileId) mappedLocalIds.add(localMobileId);

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

    if (targetRootId) {
      const children = await chrome.bookmarks.getChildren(targetRootId).catch(() => []);
      await pruneTree(children);
    } else {
      // Prune inside all safe system roots
      const rootNodes = freshTree[0]?.children || [];
      for (const rootNode of rootNodes) {
        if (rootNode?.children) {
          await pruneTree(rootNode.children);
        }
      }
    }
    console.log('[BrowSync] Pruning complete');
  } } finally {
    setTimeout(() => { isApplyingSync = false; }, 2000);
  }
}

let bookmarkDebounceTimer = null;
async function handleBookmarkChange(reason, event = {}) {
  if (isApplyingSync) return;
  if (!(await isBookmarkEventInSelectedFolder(event))) {
    console.log(`[BrowSync] Ignored bookmark ${reason} outside selected sync folder`);
    return;
  }
  
  // Clear existing timer to debounce
  if (bookmarkDebounceTimer) {
    clearTimeout(bookmarkDebounceTimer);
  }
  
  // Wait for 3 seconds of silence
  bookmarkDebounceTimer = setTimeout(async () => {
    if (isApplyingSync) return; // double check
    if (!(await isBookmarkEventInSelectedFolder(event))) return;
    console.log(`[BrowSync] Bookmark changed (${reason}), preparing to sync after debounce...`);
    const preTree = await chrome.bookmarks.getTree();
    const snapshot = [];
    function flatForBackup(nodes) {
      for (const node of nodes) {
        if (node.id !== '0') {
          let pId = node.parentId;
          if (pId === localBarId) pId = '1';
          else if (pId === localOtherId) pId = '2';
          else if (pId === localMobileId) pId = '3';
          
          snapshot.push({
            id: node.id,
            title: node.title,
            url: node.url || null,
            parentId: pId,
            isFolder: !node.url,
            inBookmarksBar: pId === '1'
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
    
    // Actually trigger the full sync!
    await handlePullRequest('bookmarks');
  }, 10000);
}

if (chrome.bookmarks) {
  chrome.bookmarks.onCreated.addListener((id, node) => handleBookmarkChange('created', { id, parentId: node?.parentId }));
  chrome.bookmarks.onRemoved.addListener(async (id, removeInfo) => {
    if (isApplyingSync) return;
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
    const deletedBm = {
      id: mappedId,
      title: removeInfo.node.title,
      url: removeInfo.node.url,
      isFolder: !removeInfo.node.url
    };
    
    console.log('[BrowSync] Explicit bookmark removed:', deletedBm);
    send({
      type: 'sync',
      browser: DETECTED_BROWSER,
      category: 'bookmarks_removed',
      payload: { bookmarksRemoved: deletedBm },
      messageId: crypto.randomUUID(),
      timestamp: Date.now()
    });
    if (bookmarkDebounceTimer) {
      clearTimeout(bookmarkDebounceTimer);
      bookmarkDebounceTimer = null;
    }
  });
  chrome.bookmarks.onChanged.addListener((id) => handleBookmarkChange('changed', { id }));
  chrome.bookmarks.onMoved.addListener((id, moveInfo) => handleBookmarkChange('moved', { id, oldParentId: moveInfo?.oldParentId, newParentId: moveInfo?.parentId }));
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
    const urlsToTry = (baseDomain === 'localhost' || baseDomain.startsWith('127.0.0.'))
      ? [`http://${baseDomain}${cookie.path}`, `https://${baseDomain}${cookie.path}`]
      : [`https://${baseDomain}${cookie.path}`];
      
    const cookieKey = cookieIdentity(cookie);
    const updatedAt = cookie.updatedAt || Date.now();
    applyingCookies.add(cookieKey);

    if (cookie.removed) {
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
      const tKey = `tombstone_cookies_${cookieIdentity(cookie)}`;
      chrome.storage.local.remove(tKey).catch(() => { });
    }

    const base = {
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
  if (message.type === 'UPDATE_SETTING') {
    send({
      type: 'settings',
      browser: DETECTED_BROWSER,
      payload: { kind: 'raw', raw: { [message.setting]: message.value } },
      messageId: crypto.randomUUID(),
      timestamp: Date.now()
    });
    chrome.storage.local.get('appSettings').then(({ appSettings }) => {
      let settings = appSettings || {};
      const browserId = DETECTED_BROWSER;
      if (message.setting === 'bookmarkSync') {
         if (!settings.bookmarkParticipatingBrowsers) settings.bookmarkParticipatingBrowsers = {};
         settings.bookmarkParticipatingBrowsers[browserId] = message.value;
      } else if (message.setting === 'stateSync') {
         if (!settings.stateParticipatingBrowsers) settings.stateParticipatingBrowsers = {};
         settings.stateParticipatingBrowsers[browserId] = message.value;
      } else if (message.setting === 'routerDefault' && message.value === true) {
         settings.routerDefault = browserId;
      }
      chrome.storage.local.set({ appSettings: settings });
    });
    sendResponse({ ok: true });
    return true;
  }
  
  if (message.type === 'UPDATE_SITE_SETTING') {
    send({
      type: 'settings', browser: DETECTED_BROWSER,
      payload: { kind: 'raw', raw: { toggleSiteSync: { domain: message.domain, value: message.value } } },
      messageId: crypto.randomUUID(), timestamp: Date.now()
    });
    sendResponse({ ok: true });
    return true;
  }
  
  if (message.type === 'UPDATE_SITE_STRATEGY') {
    send({
      type: 'settings', browser: DETECTED_BROWSER,
      payload: { kind: 'raw', raw: { updateSiteStrategy: { domain: message.domain, strategy: message.strategy } } },
      messageId: crypto.randomUUID(), timestamp: Date.now()
    });
    sendResponse({ ok: true });
    return true;
  }
  
  if (message.type === 'UPDATE_SITE_SOURCE_BROWSER') {
    send({
      type: 'settings', browser: DETECTED_BROWSER,
      payload: { kind: 'raw', raw: { updateSiteSourceBrowser: { domain: message.domain, browser: message.browser } } },
      messageId: crypto.randomUUID(), timestamp: Date.now()
    });
    sendResponse({ ok: true });
    return true;
  }
  
  if (message.type === 'PULL_SITE_DATA') {
    send({
      type: 'pull', browser: DETECTED_BROWSER, category: 'browserData', site: message.domain,
      messageId: crypto.randomUUID(), timestamp: Date.now()
    });
    sendResponse({ ok: true });
    return true;
  }
  
  if (message.type === 'OPEN_SETTINGS') {
    send({
      type: 'open_settings',
      browser: DETECTED_BROWSER,
      messageId: crypto.randomUUID(),
      timestamp: Date.now()
    });
    sendResponse({ ok: true });
    return true;
  }

  if (message.type === 'OPEN_URL_IN_BROWSER') {
    send({
      type: 'open_url',
      browser: DETECTED_BROWSER,
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
      browser: DETECTED_BROWSER,
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

let tabDebounceTimer = null;
if (chrome.tabs) {
  chrome.tabs.onUpdated.addListener(async (tabId, changeInfo, tab) => {
    if (changeInfo.status !== 'complete' || !tab.url) return;
    
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
