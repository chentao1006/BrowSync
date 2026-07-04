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

// ─── Settings ─────────────────────────────────────────────────────────────────

const toggleBookmarkSync = document.getElementById('toggleBookmarkSync');
const toggleStateSync = document.getElementById('toggleStateSync');
const toggleTabSharing = document.getElementById('toggleTabSharing');
const btnSetRouterDefault = document.getElementById('btnSetRouterDefault');
const textIsRouterDefault = document.getElementById('textIsRouterDefault');
const btnMoreSettings = document.getElementById('btnMoreSettings');
const browserNames = {
  safari: 'Safari',
  chrome: 'Chrome',
  edge: 'Edge',
  brave: 'Brave',
  firefox: 'Firefox',
  vivaldi: 'Vivaldi',
  opera: 'Opera',
  yandex: 'Yandex',
  arc: 'Arc',
  orion: 'Orion',
  helium: 'Helium',
  browseros: 'BrowserOS'
};

const iconUrls = {
  safari: 'https://cdnjs.cloudflare.com/ajax/libs/browser-logos/74.0.0/safari/safari_128x128.png',
  chrome: 'https://cdnjs.cloudflare.com/ajax/libs/browser-logos/74.0.0/chrome/chrome_128x128.png',
  edge: 'https://cdnjs.cloudflare.com/ajax/libs/browser-logos/74.0.0/edge/edge_128x128.png',
  brave: 'https://cdnjs.cloudflare.com/ajax/libs/browser-logos/74.0.0/brave/brave_128x128.png',
  firefox: 'https://cdnjs.cloudflare.com/ajax/libs/browser-logos/74.0.0/firefox/firefox_128x128.png',
  vivaldi: 'https://cdnjs.cloudflare.com/ajax/libs/browser-logos/74.0.0/vivaldi/vivaldi_128x128.png',
  opera: 'https://cdnjs.cloudflare.com/ajax/libs/browser-logos/74.0.0/opera/opera_128x128.png',
  yandex: 'https://cdnjs.cloudflare.com/ajax/libs/browser-logos/74.0.0/yandex/yandex_128x128.png',
  arc: 'https://www.google.com/s2/favicons?domain=arc.net&sz=64',
  orion: 'https://www.google.com/s2/favicons?domain=browser.kagi.com&sz=64',
  helium: 'https://www.google.com/s2/favicons?domain=helium.computer&sz=64',
  browseros: 'https://www.google.com/s2/favicons?domain=browseros.app&sz=64'
};

function getRemoteIconUrl(browserId) {
  const b = browserId.toLowerCase();
  if (iconUrls[b]) return iconUrls[b];
  return `https://www.google.com/s2/favicons?domain=${b}.com&sz=64`;
}

const localIcons = ['chrome', 'edge', 'firefox', 'safari'];

function detectCurrentBrowserId() {
  const ua = navigator.userAgent.toLowerCase();
  if (ua.includes('firefox/')) return 'firefox';
  if (ua.includes('edg/')) return 'edge';
  if (ua.includes('opr/') || ua.includes('opera/')) return 'opera';
  if (ua.includes('vivaldi/')) return 'vivaldi';
  if (ua.includes('yabrowser/')) return 'yandex';
  if (ua.includes('brave/') || navigator.brave) return 'brave';
  if (ua.includes('orion/')) return 'orion';
  if (ua.includes('helium/')) return 'helium';
  if (ua.includes('browseros/')) return 'browseros';
  if (ua.includes('safari/') && !ua.includes('chrome/') && !ua.includes('chromium/')) return 'safari';
  return 'chrome';
}

function renderOpenInBrowsers(installedBrowsers, currentBrowserId, currentUrl) {
  const section = document.getElementById('openInBrowserSection');
  const list = document.getElementById('openInBrowserList');
  if (!section || !list) return;

  list.innerHTML = '';
  if (!currentUrl || !/^https?:\/\//i.test(currentUrl)) {
    section.style.display = 'none';
    return;
  }

  const targets = (installedBrowsers || []).filter(browser => browser !== currentBrowserId);
  if (targets.length === 0) {
    section.style.display = 'none';
    return;
  }

  for (const browser of targets) {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'browser-open-btn';
    button.title = browserNames[browser] || browser;
    button.setAttribute('aria-label', button.title);
    button.addEventListener('click', () => {
      chrome.runtime.sendMessage({
        type: 'OPEN_URL_IN_BROWSER',
        browser,
        url: currentUrl
      }, () => window.close());
    });

    const icon = document.createElement('img');
    const lowerBrowser = browser.toLowerCase();
    
    if (localIcons.includes(lowerBrowser)) {
      icon.src = `../icons/${lowerBrowser}.png`;
    } else {
      icon.src = getRemoteIconUrl(browser);
    }
    
    icon.alt = '';
    icon.onerror = () => { 
      icon.onerror = null;
      icon.src = '../icons/icon16.png'; 
    };

    button.appendChild(icon);
    list.appendChild(button);
  }

  section.style.display = 'block';
}

async function loadSettings() {
  const { appSettings, currentBrowserId } = await chrome.storage.local.get(['appSettings', 'currentBrowserId']);
  if (!appSettings) return;

  const browserId = currentBrowserId || detectCurrentBrowserId();

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
      siteSyncSection.style.display = 'block'; // ALWAYS SHOW
      const url = tabs.length > 0 ? tabs[0].url : null;
      let activeHostname = null;
      renderOpenInBrowsers(appSettings.installedBrowsers || ['safari', 'chrome'], browserId, url);

      if (url && /^https?:/i.test(url)) {
        try {
          activeHostname = getBaseDomain(new URL(url).hostname);
        } catch (e) {}
      }

      const siteStrategyRow = document.getElementById('siteStrategyRow');
      const siteSourceBrowserRow = document.getElementById('siteSourceBrowserRow');

      if (!activeHostname) {
        if (siteDomainName) siteDomainName.textContent = chrome.i18n.getMessage("noWebsite") || 'N/A';
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
          if (label) label.title = chrome.i18n.getMessage("disabledByBlacklist") || "Sync is disabled for this domain to protect your account security.";
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
      const lowerBrowser = browser.toLowerCase();
      
      if (localIcons.includes(lowerBrowser)) {
        icon.src = `../icons/${lowerBrowser}.png`;
      } else {
        icon.src = getRemoteIconUrl(browser);
      }
      
      icon.onerror = () => { 
        icon.onerror = null;
        icon.src = '../icons/icon16.png'; 
      };

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
    if (changes.remoteTabs) {
      renderRemoteTabs();
    }
    if (changes.appSettings || changes.currentBrowserId) {
      loadSettings();
    }
    if (changes.wsState || changes.isWorking) {
      updateStatus();
    }
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
