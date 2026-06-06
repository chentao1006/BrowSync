# BrowSync

[English] | [简体中文](README_zh.md)

**BrowSync** is a macOS native app that makes Safari, Chrome, Arc, Edge, and Brave work together. It unifies your browsing experience through a local WebSocket daemon, browser extensions, intelligent URL routing rules, and cross-browser data synchronization.

[![Download BrowSync](https://img.shields.io/badge/Download-Latest%20Release-blue?style=for-the-badge&logo=apple)](https://github.com/chentao1006/browsync/releases/latest)

```bash
brew install --cask chentao1006/tap/browsync
```

> [!IMPORTANT]
> **Privacy First by Design**
> BrowSync is built on a strict privacy-first architecture. All synchronization and URL routing happen **entirely locally** on your device via a local WebSocket daemon. Your browsing data (history, bookmarks, cookies) **never** leaves your machine, and no external servers or cloud services are involved.

## 🚀 Key Features

- **Intelligent URL Routing**: Register BrowSync as your default macOS browser. Its powerful rule engine automatically directs links to your preferred browser based on domain, URL patterns, query strings, source application, or time of day.
- **Cross-Browser Data Sync**: Seamlessly sync Cookies, LocalStorage, sessionStorage, and Bookmarks across Safari and Chromium-based browsers (Chrome, Arc, Edge, Brave).
- **Real-time Tab Sharing**: View and share active tabs across all browsers in real-time. Automatically filters out incognito tabs and non-HTTP(S) local pages to protect privacy, and intelligently deduplicates URLs across different browsers for a clean UI.
- **Flexible Sync Strategies**: Choose the synchronization logic that fits your workflow:
  - *Unidirectional (Master-slave)*
  - *Last-Write-Wins* (based on access time)
  - *Bidirectional Merging*
- **Granular Site Control**: Manage sync scope with whitelist/blacklist rules. Apply per-site policy overrides for ultimate customization.
- **Local & Secure**: All communication happens entirely on your machine via a local WebSocket daemon (`ws://127.0.0.1:62333`). No external servers are involved.
- **Native macOS Experience**: Built with SwiftUI. Supports Dark/Light themes, Menu Bar integration, and Launch at Login.

## 🛠 Installation & Setup

### 1. Requirements

| Tool | Version |
|------|---------|
| macOS | 14.0+ |
| Xcode | 15.0+ |
| Swift | 5.10+ |
| Homebrew | Latest |
| XcodeGen | 2.40+ |

### 2. Homebrew Cask

You can install BrowSync with Homebrew:

```bash
brew install --cask chentao1006/tap/browsync
```

Or tap the repository first:

```bash
brew tap chentao1006/tap
brew install --cask browsync
```

### 3. Build from Source

```bash
# 1. Clone the repo
git clone https://github.com/chentao1006/browsync.git
cd browsync

# 2. Generate Xcode project using XcodeGen
xcodegen generate

# 3. Open the generated project
open BrowSync.xcodeproj
```

Then in Xcode:
1. Select the **BrowSync** target → **Signing & Capabilities**
2. Set your **Development Team**
3. Press **⌘R** to build and run

### 4. Loading the Chromium Extension

For Chrome, Arc, Edge, or Brave:

1. Open the browser → go to `chrome://extensions/`
2. Enable **Developer Mode** (top-right toggle)
3. Click **Load Unpacked**
4. Select the `ChromiumExtension/` folder
5. The BrowSync extension icon will appear in the toolbar. Safari users can enable the native extension directly in Safari Settings.

## 🔍 Architecture & Protocol

### System Architecture

```text
Safari Extension           Chrome / Arc / Edge / Brave Extension
      │                                    │
      └──────────── WebSocket ─────────────┘
                         │
                  BrowSync Daemon
              ws://127.0.0.1:62333
                         │
                   BrowSync App
              (macOS native, SwiftUI)
```

### Directory Structure

```text
BrowSync/
├── BrowSync/                   # macOS App (Swift/SwiftUI)
│   ├── App/                    # Entry point, AppState
│   ├── Views/                  # Multi-tab UI (Browsers, Rules, Sync)
│   ├── Core/                   # DaemonServer, BrowserScanner, BrowserLauncher
│   ├── Models/                 # Data models (Browser, Rule, SyncModels, WSMessage)
│   ├── Services/               # RulesEngine, SyncService, SettingsService
│   └── Resources/              # Info.plist, Localizable.strings (en + zh-Hans)
│
├── BrowSyncExtension/          # Safari Web Extension target
│   ├── SafariWebExtensionHandler.swift
│   └── Resources/
│       ├── manifest.json
│       ├── background.js       # WebSocket client, bookmark/cookie/tab sharing
│       ├── content.js          # localStorage/sessionStorage proxy
│       ├── popup.html
│       └── popup.js
│
├── ChromiumExtension/          # Shared MV3 extension (Chrome/Arc/Edge/Brave)
│   ├── manifest.json
│   ├── background/
│   │   └── service-worker.js   # Same logic as Safari background.js
│   ├── content/
│   │   └── content-script.js
│   ├── popup/
│   │   ├── popup.html
│   │   └── popup.js
│   └── _locales/
│       ├── en/messages.json
│       └── zh_CN/messages.json
│
├── project.yml                 # XcodeGen configuration
├── BrowSync.entitlements       # App entitlements (Sandbox: NO)
├── package.sh                  # Script to package the app
├── release.sh                  # Script to automate releases
├── test.sh                     # Script to run tests
├── index.html                  # Landing page
└── privacy.html                # Privacy policy
```

### WebSocket Protocol

All browser extensions connect to the BrowSync daemon at `ws://127.0.0.1:62333`.

- **Registration**: `{ "type": "register", "browser": "chrome", "instanceId": "chrome-main" }`
- **Heartbeat (every 30s)**: `{ "type": "heartbeat" }`
- **Sync**: 
```json
{
  "type": "sync",
  "browser": "safari",
  "site": "chatgpt.com",
  "category": "bookmarks",
  "payload": { "kind": "bookmarks", "bookmarks": [...] },
  "messageId": "uuid",
  "timestamp": 1234567890
}
```

## 📁 Data Directory & Identifiers

BrowSync stores its data locally in your Application Support folder:

```text
~/Library/Application Support/BrowSync/
├── sites/          # Per-site sync state
├── bookmarks/      # Synced bookmark snapshots
├── history/        # History (when enabled)
├── logs/           # sync-YYYY-MM-DD.log
└── settings.json   # All app settings
```

**Bundle IDs:**
- App: `com.ct106.browsync`
- Safari Extension: `com.ct106.browsync.extension`
- App Group: `group.com.ct106.browsync`

## 🎯 Feature Status (MVP)

| Feature | Status |
|---------|--------|
| Browser detection & extension status | ✅ |
| WebSocket Daemon | ✅ |
| URL routing rules & Default browser handling | ✅ |
| Bookmark real-time sync | ✅ |
| localStorage & sessionStorage cross-browser sync | ✅ |
| Cookie cross-browser sync | ✅ |
| Real-time Tab Sharing (w/ deduplication & privacy filter) | ✅ |
| Granular site sync control | ✅ |
| Safari & Chromium MV3 Extensions | ✅ |
| Dark/Light/System theme & EN/zh-Hans localization | ✅ |

## ⚠️ Important Notes

- **Default Browser**: To utilize the URL routing feature, BrowSync must be set as your default system browser in macOS Settings.

## 🛡 License

© 2026 BrowSync. All rights reserved.
