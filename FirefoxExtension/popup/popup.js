// popup.js — BrowSync extension popup

'use strict';

const statusDot = document.getElementById('statusDot');
const statusText = document.getElementById('statusText');

let appInterfaceLanguage = 'system';
let appMessages = null;
const APP_LANGUAGE_LOCALE_DIRECTORIES = {
  en: ['en'],
  'zh-Hans': ['zh-CN'],
  ja: ['ja'],
  ko: ['ko'],
  de: ['de'],
  fr: ['fr'],
  it: ['it'],
  es: ['es']
};

function localizedMessage(key, fallback) {
  return appMessages?.[key]?.message || chrome.i18n.getMessage(key) || fallback;
}

async function applyAppLanguage(language) {
  const requestedLanguage = APP_LANGUAGE_LOCALE_DIRECTORIES[language] ? language : 'system';
  if (requestedLanguage === appInterfaceLanguage && (requestedLanguage === 'system' || appMessages)) return;

  let messages = null;
  if (requestedLanguage !== 'system') {
    for (const directory of APP_LANGUAGE_LOCALE_DIRECTORIES[requestedLanguage]) {
      try {
        const response = await fetch(chrome.runtime.getURL(`_locales/${directory}/messages.json`));
        if (response.ok) {
          messages = await response.json();
          break;
        }
      } catch (_) {}
    }
  }
  appInterfaceLanguage = requestedLanguage;
  appMessages = messages;
  document.documentElement.lang = requestedLanguage === 'system'
    ? (chrome.i18n.getUILanguage?.() || navigator.language || 'en')
    : requestedLanguage;
  localizePopup();
  updateStatus();
}

function localizePopup() {
  document.querySelectorAll('[data-i18n]').forEach(el => {
    const message = localizedMessage(el.getAttribute('data-i18n'), '');
    if (message) el.textContent = message;
  });
}

// ─── Connection status ────────────────────────────────────────────────────────

async function updateStatus() {
  const { wsState } = await chrome.storage.local.get('wsState');
  const connected = wsState === 'open';
  
  const { isWorking } = await chrome.storage.local.get('isWorking');
  
  statusDot.classList.remove('connected', 'working');
  if (connected) {
    if (isWorking) {
      statusDot.classList.add('working');
      statusText.textContent = localizedMessage('statusSyncing', 'Syncing...');
    } else {
      statusDot.classList.add('connected');
      statusText.textContent = localizedMessage('statusConnected', 'Connected to BrowSync');
    }
  } else {
    statusText.textContent = localizedMessage('statusDisconnected', 'Disconnected');
  }
}

updateStatus();
setInterval(updateStatus, 1500);

// ─── Settings ─────────────────────────────────────────────────────────────────

const toggleBookmarkSync = document.getElementById('toggleBookmarkSync');
const toggleStateSync = document.getElementById('toggleStateSync');
const toggleTabSharing = document.getElementById('toggleTabSharing');
const bookmarkSyncRow = document.getElementById('bookmarkSyncRow');
const stateSyncRow = document.getElementById('stateSyncRow');
const tabSharingRow = document.getElementById('tabSharingRow');
const btnGrantStateSyncPermission = document.getElementById('btnGrantStateSyncPermission');
const btnGrantTabSharingPermission = document.getElementById('btnGrantTabSharingPermission');
const routerDefaultContainer = document.getElementById('routerDefaultContainer');
const btnSetRouterDefault = document.getElementById('btnSetRouterDefault');
const textIsRouterDefault = document.getElementById('textIsRouterDefault');
const btnMoreSettings = document.getElementById('btnMoreSettings');

const STATE_SYNC_PERMISSIONS = {
  permissions: ['tabs', 'cookies', 'scripting'],
  origins: ['<all_urls>']
};
const TAB_SHARING_PERMISSIONS = { permissions: ['tabs'] };

async function hasFeaturePermissions(details) {
  if (!chrome.permissions?.contains) return false;
  try { return await chrome.permissions.contains(details); } catch (_) { return false; }
}

function grantPermissionMessage() {
  const language = appInterfaceLanguage === 'system'
    ? (chrome.i18n?.getUILanguage?.() || navigator.language || '')
    : appInterfaceLanguage;
  if (/^zh[-_](?:tw|hant)/i.test(language)) return '授予權限';
  if (/^zh/i.test(language)) return '授予权限';
  if (/^ja/i.test(language)) return '許可を与える';
  if (/^ko/i.test(language)) return '권한 부여';
  if (/^de/i.test(language)) return 'Berechtigung erteilen';
  if (/^es/i.test(language)) return 'Conceder permiso';
  if (/^fr/i.test(language)) return 'Autoriser';
  if (/^it/i.test(language)) return 'Concedi autorizzazione';
  return 'Grant Permission';
}

function renderConfiguredFeature(toggle, grantButton, configured, hasPermissions) {
  if (!toggle || !grantButton) return;
  const needsPermission = configured && !hasPermissions;
  // The App setting is authoritative: it stays visibly on. A disabled switch
  // distinguishes missing browser authorization from a user-disabled feature.
  toggle.checked = configured;
  toggle.disabled = needsPermission;
  grantButton.textContent = grantPermissionMessage();
  grantButton.style.display = needsPermission ? 'inline-block' : 'none';
}

async function grantFeaturePermission(button, permissions) {
  button.disabled = true;
  try {
    await chrome.permissions.request(permissions);
  } finally {
    button.disabled = false;
    void loadSettings();
  }
}

// Settings currently being written by an in-flight updateOptionalFeature() call.
// While non-empty, storage.onChanged / permissions.onAdded / permissions.onRemoved
// below skip reloading from storage: the settings write happens before the
// permission request resolves, so a reload in that window would read
// "setting on, permission not yet granted" and flicker the toggle back off —
// and since it's a set (not a single flag), one toggle finishing doesn't
// prematurely clear the guard for another toggle still in flight.
const pendingOptionalFeatureUpdates = new Set();

async function updateOptionalFeature(toggle, setting, permissions) {
  const enabled = toggle.checked;
  toggle.disabled = true;
  pendingOptionalFeatureUpdates.add(setting);
  try {
    // chrome.permissions.request() must be the first async call made in direct
    // response to this click: any await before it — even a fast sendMessage
    // round-trip — loses the user-gesture context Firefox requires, and the
    // call silently rejects instead of showing the permission prompt. Send the
    // settings write only after the grant; reconcileOptionalFeaturePermissions
    // in the background tolerates the brief race against permissions.onAdded
    // with its own short re-check delay.
    if (enabled) {
      if (!(await chrome.permissions.request(permissions))) {
        toggle.checked = false;
        return;
      }
      await chrome.runtime.sendMessage({ type: 'UPDATE_SETTING', setting, value: true });
    } else {
      await chrome.runtime.sendMessage({ type: 'UPDATE_SETTING', setting, value: false });
    }
  } catch (_) {
    toggle.checked = false;
  } finally {
    toggle.disabled = false;
    // permissions.onAdded can fire slightly after chrome.permissions.request()
    // resolves (and thus after this function returns), so keep the guard up
    // briefly past that point rather than clearing it immediately.
    setTimeout(() => {
      pendingOptionalFeatureUpdates.delete(setting);
      void loadSettings();
    }, 500);
  }
}
function detectCurrentBrowserId() {
  const ua = navigator.userAgent.toLowerCase();
  if (ua.includes('firefox/')) return 'firefox';
  if (ua.includes('edg/')) return 'edge';
  if (ua.includes('safari/') && !ua.includes('chrome/') && !ua.includes('chromium/')) return 'safari';
  return 'chrome';
}

function displayBrowserName(browserId, detail) {
  if (detail?.displayName?.trim()) return detail.displayName.trim();
  return String(browserId).replace(/[-_]+/g, ' ').replace(/\b\w/g, char => char.toUpperCase());
}

function renderOpenInBrowsers(installedBrowsers, currentBrowserId, currentUrl, installedBrowserDetails = []) {
  const section = document.getElementById('openInBrowserSection');
  const list = document.getElementById('openInBrowserList');
  if (!section || !list) return;

  if (!currentUrl || !/^https?:\/\//i.test(currentUrl)) {
    list.innerHTML = '';
    delete list.dataset.renderKey;
    section.style.display = 'none';
    return;
  }

  const targets = (installedBrowsers || []).filter(browser => browser !== currentBrowserId);
  if (targets.length === 0) {
    list.innerHTML = '';
    delete list.dataset.renderKey;
    section.style.display = 'none';
    return;
  }

  const detailsById = new Map(installedBrowserDetails.map(detail => [detail.id, detail]));
  const renderKey = JSON.stringify({
    currentUrl,
    targets: targets.map(browser => {
      const detail = detailsById.get(browser) || {};
      return [browser, detail.displayName || '', detail.iconDataURL || ''];
    })
  });
  if (list.dataset.renderKey === renderKey) {
    section.style.display = 'block';
    return;
  }

  list.innerHTML = '';
  list.dataset.renderKey = renderKey;
  for (const browser of targets) {
    const detail = detailsById.get(browser) || {};
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'browser-open-btn';
    button.title = displayBrowserName(browser, detail);
    button.setAttribute('aria-label', button.title);
    button.addEventListener('click', () => {
      chrome.runtime.sendMessage({
        type: 'OPEN_URL_IN_BROWSER',
        browser,
        url: currentUrl
      }, () => window.close());
    });

    const icon = document.createElement('img');
    icon.src = detail.iconDataURL || '../icons/icon16.png';
    icon.alt = '';
    icon.onerror = () => { icon.src = '../icons/icon16.png'; };

    button.appendChild(icon);
    list.appendChild(button);
  }

  section.style.display = 'block';
}

async function loadSettings() {
  const { appSettings, currentBrowserId } = await chrome.storage.local.get(['appSettings', 'currentBrowserId']);
  if (!appSettings) return;
  await applyAppLanguage(appSettings.interfaceLanguage);

  const browserId = currentBrowserId || detectCurrentBrowserId();

  const isBookmarkSync = appSettings.bookmarkParticipatingBrowsers?.[browserId] === true;
  const isStateSync = appSettings.stateParticipatingBrowsers?.[browserId] === true;
  const isRouterDefault = appSettings.routerDefault === browserId;
  const isRouterEnabled = appSettings.routerEnabled !== false;
  const isTabSharingEnabled = appSettings.tabSharingEnabled === true;
  const isBookmarkSyncFeatureEnabled = appSettings.bookmarkSyncEnabled !== false;
  const isStateSyncFeatureEnabled = appSettings.stateSyncEnabled !== false;

  if (bookmarkSyncRow) bookmarkSyncRow.style.display = isBookmarkSyncFeatureEnabled ? 'flex' : 'none';
  if (stateSyncRow) stateSyncRow.style.display = isStateSyncFeatureEnabled ? 'flex' : 'none';
  if (tabSharingRow) tabSharingRow.style.display = isTabSharingEnabled ? 'flex' : 'none';
  if (routerDefaultContainer) routerDefaultContainer.style.display = isRouterEnabled ? 'flex' : 'none';

  if (toggleBookmarkSync) toggleBookmarkSync.checked = isBookmarkSyncFeatureEnabled && isBookmarkSync;
  const [hasStateSyncPermissions, hasTabSharingPermissions] = await Promise.all([
    hasFeaturePermissions(STATE_SYNC_PERMISSIONS),
    hasFeaturePermissions(TAB_SHARING_PERMISSIONS)
  ]);
  if (toggleStateSync) {
    renderConfiguredFeature(toggleStateSync, btnGrantStateSyncPermission,
      isStateSyncFeatureEnabled && isStateSync, hasStateSyncPermissions);
  }
  if (toggleTabSharing) {
    const isTabSharing = appSettings.tabSharingParticipatingBrowsers?.[browserId] === true;
    renderConfiguredFeature(toggleTabSharing, btnGrantTabSharingPermission,
      isTabSharingEnabled && isTabSharing, hasTabSharingPermissions);
  }
  
  const tabSharingSection = document.getElementById('tabSharingSection');
  if (tabSharingSection && !isTabSharingEnabled) {
    // Only force-hide when tab sharing is disabled.
    // When enabled, renderRemoteTabs() controls visibility based on actual content.
    tabSharingSection.style.display = 'none';
  }
  
  if (btnSetRouterDefault && textIsRouterDefault) {
    if (isRouterDefault) {
      btnSetRouterDefault.style.display = 'none';
      textIsRouterDefault.style.display = 'inline';
    } else {
      btnSetRouterDefault.style.display = 'inline-block';
      textIsRouterDefault.style.display = 'none';
    }
  }

  // Site Sync Section
  const siteSyncSection = document.getElementById('siteSyncSection');
  const siteDomainName = document.getElementById('siteDomainName');
  const toggleSiteSync = document.getElementById('toggleSiteSync');
  const selectSiteStrategy = document.getElementById('selectSiteStrategy');
  const selectSiteSourceBrowser = document.getElementById('selectSiteSourceBrowser');
  const btnSyncSiteNow = document.getElementById('btnSyncSiteNow');

  function getBaseDomain(hostname) {
    const parts = hostname.split('.');
    if (parts.length <= 2) return hostname;
    if (/^\d{1,3}(\.\d{1,3}){3}$/.test(hostname)) return hostname;
    const sld = parts[parts.length - 2];
    if (['co', 'com', 'org', 'net', 'edu', 'gov', 'ac', 'ne'].includes(sld) && parts.length > 2) {
      return parts.slice(-3).join('.');
    }
    return parts.slice(-2).join('.');
  }

  if (siteSyncSection && isStateSyncFeatureEnabled) {
    chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
      siteSyncSection.style.display = 'block'; // ALWAYS SHOW
      const url = tabs.length > 0 ? tabs[0].url : null;
      let activeHostname = null;
      renderOpenInBrowsers(appSettings.installedBrowsers || ['safari', 'chrome'], browserId, url, appSettings.installedBrowserDetails);

      if (url && /^https?:/i.test(url)) {
        try {
          activeHostname = getBaseDomain(new URL(url).hostname);
        } catch (e) {}
      }

      const siteStrategyRow = document.getElementById('siteStrategyRow');
      const siteSourceBrowserRow = document.getElementById('siteSourceBrowserRow');

      if (!activeHostname) {
        if (siteDomainName) siteDomainName.textContent = localizedMessage('noWebsite', 'N/A');
        if (toggleSiteSync) {
          toggleSiteSync.checked = false;
          toggleSiteSync.disabled = true;
          const label = document.getElementById('toggleSiteSyncLabel');
          if (label) label.title = "";
        }
        if (siteStrategyRow) siteStrategyRow.style.display = 'none';
        if (siteSourceBrowserRow) siteSourceBrowserRow.style.display = 'none';
        if (btnSyncSiteNow) btnSyncSiteNow.style.display = 'none';
        return;
      }

      if (siteDomainName) siteDomainName.textContent = activeHostname;
      
      const SYNC_DISABLED_DOMAINS = appSettings.syncDisabledDomains || [];
      const isDisabledDomain = SYNC_DISABLED_DOMAINS.some(d => activeHostname === d || activeHostname.endsWith('.' + d));

      if (isDisabledDomain) {
        if (toggleSiteSync) {
          toggleSiteSync.checked = false;
          toggleSiteSync.disabled = true;
          const label = document.getElementById('toggleSiteSyncLabel');
          if (label) label.title = localizedMessage('disabledByBlacklist', 'Sync is disabled for this domain to protect your account security.');
        }
        if (siteStrategyRow) siteStrategyRow.style.display = 'none';
        if (siteSourceBrowserRow) siteSourceBrowserRow.style.display = 'none';
        if (btnSyncSiteNow) btnSyncSiteNow.style.display = 'none';
        return;
      }

      const policy = appSettings.websiteListPolicy || 'allow_list';
      const settingsList = appSettings.websiteSettings || [];
      
      const siteSetting = settingsList.find(s => {
        const listed = s.domain;
        return activeHostname === listed || activeHostname.endsWith('.' + listed) || listed.endsWith('.' + activeHostname);
      });
      
      const inList = !!siteSetting;
      let isSiteEnabled = false;
      if (policy === 'allow_list') isSiteEnabled = inList;
      else if (policy === 'block_list') isSiteEnabled = !inList;
      
      if (toggleSiteSync) {
        toggleSiteSync.checked = isSiteEnabled;
        toggleSiteSync.disabled = false;
        toggleSiteSync.dataset.domain = activeHostname;
        const label = document.getElementById('toggleSiteSyncLabel');
        if (label) label.title = "";
      }
      
      if (isSiteEnabled) {
        if (siteStrategyRow) siteStrategyRow.style.display = policy === 'allow_list' ? 'flex' : 'none';
        if (btnSyncSiteNow) btnSyncSiteNow.style.display = 'block';
        if (siteSourceBrowserRow) {
           const strat = siteSetting?.strategy || 'default';
           siteSourceBrowserRow.style.display = policy === 'allow_list' && strat === 'primary_wins' ? 'flex' : 'none';
        }
      } else {
        if (siteStrategyRow) siteStrategyRow.style.display = 'none';
        if (btnSyncSiteNow) btnSyncSiteNow.style.display = 'none';
        if (siteSourceBrowserRow) siteSourceBrowserRow.style.display = 'none';
      }
      
      if (selectSiteStrategy) {
        selectSiteStrategy.value = siteSetting?.strategy || 'default';
        selectSiteStrategy.disabled = !isSiteEnabled || policy === 'block_list';
        selectSiteStrategy.dataset.domain = activeHostname;
      }
      
      if (selectSiteSourceBrowser) {
        const installedBrowsers = appSettings.installedBrowsers || ['safari', 'chrome'];
        const detailsById = new Map((appSettings.installedBrowserDetails || []).map(detail => [detail.id, detail]));
        selectSiteSourceBrowser.innerHTML = '';

        installedBrowsers.forEach(b => {
          const opt = document.createElement('option');
          opt.value = b;
          opt.textContent = displayBrowserName(b, detailsById.get(b));
          selectSiteSourceBrowser.appendChild(opt);
        });
        
        let sourceBrowser = siteSetting?.sourceBrowser;
        if (!sourceBrowser || !installedBrowsers.includes(sourceBrowser)) {
           sourceBrowser = installedBrowsers.length > 0 ? installedBrowsers[0] : 'safari';
        }

        selectSiteSourceBrowser.value = sourceBrowser;
        selectSiteSourceBrowser.disabled = !isSiteEnabled || policy === 'block_list';
        selectSiteSourceBrowser.dataset.domain = activeHostname;
      }
      
      if (btnSyncSiteNow) {
        btnSyncSiteNow.disabled = !isSiteEnabled;
        btnSyncSiteNow.dataset.domain = activeHostname;
      }
    });
  } else if (siteSyncSection) {
    siteSyncSection.style.display = 'none';
  }
}

if (toggleBookmarkSync) {
  toggleBookmarkSync.addEventListener('change', (e) => {
    chrome.runtime.sendMessage({ type: 'UPDATE_SETTING', setting: 'bookmarkSync', value: e.target.checked });
  });
}

if (toggleStateSync) {
  toggleStateSync.addEventListener('change', () => {
    void updateOptionalFeature(toggleStateSync, 'stateSync', STATE_SYNC_PERMISSIONS);
  });
}

if (toggleTabSharing) {
  toggleTabSharing.addEventListener('change', () => {
    void updateOptionalFeature(toggleTabSharing, 'tabSharing', TAB_SHARING_PERMISSIONS);
  });
}

if (btnGrantStateSyncPermission) {
  btnGrantStateSyncPermission.addEventListener('click', (event) => {
    event.preventDefault();
    event.stopPropagation();
    void grantFeaturePermission(btnGrantStateSyncPermission, STATE_SYNC_PERMISSIONS);
  });
}

if (btnGrantTabSharingPermission) {
  btnGrantTabSharingPermission.addEventListener('click', (event) => {
    event.preventDefault();
    event.stopPropagation();
    void grantFeaturePermission(btnGrantTabSharingPermission, TAB_SHARING_PERMISSIONS);
  });
}

if (btnSetRouterDefault) {
  btnSetRouterDefault.addEventListener('click', () => {
    chrome.runtime.sendMessage({ type: 'UPDATE_SETTING', setting: 'routerDefault', value: true });
  });
}

if (btnMoreSettings) {
  btnMoreSettings.addEventListener('click', () => {
    chrome.runtime.sendMessage({ type: 'OPEN_SETTINGS' });
    window.close();
  });
}

// Event Listeners for Site Sync
const toggleSiteSync = document.getElementById('toggleSiteSync');
if (toggleSiteSync) {
  toggleSiteSync.addEventListener('change', (e) => {
    if (e.target.dataset.domain) {
      chrome.runtime.sendMessage({ type: 'UPDATE_SITE_SETTING', domain: e.target.dataset.domain, value: e.target.checked });
    }
  });
}

const selectSiteStrategy = document.getElementById('selectSiteStrategy');
if (selectSiteStrategy) {
  selectSiteStrategy.addEventListener('change', (e) => {
    if (e.target.dataset.domain) {
      const strategy = e.target.value === 'default' ? null : e.target.value;
      chrome.runtime.sendMessage({ type: 'UPDATE_SITE_STRATEGY', domain: e.target.dataset.domain, strategy: strategy });
      const siteSourceBrowserRow = document.getElementById('siteSourceBrowserRow');
      if (siteSourceBrowserRow) {
         siteSourceBrowserRow.style.display = (strategy === 'primary_wins') ? 'flex' : 'none';
      }
      if (strategy === 'primary_wins') {
        const sourceSelect = document.getElementById('selectSiteSourceBrowser');
        if (sourceSelect?.value) {
          chrome.runtime.sendMessage({ type: 'UPDATE_SITE_SOURCE_BROWSER', domain: e.target.dataset.domain, browser: sourceSelect.value });
        }
      }
    }
  });
}

const selectSiteSourceBrowser = document.getElementById('selectSiteSourceBrowser');
if (selectSiteSourceBrowser) {
  selectSiteSourceBrowser.addEventListener('change', (e) => {
    if (e.target.dataset.domain) {
      chrome.runtime.sendMessage({ type: 'UPDATE_SITE_SOURCE_BROWSER', domain: e.target.dataset.domain, browser: e.target.value });
    }
  });
}

const btnSyncSiteNow = document.getElementById('btnSyncSiteNow');
if (btnSyncSiteNow) {
  btnSyncSiteNow.addEventListener('click', (e) => {
    const domain = e.target.dataset.domain;
    if (domain) {
      btnSyncSiteNow.style.opacity = '0.5';
      chrome.runtime.sendMessage({ type: 'SYNC_SITE_DATA', domain: domain }, () => {
        setTimeout(() => { btnSyncSiteNow.style.opacity = '1'; }, 1000);
      });
    }
  });
}

loadSettings();
// Gated the same way as the storage.onChanged/permissions.onAdded/onRemoved
// listeners below: reloading mid-toggle would read "setting on, permission
// not yet granted" and flicker the toggle back off.
setInterval(() => { if (pendingOptionalFeatureUpdates.size === 0) void loadSettings(); }, 1000);

// ─── Tab Sharing ──────────────────────────────────────────────────────────────

const btnRefreshTabs = document.getElementById('btnRefreshTabs');
const remoteTabsList = document.getElementById('remoteTabsList');

async function renderRemoteTabs() {
  const tabSharingSection = document.getElementById('tabSharingSection');
  const { remoteTabs, appSettings } = await chrome.storage.local.get(['remoteTabs', 'appSettings']);
  const detailsById = new Map((appSettings?.installedBrowserDetails || []).map(detail => [detail.id, detail]));
  if (!remoteTabsList) return;
  if (appSettings?.tabSharingEnabled !== true) {
    if (tabSharingSection) tabSharingSection.style.display = 'none';
    return;
  }

  remoteTabsList.innerHTML = '';

  const hasAnyTab = remoteTabs && Object.values(remoteTabs).some(tabs => tabs && tabs.length > 0);

  if (!hasAnyTab) {
    if (tabSharingSection) tabSharingSection.style.display = 'none';
    return;
  }

  if (tabSharingSection) tabSharingSection.style.display = 'block';

  const seenUrls = new Set();

  for (const browser of Object.keys(remoteTabs)) {
    const tabs = remoteTabs[browser];
    if (!tabs || tabs.length === 0) continue;

    for (const tab of tabs) {
      if (seenUrls.has(tab.url)) continue;
      seenUrls.add(tab.url);

      const item = document.createElement('a');
      item.className = 'remote-tab-item';
      item.href = tab.url;
      item.target = '_blank';
      item.title = tab.url;
      item.addEventListener('click', (e) => {
        e.preventDefault();
        chrome.tabs.create({ url: tab.url });
      });

      const icon = document.createElement('img');
      icon.className = 'remote-tab-icon';
      icon.src = detailsById.get(browser)?.iconDataURL || '../icons/icon16.png';
      icon.onerror = () => { icon.src = '../icons/icon16.png'; };

      const tabTitle = document.createElement('div');
      tabTitle.className = 'remote-tab-title';
      tabTitle.textContent = tab.title || tab.url;

      item.appendChild(icon);
      item.appendChild(tabTitle);
      remoteTabsList.appendChild(item);
    }
  }
}

if (btnRefreshTabs) {
  btnRefreshTabs.addEventListener('click', () => {
    btnRefreshTabs.style.opacity = '0.5';
    chrome.runtime.sendMessage({ type: 'PULL_TAB_SHARING' }, () => {
      setTimeout(() => { btnRefreshTabs.style.opacity = '1'; }, 1000);
    });
  });
}

chrome.storage.onChanged.addListener((changes, namespace) => {
  if (namespace === 'local') {
    if ((changes.appSettings || changes.currentBrowserId) && pendingOptionalFeatureUpdates.size === 0) {
      void loadSettings();
    }
    if (changes.remoteTabs) {
      void renderRemoteTabs();
    }
  }
});

if (chrome.permissions?.onAdded) {
  chrome.permissions.onAdded.addListener(() => { if (pendingOptionalFeatureUpdates.size === 0) void loadSettings(); });
  chrome.permissions.onRemoved.addListener(() => { if (pendingOptionalFeatureUpdates.size === 0) void loadSettings(); });
}

// Initial pull and render
chrome.runtime.sendMessage({ type: 'PULL_TAB_SHARING' });
renderRemoteTabs();

// ─── i18n ─────────────────────────────────────────────────────────────────────
document.addEventListener('DOMContentLoaded', () => {
  localizePopup();
  
  const subtitleEl = document.getElementById('appSubtitle');
  if (subtitleEl) {
    subtitleEl.textContent = 'v' + chrome.runtime.getManifest().version;
  }
});
