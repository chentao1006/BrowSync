// popup.js — BrowSync extension popup

'use strict';

const statusDot = document.getElementById('statusDot');
const statusText = document.getElementById('statusText');

// ─── Connection status ────────────────────────────────────────────────────────

async function updateStatus() {
  const { wsState } = await chrome.storage.local.get('wsState');
  const connected = wsState === 'open';
  statusDot.classList.toggle('connected', connected);
  statusText.textContent = connected ? 'Connected to BrowSync' : 'Disconnected';
}

updateStatus();
// Poll every 2s while popup is open
setInterval(updateStatus, 2000);

// ─── Toggle persistence ──────────────────────────────────────────────────────

const toggleIds = ['syncBookmarks', 'syncCookies', 'syncLocalStorage', 'syncSessionStorage'];

async function loadToggles() {
  const result = await chrome.storage.local.get(toggleIds);
  for (const id of toggleIds) {
    const el = document.getElementById(id);
    if (el) {
      el.checked = result[id] !== false; // default true
    }
  }
}

loadToggles();

for (const id of toggleIds) {
  document.getElementById(id)?.addEventListener('change', async (e) => {
    await chrome.storage.local.set({ [id]: e.target.checked });
  });
}

// ─── Open app ────────────────────────────────────────────────────────────────

document.getElementById('openApp')?.addEventListener('click', () => {
  // On macOS, opening a deep-link to the app
  window.open('browsync://open', '_blank');
});
