# BrowSync（同览）

**让多个浏览器协同工作。**

A macOS native app that makes Safari, Chrome, Arc, Edge, and Brave work together — unified through a local WebSocket daemon with browser extensions, URL routing rules, and cross-browser data sync.

---

## Requirements

| Tool | Version |
|------|---------|
| macOS | 14.0+ |
| Xcode | 15.0+ |
| Swift | 5.10+ |
| Homebrew | Latest |
| XcodeGen | 2.40+ |

---

## Quick Start

```bash
# 1. Clone the repo
git clone https://github.com/chentao1006/browsync.git
cd browsync

# 2. Run the setup script
chmod +x setup.sh
./setup.sh

# 3. Open the generated project
open BrowSync.xcodeproj
```

Then in Xcode:
1. Select the **BrowSync** target → **Signing & Capabilities**
2. Set your **Development Team**
3. Press **⌘R** to build and run

---

## Loading the Chromium Extension

For Chrome, Arc, Edge, or Brave:

1. Open the browser → go to `chrome://extensions/`
2. Enable **Developer Mode** (top-right toggle)
3. Click **Load Unpacked**
4. Select the `ChromiumExtension/` folder
5. The BrowSync extension icon will appear in the toolbar

---

## Architecture

```
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

```
BrowSync/
├── BrowSync/                   # macOS App (Swift/SwiftUI)
│   ├── App/                    # Entry point, AppState
│   ├── Views/                  # 5-tab UI
│   │   ├── Browsers/           # Tab 1: Browser status
│   │   ├── Rules/              # Tab 2: URL routing rules
│   │   ├── Sync/               # Tab 3: Sync settings
│   │   ├── General/            # Tab 4: App settings
│   │   └── About/              # Tab 5: About + diagnostics
│   ├── Core/                   # DaemonServer, BrowserScanner, BrowserLauncher
│   ├── Models/                 # Data models (Browser, Rule, SyncModels, WSMessage)
│   ├── Services/               # RulesEngine, SyncService, SettingsService
│   └── Resources/              # Info.plist, Localizable.strings (en + zh-Hans)
│
├── BrowSyncExtension/          # Safari Web Extension target
│   ├── SafariWebExtensionHandler.swift
│   └── Resources/
│       ├── manifest.json
│       ├── background.js       # WebSocket client, bookmark/cookie/tab sync
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
├── BrowSyncExtension.entitlements
└── setup.sh                    # One-command project setup
```

---

## WebSocket Protocol

All browser extensions connect to the BrowSync daemon at `ws://127.0.0.1:62333`.

### Registration
```json
{ "type": "register", "browser": "chrome", "instanceId": "chrome-main" }
```

### Heartbeat (every 30s)
```json
{ "type": "heartbeat" }
```

### Sync
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

---

## Data Directory

```
~/Library/Application Support/BrowSync/
├── sites/          # Per-site sync state
├── bookmarks/      # Synced bookmark snapshots
├── history/        # History (when enabled)
├── logs/           # sync.log
└── settings.json   # All app settings
```

---

## Bundle IDs

| Target | Bundle ID |
|--------|-----------|
| App | `com.ct106.browsync` |
| Safari Extension | `com.ct106.browsync.extension` |
| App Group | `group.com.ct106.browsync` |

---

## Internationalization

All UI strings use `String(localized:)` and `Localizable.strings`.

| Language | Code |
|----------|------|
| English | `en` |
| 简体中文 | `zh-Hans` |

To add a new language:
1. Create `BrowSync/Resources/<lang-code>.lproj/Localizable.strings`
2. Add the language code to `CFBundleLocalizations` in `Info.plist`

---

## Feature Status (MVP)

| Feature | Status |
|---------|--------|
| Browser detection | ✅ |
| Browser extension status | ✅ |
| WebSocket Daemon | ✅ |
| Bookmark sync | ✅ |
| localStorage sync | ✅ |
| sessionStorage sync | ✅ |
| Cookie sync | ✅ |
| Tab state sync | ✅ |
| URL routing rules | ✅ |
| Default browser handling | ✅ |
| Safari Extension | ✅ |
| Chrome/Arc/Edge/Brave Extension | ✅ |
| Launch at Login | ✅ |
| Menu Bar icon | ✅ |
| Dark/Light/System theme | ✅ |
| EN + 简体中文 localization | ✅ |
| Focus Mode (data + UI) | ✅ |
| Automatic Sync | 🔜 PRO |
| iCloud Sync | 🔜 PRO |
| Sparkle auto-update | 🔜 Phase 2 |
| History sync | ⚠️ Off by default |

---

## License

© 2026 BrowSync. All rights reserved.
