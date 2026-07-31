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
    if (message.type === 'state_sync_updated') {
      showStateSyncUpdateBanner();
      return;
    }
    if (message.type !== 'apply_storage') return;

    const storage = message.storageType === 'sessionStorage' ? sessionStorage : localStorage;
    const items = message.items || [];

    applyStorageItems(storage, items);
  });

  function showStateSyncUpdateBanner() {
    const existingBanner = document.getElementById('browsync-state-sync-banner');
    if (existingBanner) {
      clearTimeout(existingBanner.browsyncDismissTimer);
      restartStateSyncBannerTimer(existingBanner);
      return;
    }

    const banner = document.createElement('div');
    banner.id = 'browsync-state-sync-banner';
    banner.style.cssText = 'position:fixed;top:12px;right:12px;z-index:2147483647;display:flex;align-items:center;gap:8px;max-width:min(360px,calc(100vw - 24px));padding:8px 10px;border-radius:8px;background:rgba(31,41,55,.78);color:#fff;box-shadow:0 4px 14px rgba(0,0,0,.16);font:12px -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;';

    const localized = (key, fallback) => api.i18n?.getMessage(key) || fallback;
    const text = document.createElement('span');
    text.textContent = localized('stateSyncReloadPrompt', 'Your sign-in state was synced. Reload this page to apply it?');
    banner.appendChild(text);

    const reload = document.createElement('button');
    reload.innerHTML = '<svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor" aria-hidden="true"><path d="M17.65 6.35A7.96 7.96 0 0 0 12 4c-4.42 0-7.99 3.58-7.99 8S7.58 20 12 20c3.73 0 6.84-2.55 7.73-6h-2.08A5.99 5.99 0 0 1 12 18c-3.31 0-6-2.69-6-6s2.69-6 6-6c1.66 0 3.14.69 4.22 1.78L13 11h7V4l-2.35 2.35Z"/></svg>';
    reload.title = localized('stateSyncReload', 'Reload');
    reload.setAttribute('aria-label', reload.title);
    reload.style.cssText = 'border:0;border-radius:6px;width:26px;height:26px;padding:0;display:grid;place-items:center;flex:none;background:transparent;color:#f3f4f6;cursor:pointer!important;';
    reload.addEventListener('click', () => location.reload());
    banner.appendChild(reload);

    const dismiss = document.createElement('button');
    dismiss.innerHTML = '<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="m6 6 12 12M18 6 6 18"/></svg>';
    dismiss.title = localized('stateSyncLater', 'Later');
    dismiss.setAttribute('aria-label', dismiss.title);
    dismiss.style.cssText = 'border:0;width:26px;height:26px;padding:0;display:grid;place-items:center;flex:none;background:transparent;color:#e5e7eb;cursor:pointer!important;';
    dismiss.addEventListener('click', () => banner.remove());
    banner.appendChild(dismiss);

    const progress = document.createElement('div');
    progress.style.cssText = 'position:absolute;right:0;bottom:0;left:0;height:2px;overflow:hidden;border-radius:0 0 8px 8px;background:rgba(255,255,255,.16);';
    const progressBar = document.createElement('div');
    progressBar.className = 'browsync-state-sync-progress';
    progressBar.style.cssText = 'width:100%;height:100%;background:rgba(255,255,255,.7);';
    progress.appendChild(progressBar);
    banner.appendChild(progress);

    (document.body || document.documentElement).appendChild(banner);
    restartStateSyncBannerTimer(banner);
    banner.addEventListener('mouseenter', () => pauseStateSyncBannerTimer(banner));
    banner.addEventListener('mouseleave', () => resumeStateSyncBannerTimer(banner));
  }

  function restartStateSyncBannerTimer(banner) {
    clearTimeout(banner.browsyncDismissTimer);
    banner.browsyncRemainingMs = 10000;
    const progressBar = banner.querySelector('.browsync-state-sync-progress');
    if (progressBar) {
      progressBar.style.transition = 'none';
      progressBar.style.width = '100%';
    }
    resumeStateSyncBannerTimer(banner);
  }

  function pauseStateSyncBannerTimer(banner) {
    if (!banner.browsyncDismissTimer) return;
    clearTimeout(banner.browsyncDismissTimer);
    banner.browsyncDismissTimer = null;
    banner.browsyncRemainingMs = Math.max(0, banner.browsyncRemainingMs - (Date.now() - banner.browsyncTimerStartedAt));
    const progressBar = banner.querySelector('.browsync-state-sync-progress');
    if (progressBar) {
      progressBar.style.width = getComputedStyle(progressBar).width;
      progressBar.style.transition = 'none';
    }
  }

  function resumeStateSyncBannerTimer(banner) {
    const remaining = banner.browsyncRemainingMs;
    if (!remaining) {
      banner.remove();
      return;
    }
    banner.browsyncTimerStartedAt = Date.now();
    banner.browsyncDismissTimer = setTimeout(() => banner.remove(), remaining);
    const progressBar = banner.querySelector('.browsync-state-sync-progress');
    if (progressBar) {
      requestAnimationFrame(() => {
        progressBar.style.transition = `width ${remaining}ms linear`;
        progressBar.style.width = '0';
      });
    }
  }

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

  // ── Keep Background Alive ──────────────────────────────────────────────────
  let keepAlivePort = null;
  function connectKeepAlive() {
    keepAlivePort = api.runtime.connect({ name: 'browsync-keepalive' });
    keepAlivePort.onDisconnect.addListener(() => {
      keepAlivePort = null;
      setTimeout(connectKeepAlive, 5000);
    });
  }
  connectKeepAlive();

  setInterval(() => {
    if (keepAlivePort) {
      try {
        keepAlivePort.postMessage({ type: 'ping' });
      } catch (e) {
        connectKeepAlive();
      }
    } else {
      api.runtime.sendMessage({ source: 'browsync-content', type: 'heartbeat_ping' }).catch(() => {});
    }
  }, 15000);

})();
