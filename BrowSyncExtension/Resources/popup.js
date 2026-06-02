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
      statusText.textContent = 'Syncing...';
    } else {
      statusDot.classList.add('connected');
      statusText.textContent = 'Connected to BrowSync';
    }
  } else {
    statusText.textContent = 'Disconnected';
  }
}

updateStatus();
setInterval(updateStatus, 1500);

// ─── Open app ────────────────────────────────────────────────────────────────

document.getElementById('openApp')?.addEventListener('click', () => {
  window.open('https://github.com/chentao1006/browsync', '_blank');
});
