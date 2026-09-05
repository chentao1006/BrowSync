// popup.js — BrowSync extension popup

'use strict';

const statusDot = document.getElementById('statusDot');
const statusText = document.getElementById('statusText');
// Safari exposes the runtime permission API under `browser.permissions`.
// Keep the Chrome alias as a fallback for compatibility with converted builds.
const permissionsAPI = (typeof browser !== 'undefined' && browser.permissions) ||
  (typeof chrome !== 'undefined' ? chrome.permissions : undefined);
// Safari before 16.4 has no dynamic content-script registration or optional
// permissions API. The separately packaged legacy extension declares its
// permissions statically, so it must not show a misleading "Grant Permission"
// control or attempt a runtime request.
const usesLegacyStaticPermissions = typeof chrome !== 'undefined' &&
  !chrome.scripting?.getRegisteredContentScripts;

let appInterfaceLanguage = 'system';
let appMessages = null;
const APP_LANGUAGE_LOCALE_DIRECTORIES = {
  en: ['en'],
  'zh-Hans': ['zh_CN'],
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
const stateSyncPermissionFeedback = document.getElementById('stateSyncPermissionFeedback');
const tabSharingPermissionFeedback = document.getElementById('tabSharingPermissionFeedback');
const routerDefaultContainer = document.getElementById('routerDefaultContainer');
const btnSetRouterDefault = document.getElementById('btnSetRouterDefault');
const textIsRouterDefault = document.getElementById('textIsRouterDefault');
const btnMoreSettings = document.getElementById('btnMoreSettings');

const STATE_SYNC_PERMISSIONS = {
  permissions: ['tabs', 'cookies', 'scripting'],
  origins: ['*://*/*']
};
const TAB_SHARING_PERMISSIONS = { permissions: ['tabs'] };

async function refreshPermissionStateCache() {
  const [stateSync, tabSharing] = await Promise.all([
    hasFeaturePermissions(STATE_SYNC_PERMISSIONS),
    hasFeaturePermissions(TAB_SHARING_PERMISSIONS)
  ]);
  await chrome.storage.local.set({ optionalPermissionState: { stateSync, tabSharing } });
  return { stateSync, tabSharing };
}

function setPermissionFeedback(element, message, isError = false) {
  if (!element) return;
  element.textContent = message || '';
  element.classList.toggle('visible', Boolean(message));
  element.classList.toggle('error', isError);
}

function safariWebsiteAccessSettingsMessage() {
  return localizedMessage(
    'safariWebsiteAccessDenied',
    'Website access was denied. In Safari > Settings > Extensions, select BrowSync and set Website Access to Always Allow on Every Website.'
  );
}

function permissionRequestFailedMessage() {
  const language = appInterfaceLanguage === 'system'
    ? (chrome.i18n?.getUILanguage?.() || navigator.language || '')
    : appInterfaceLanguage;
  if (/^zh[-_](?:tw|hant)/i.test(language)) return 'Safari 未授予此功能所需的權限。';
  if (/^zh/i.test(language)) return 'Safari 未授予此功能所需的权限。';
  return 'Safari did not grant the required permission.';
}

async function hasFeaturePermissions(details) {
  if (usesLegacyStaticPermissions) return true;
  if (!permissionsAPI?.contains) return false;
  try {
    // Safari reports a combined APIs + origins contains() query as false even
    // after each part was granted. Check the two permission classes separately.
    const checks = [];
    if (details.permissions?.length) {
      checks.push(permissionsAPI.contains({ permissions: details.permissions }));
    }
    if (details.origins?.length) {
      checks.push(permissionsAPI.contains({ origins: details.origins }));
    }
    return (await Promise.all(checks)).every(Boolean);
  } catch (_) { return false; }
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

async function requestFeaturePermissions(permissions) {
  if (!permissionsAPI?.request) throw new Error('permissions.request is unavailable');

  // Keep every requested capability in this one call. Safari requires the
  // request to originate directly from the user's click; a second request
  // after awaiting the website-access dialog has lost that gesture and Safari
  // rejects it even if the user chose "Always Allow" in the first dialog.
  return await permissionsAPI.request(permissions);
}

async function grantFeaturePermission(button, permissions, feedbackElement) {
  button.disabled = true;
  setPermissionFeedback(feedbackElement, '');
  try {
    const requested = await requestFeaturePermissions(permissions);
    const granted = requested && await hasFeaturePermissions(permissions);
    if (granted) {
      await refreshPermissionStateCache();
    } else {
      if (permissions.origins?.length) {
        setPermissionFeedback(feedbackElement, safariWebsiteAccessSettingsMessage());
      } else {
        setPermissionFeedback(feedbackElement, permissionRequestFailedMessage(), true);
      }
    }
  } catch (error) {
    console.warn('[BrowSync] Could not request Safari extension permission:', error);
    setPermissionFeedback(feedbackElement, permissionRequestFailedMessage(), true);
  } finally {
    button.disabled = false;
    void loadSettings();
  }
}

const pendingOptionalFeatureUpdates = new Set();

async function updateOptionalFeature(toggle, setting, permissions) {
  const enabled = toggle.checked;
  toggle.disabled = true;
  pendingOptionalFeatureUpdates.add(setting);
  try {
    // requestFeaturePermissions() must be the first async call made in direct
    // response to this click: any await before it — even a fast sendMessage
    // round-trip — loses the user-gesture context Safari requires, and the
    // permission prompt silently fails to appear instead of showing. Send the
    // settings write only after the grant, and let the background's own
    // reconcile logic tolerate the brief race against permissions.onAdded.
    if (enabled) {
      if (!usesLegacyStaticPermissions && !(await requestFeaturePermissions(permissions))) {
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

// Some Chromium builds (observed on Edge) fail to decode a long inline
// data: URI assigned directly to <img src> in an extension popup. Re-wrap
// the same bytes as a blob: URL first, which is universally supported.
function setBrowserIconSrc(imgEl, dataURL) {
  const fallback = '../icons/icon16.png';
  imgEl.onerror = () => { imgEl.onerror = null; imgEl.src = fallback; };
  if (!dataURL) { imgEl.src = fallback; return; }
  try {
    const [header, base64] = dataURL.split(',');
    const mime = /data:(.*?);base64/.exec(header)?.[1] || 'image/png';
    const binary = atob(base64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    imgEl.src = URL.createObjectURL(new Blob([bytes], { type: mime }));
  } catch (e) {
    imgEl.src = fallback;
  }
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
    icon.alt = '';
    setBrowserIconSrc(icon, detail.iconDataURL);

    button.appendChild(icon);
    list.appendChild(button);
  }

  section.style.display = 'block';
}

async function loadSettings() {
  const { appSettings, currentBrowserId, optionalPermissionState } = await chrome.storage.local.get([
    'appSettings', 'currentBrowserId', 'optionalPermissionState'
  ]);
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
  const [actualStateSyncPermissions, actualTabSharingPermissions] = await Promise.all([
    hasFeaturePermissions(STATE_SYNC_PERMISSIONS),
    hasFeaturePermissions(TAB_SHARING_PERMISSIONS)
  ]);
  // Safari can expose a stale permission snapshot during popup creation.
  // The background maintains this cache from permissions.onAdded/onRemoved, so
  // a known grant never flashes an incorrect Grant Permission button.
  const hasStateSyncPermissions = actualStateSyncPermissions || optionalPermissionState?.stateSync === true;
  const hasTabSharingPermissions = actualTabSharingPermissions || optionalPermissionState?.tabSharing === true;
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
    void grantFeaturePermission(btnGrantStateSyncPermission, STATE_SYNC_PERMISSIONS, stateSyncPermissionFeedback);
  });
}

if (btnGrantTabSharingPermission) {
  btnGrantTabSharingPermission.addEventListener('click', (event) => {
    event.preventDefault();
    event.stopPropagation();
    void grantFeaturePermission(btnGrantTabSharingPermission, TAB_SHARING_PERMISSIONS, tabSharingPermissionFeedback);
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
      setBrowserIconSrc(icon, detailsById.get(browser)?.iconDataURL);

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
