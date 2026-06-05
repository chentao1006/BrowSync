// popup.js — BrowSync extension popup

'use strict';

const statusDot = document.getElementById('statusDot');
const statusText = document.getElementById('statusText');

// ─── Connection status ────────────────────────────────────────────────────────

async function updateStatus() {
  const { wsState } = await chrome.storage.local.get('wsState');
  const connected = wsState === 'open';
  
  const { isWorking } = await chrome.storage.local.get('isWorking');
  
  statusDot.classList.remove('connected', 'working');
  if (connected) {
    if (isWorking) {
      statusDot.classList.add('working');
      statusText.textContent = chrome.i18n.getMessage("statusSyncing") || 'Syncing...';
    } else {
      statusDot.classList.add('connected');
      statusText.textContent = chrome.i18n.getMessage("statusConnected") || 'Connected to BrowSync';
    }
  } else {
    statusText.textContent = chrome.i18n.getMessage("statusDisconnected") || 'Disconnected';
  }
}

updateStatus();
setInterval(updateStatus, 1500);

// ─── Settings ─────────────────────────────────────────────────────────────────

const toggleBookmarkSync = document.getElementById('toggleBookmarkSync');
const toggleStateSync = document.getElementById('toggleStateSync');
const toggleTabSharing = document.getElementById('toggleTabSharing');
const btnSetRouterDefault = document.getElementById('btnSetRouterDefault');
const textIsRouterDefault = document.getElementById('textIsRouterDefault');
const btnMoreSettings = document.getElementById('btnMoreSettings');

async function loadSettings() {
  const { appSettings } = await chrome.storage.local.get('appSettings');
  if (!appSettings) return;

  const browserId = navigator.userAgent.toLowerCase().includes('safari') && !navigator.userAgent.toLowerCase().includes('chrome') ? 'safari' : 'chrome';

  const isBookmarkSync = appSettings.bookmarkParticipatingBrowsers?.[browserId] === true;
  const isStateSync = appSettings.stateParticipatingBrowsers?.[browserId] === true;
  const isRouterDefault = appSettings.routerDefault === browserId;
  const isTabSharingEnabled = appSettings.tabSharingEnabled === true;

  if (toggleBookmarkSync) toggleBookmarkSync.checked = isBookmarkSync;
  if (toggleStateSync) toggleStateSync.checked = isStateSync;
  if (toggleTabSharing) toggleTabSharing.checked = appSettings.tabSharingParticipatingBrowsers?.[browserId] === true;
  
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

  if (siteSyncSection) {
    chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
      const url = tabs.length > 0 ? tabs[0].url : null;
      if (url && /^https?:/i.test(url)) {
        try {
          let activeHostname = getBaseDomain(new URL(url).hostname);
          if (!activeHostname) {
            siteSyncSection.style.display = 'none';
            return;
          }
          
          siteSyncSection.style.display = 'block';
          if (siteDomainName) siteDomainName.textContent = activeHostname;
          
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
            toggleSiteSync.dataset.domain = activeHostname;
          }
          
          const siteStrategyRow = document.getElementById('siteStrategyRow');
          const siteSourceBrowserRow = document.getElementById('siteSourceBrowserRow');
          
          if (isSiteEnabled) {
            if (siteStrategyRow) siteStrategyRow.style.display = 'flex';
            if (btnSyncSiteNow) btnSyncSiteNow.style.display = 'block';
            if (siteSourceBrowserRow) {
               const strat = siteSetting?.strategy || 'default';
               siteSourceBrowserRow.style.display = (strat === 'primary_wins') ? 'flex' : 'none';
            }
          } else {
            if (siteStrategyRow) siteStrategyRow.style.display = 'none';
            if (btnSyncSiteNow) btnSyncSiteNow.style.display = 'none';
            if (siteSourceBrowserRow) siteSourceBrowserRow.style.display = 'none';
          }
          
          if (selectSiteStrategy) {
            selectSiteStrategy.value = siteSetting?.strategy || 'default';
            selectSiteStrategy.disabled = !isSiteEnabled;
            selectSiteStrategy.dataset.domain = activeHostname;
          }
          if (selectSiteSourceBrowser) {
            const installedBrowsers = appSettings.installedBrowsers || ['safari', 'chrome'];
            selectSiteSourceBrowser.innerHTML = '';
            
            const browserNames = {
              'safari': 'Safari',
              'chrome': 'Chrome',
              'arc': 'Arc',
              'edge': 'Edge',
              'brave': 'Brave'
            };
            
            installedBrowsers.forEach(b => {
              const opt = document.createElement('option');
              opt.value = b;
              opt.textContent = browserNames[b] || b;
              selectSiteSourceBrowser.appendChild(opt);
            });
            
            let sourceBrowser = siteSetting?.sourceBrowser;
            if (!sourceBrowser || !installedBrowsers.includes(sourceBrowser)) {
               sourceBrowser = installedBrowsers.length > 0 ? installedBrowsers[0] : 'safari';
            }

            selectSiteSourceBrowser.value = sourceBrowser;
            selectSiteSourceBrowser.disabled = !isSiteEnabled;
            selectSiteSourceBrowser.dataset.domain = activeHostname;
          }
          if (btnSyncSiteNow) {
            btnSyncSiteNow.disabled = !isSiteEnabled;
            btnSyncSiteNow.dataset.domain = activeHostname;
          }
        } catch (e) {
          siteSyncSection.style.display = 'none';
        }
      } else {
        siteSyncSection.style.display = 'none';
      }
    });
  }
}

if (toggleBookmarkSync) {
  toggleBookmarkSync.addEventListener('change', (e) => {
    chrome.runtime.sendMessage({ type: 'UPDATE_SETTING', setting: 'bookmarkSync', value: e.target.checked });
  });
}

if (toggleStateSync) {
  toggleStateSync.addEventListener('change', (e) => {
    chrome.runtime.sendMessage({ type: 'UPDATE_SETTING', setting: 'stateSync', value: e.target.checked });
  });
}

if (toggleTabSharing) {
  toggleTabSharing.addEventListener('change', (e) => {
    chrome.runtime.sendMessage({ type: 'UPDATE_SETTING', setting: 'tabSharing', value: e.target.checked });
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
      chrome.runtime.sendMessage({ type: 'PULL_SITE_DATA', domain: domain }, () => {
        chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
          if (tabs[0]) {
            chrome.tabs.reload(tabs[0].id);
          }
        });
        setTimeout(() => { btnSyncSiteNow.style.opacity = '1'; }, 1000);
      });
    }
  });
}

loadSettings();
setInterval(loadSettings, 1000);

// ─── Tab Sharing ──────────────────────────────────────────────────────────────

const btnRefreshTabs = document.getElementById('btnRefreshTabs');
const remoteTabsList = document.getElementById('remoteTabsList');

async function renderRemoteTabs() {
  const tabSharingSection = document.getElementById('tabSharingSection');
  const { remoteTabs } = await chrome.storage.local.get('remoteTabs');
  if (!remoteTabsList) return;

  remoteTabsList.innerHTML = '';

  const hasAnyTab = remoteTabs && Object.values(remoteTabs).some(tabs => tabs && tabs.length > 0);

  if (!hasAnyTab) {
    if (tabSharingSection) tabSharingSection.style.display = 'none';
    return;
  }

  if (tabSharingSection) tabSharingSection.style.display = 'block';

  for (const browser of Object.keys(remoteTabs)) {
    const tabs = remoteTabs[browser];
    if (!tabs || tabs.length === 0) continue;

    for (const tab of tabs) {
      const item = document.createElement('a');
      item.className = 'remote-tab-item';
      item.href = tab.url;
      item.target = '_blank';
      item.addEventListener('click', (e) => {
        e.preventDefault();
        chrome.tabs.create({ url: tab.url });
      });

      const icon = document.createElement('img');
      icon.className = 'remote-tab-icon';
      icon.src = `../icons/${browser.toLowerCase()}.png`;
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
  if (namespace === 'local' && changes.remoteTabs) {
    renderRemoteTabs();
  }
});

// Initial pull and render
chrome.runtime.sendMessage({ type: 'PULL_TAB_SHARING' });
renderRemoteTabs();

// ─── i18n ─────────────────────────────────────────────────────────────────────
document.addEventListener('DOMContentLoaded', () => {
  const elements = document.querySelectorAll('[data-i18n]');
  elements.forEach(el => {
    const msg = chrome.i18n.getMessage(el.getAttribute('data-i18n'));
    if (msg) el.textContent = msg;
  });
  
  const subtitleEl = document.getElementById('appSubtitle');
  if (subtitleEl) {
    subtitleEl.textContent = 'v' + chrome.runtime.getManifest().version;
  }
});
