// content.js — BrowSync content script
// Applies incoming storage syncs ONLY on page load, and periodically polls for outbound changes.

'use strict';

(function () {
  if (window.__browsyncInjected) return;
  window.__browsyncInjected = true;

  const api = (typeof browser !== 'undefined') ? browser : chrome;

  // ── Snapshots for Polling ──────────────────────────────────────────────────

  function snapshotStorage(storage) {
    const snap = {};
    try {
      for (let i = 0; i < storage.length; i++) {
        const key = storage.key(i);
        snap[key] = storage.getItem(key);
      }
    } catch (e) {
      // Ignored
    }
    return snap;
  }

  let lastLocalSnapshot = snapshotStorage(localStorage);
  let lastSessionSnapshot = snapshotStorage(sessionStorage);

  function detectAndSendChanges(storage, lastSnapshot, storageType) {
    const currentSnapshot = snapshotStorage(storage);
    const changes = [];

    // Check for new/modified
    for (const key in currentSnapshot) {
      if (currentSnapshot[key] !== lastSnapshot[key]) {
        changes.push({ key, value: currentSnapshot[key], origin: location.origin });
      }
    }

    // Check for deleted
    for (const key in lastSnapshot) {
      if (!(key in currentSnapshot)) {
        changes.push({ key, value: null, origin: location.origin });
      }
    }

    if (changes.length > 0) {
      api.runtime.sendMessage({
        source: 'browsync-content',
        type: 'storage_change', // Send as an active change so it gets broadcasted
        storageType: storageType,
        items: changes
      }).catch(() => {});
    }

    return currentSnapshot;
  }

  // ── Polling Interval ───────────────────────────────────────────────────────

  // Check every 3 seconds
  setInterval(() => {
    lastLocalSnapshot = detectAndSendChanges(localStorage, lastLocalSnapshot, 'localStorage');
    lastSessionSnapshot = detectAndSendChanges(sessionStorage, lastSessionSnapshot, 'sessionStorage');
  }, 3000);

  // ── Apply storage ──────────────────────────────────────────────────────────

  api.runtime.onMessage.addListener((message) => {
    if (message.source !== 'browsync-background') return;
    if (message.type !== 'apply_storage') return;

    const storage = message.storageType === 'sessionStorage' ? sessionStorage : localStorage;
    const items = message.items || [];

    applyStorageItems(storage, items);
  });

  function applyStorageItems(storage, items) {
    try {
      for (const item of items) {
        if (item.origin && item.origin !== location.origin) continue;
        if (item.key === '__clear__') {
          storage.clear();
        } else if (item.value == null) {
          storage.removeItem(item.key);
        } else {
          storage.setItem(item.key, item.value);
        }
      }
      
      // Update snapshots so we don't echo these applied changes back
      if (storage === localStorage) {
        lastLocalSnapshot = snapshotStorage(localStorage);
      } else if (storage === sessionStorage) {
        lastSessionSnapshot = snapshotStorage(sessionStorage);
      }
    } catch (e) {
      console.warn('[BrowSync] Error applying storage:', e);
    }
  }

  // ── Fetch cached sync data on load ─────────────────────────────────────────

  try {
    const origin = location.origin;
    const localKey = `sync_localStorage_${origin}`;
    const sessionKey = `sync_sessionStorage_${origin}`;
    
    // Some browsers use callbacks, some promises for storage.local.get
    const storagePromise = api.storage.local.get([localKey, sessionKey]);
    if (storagePromise && storagePromise.then) {
      storagePromise.then(handleCachedStorage);
    } else {
      api.storage.local.get([localKey, sessionKey], handleCachedStorage);
    }

    function handleCachedStorage(result) {
      if (result[localKey] && result[localKey].length > 0) {
        applyStorageItems(localStorage, result[localKey]);
        api.storage.local.remove(localKey);
      }
      if (result[sessionKey] && result[sessionKey].length > 0) {
        applyStorageItems(sessionStorage, result[sessionKey]);
        api.storage.local.remove(sessionKey);
      }
      
      // After applying any pending sync, backup current state to background
      backupFullStorage();
    }
  } catch (e) {
    console.warn('[BrowSync] Could not fetch cached storage:', e);
  }

  // ── Passive Accumulation (Backup to Background) ────────────────────────────

  function backupFullStorage() {
    try {
      const localItems = [];
      for (let i = 0; i < localStorage.length; i++) {
        const key = localStorage.key(i);
        localItems.push({ key, value: localStorage.getItem(key), origin: location.origin });
      }
      if (localItems.length > 0) {
        api.runtime.sendMessage({
          source: 'browsync-content',
          type: 'backup_storage',
          storageType: 'localStorage',
          items: localItems
        }).catch(() => {});
      }

      const sessionItems = [];
      for (let i = 0; i < sessionStorage.length; i++) {
        const key = sessionStorage.key(i);
        sessionItems.push({ key, value: sessionStorage.getItem(key), origin: location.origin });
      }
      if (sessionItems.length > 0) {
        api.runtime.sendMessage({
          source: 'browsync-content',
          type: 'backup_storage',
          storageType: 'sessionStorage',
          items: sessionItems
        }).catch(() => {});
      }
    } catch (e) {
      console.warn('[BrowSync] Failed to backup storage:', e);
    }
  }

})();
