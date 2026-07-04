# 同览 (BrowSync)

[简体中文] | [English](README.md)

**同览 (BrowSync)** 是一款 macOS 原生的跨浏览器分流与同步中枢。它打通 Safari、所有 Chromium 内核浏览器与 Firefox，智能分流链接并实时同步数据，为您统一浏览体验。

<a href="https://apps.apple.com/cn/app/id6784604835?mt=12"><img src="BrowSync/Resources/Marketing/download-on-app-store-zh.svg" height="40" alt="从 App Store 下载"></a> <a href="https://chrome.google.com/webstore/detail/nahmlhblgjnkkcmaiicngaepeepofpkh"><img src="BrowSync/Resources/Marketing/chrome-web-store-badge.png" height="40" alt="Available in the Chrome Web Store"></a> <a href="https://addons.mozilla.org/zh-CN/firefox/addon/brow-sync/"><img src="https://img.shields.io/badge/Firefox_Add--on-FF7139?style=for-the-badge&logo=firefox&logoColor=white" height="40" alt="获取 Firefox 附加组件"></a>



> [!IMPORTANT]
> **本地运行**
> 同览 (BrowSync) 的同步和 URL 分流通过本地 WebSocket 守护进程进行。浏览数据（书签、Cookie、本地存储、活动标签页等）保存在本地设备，不涉及外部服务器。

## 🚀 主要功能

- **URL 分流**：将同览设为 macOS 默认浏览器后，可根据域名、URL 规则、参数、来源应用或时间段，将链接自动定向到指定的浏览器。
- **书签同步**：在 Safari、所有 Chromium 内核浏览器和 Firefox 之间实时同步书签。
- **状态同步**：在各浏览器之间同步 Cookie、LocalStorage 和 sessionStorage，保持登录状态一致。
- **标签页共享**：跨浏览器查看当前打开的标签页。自动过滤无痕模式及非 HTTP(S) 协议页面，并对重复的 URL 进行去重。
- **同步策略**：支持单向同步（主从模式）、基于访问时间的最后写入者胜出、双向合并。
- **站点控制**：通过白名单/黑名单管理同步范围，支持为特定网站设置独立策略。
- **本地网络**：通信通过本地 WebSocket 守护进程 (`ws://127.0.0.1:62333`) 进行，不依赖外部服务器。
- **原生 macOS 应用**：使用 SwiftUI 构建，支持深色/浅色主题、菜单栏集成和登录时启动。
- **iCloud 同步**：通过 iCloud 在您的所有 Mac 设备之间自动同步分流规则、偏好设置和站点配置。

## 🌐 支持的浏览器

同览 (BrowSync) 开箱即支持多种主流浏览器，并允许您手动添加几乎任何基于 Chromium 内核的浏览器。

**原生支持的浏览器：**
- Safari
- Google Chrome
- Arc
- Microsoft Edge
- Brave
- Firefox
- Vivaldi
- Opera
- Yandex Browser
- Orion
- Helium
- BrowserOS

**自定义浏览器：**
如果您最喜欢的 Chromium 浏览器不在列表中，您可以轻松添加它！只需进入应用中的“浏览器”选项卡，点击底部 **"Add Custom Browser..."** 按钮，然后在 Applications（应用程序）文件夹中选择您的浏览器 `.app` 文件即可。

## 📸 界面截图

| | |
|:---:|:---:|
| ![截图 1](screenshots/zh/000001.jpg) | ![截图 2](screenshots/zh/000002.jpg) |
| ![截图 3](screenshots/zh/000003.jpg) | ![截图 4](screenshots/zh/000004.jpg) |
| ![截图 5](screenshots/zh/000005.jpg) | ![截图 6](screenshots/zh/000006.jpg) |
| ![截图 7](screenshots/zh/000007.jpg) | ![截图 8](screenshots/zh/000008.jpg) |

## 🛠 安装与设置

### 1. 环境要求

| 工具 | 版本要求 |
|------|---------|
| macOS | 14.0+ |
| Xcode | 15.0+ |
| Swift | 5.10+ |
| Homebrew | 最新版 |
| XcodeGen | 2.40+ |

### 2. App Store 安装

您可以从 Mac App Store 下载同览 (BrowSync)：
[从 App Store 下载](https://apps.apple.com/cn/app/id6784604835?mt=12)



### 3. 源码编译构建

```bash
# 1. 克隆仓库
git clone https://github.com/chentao1006/browsync.git
cd browsync

# 2. 使用 XcodeGen 生成 Xcode 项目
xcodegen generate

# 3. 打开生成的项目
open BrowSync.xcodeproj
```

在 Xcode 中：
1. 选择 **BrowSync** target → **Signing & Capabilities**
2. 设置您的 **Development Team**
3. 按下 **⌘R** 编译并运行

### 4. 安装浏览器扩展

**Chromium 内核浏览器**:
您可以直接从 Chrome 网上应用店安装同览 (BrowSync) 扩展：
[前往 Chrome Web Store 安装](https://chrome.google.com/webstore/detail/nahmlhblgjnkkcmaiicngaepeepofpkh)

**Firefox**:
您可以直接从 Firefox 附加组件页面安装同览 (BrowSync) 扩展：
[前往 Firefox 附加组件安装](https://addons.mozilla.org/zh-CN/firefox/addon/brow-sync/)

**Safari 浏览器**:
应用内置了原生的 Safari 扩展。运行 BrowSync 应用后，您可以在 Safari 的“设置” -> “扩展”中直接启用它。

## 🔍 架构与协议

### 系统架构

```text
Safari 扩展       Chromium 扩展       Firefox 扩展
      │                  │                   │
      └──────────────────┼───────────────────┘
                         │
                  BrowSync 守护进程
              ws://127.0.0.1:62333
                         │
                  BrowSync 客户端
              (macOS 原生, SwiftUI)
```

### 目录结构

```text
BrowSync/
├── BrowSync/                   # macOS 应用 (Swift/SwiftUI)
│   ├── App/                    # 入口点, AppState
│   ├── Views/                  # 多标签 UI 界面 (浏览器, 规则, 同步等)
│   ├── Core/                   # 守护进程, 浏览器扫描器, 启动器
│   ├── Models/                 # 数据模型 (浏览器, 规则, 同步模型, WS消息)
│   ├── Services/               # 规则引擎, 同步服务, 设置服务
│   └── Resources/              # Info.plist, 国际化字符串 (en + zh-Hans)
│
├── SafariExtension/            # Safari 网页扩展 target
│   ├── SafariWebExtensionHandler.swift
│   └── Resources/
│       ├── manifest.json
│       ├── background.js       # WebSocket 客户端, 书签/cookie/共享标签页
│       ├── content.js          # localStorage/sessionStorage 代理
│       ├── popup.html
│       └── popup.js
│
├── ChromiumExtension/          # 共享 MV3 扩展 (Chromium 内核)
│   ├── manifest.json
│   ├── background/
│   │   └── service-worker.js   # 逻辑与 Safari background.js 相同
│   ├── content/
│   │   └── content-script.js
│   ├── popup/
│   │   ├── popup.html
│   │   └── popup.js
│   └── _locales/
│       ├── en/messages.json
│       └── zh_CN/messages.json
│
├── FirefoxExtension/           # Firefox MV3 扩展
│   ├── manifest.json           # 包含 Firefox 专用的 CSP 和设置
│   └── (结构与 ChromiumExtension 相同)
│
├── project.yml                 # XcodeGen 配置
├── BrowSync.entitlements       # 应用权限 (不使用沙盒)
├── package.sh                  # 打包脚本
├── release.sh                  # 发布脚本
├── test.sh                     # 测试脚本
├── index.html                  # 官网主页
└── privacy.html                # 隐私政策
```

### WebSocket 协议

所有浏览器扩展均连接到位于 `ws://127.0.0.1:62333` 的 BrowSync 守护进程。

- **注册 (Registration)**: `{ "type": "register", "browser": "chrome", "instanceId": "chrome-main" }`
- **心跳 (Heartbeat, 每30秒)**: `{ "type": "heartbeat" }`
- **同步 (Sync)**: 
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

## 📁 数据目录与标识符

BrowSync 将其数据本地存储在您的 Application Support 文件夹中：

```text
~/Library/Application Support/BrowSync/
├── sites/          # 各站点的同步状态
├── bookmarks/      # 同步的书签快照
├── logs/           # sync-YYYY-MM-DD.log (同步日志)
└── settings.json   # 所有应用设置
```

**Bundle IDs:**
- App: `com.ct106.browsync`
- Safari Extension: `com.ct106.browsync.extension`
- App Group: `group.com.ct106.browsync`

## 🎯 功能状态 (MVP)

| 功能 | 状态 |
|---------|--------|
| 浏览器检测与扩展状态 | ✅ |
| WebSocket 守护进程 | ✅ |
| URL 分流规则与默认浏览器处理 | ✅ |
| 书签实时同步 | ✅ |
| localStorage 与 sessionStorage 跨浏览器同步 | ✅ |
| Cookie 跨浏览器同步 | ✅ |
| 实时标签页共享 (去重与隐私过滤) | ✅ |
| 细粒度站点同步控制 | ✅ |
| Safari, Chromium 与 Firefox MV3 扩展 | ✅ |
| 深色/浅色/系统主题与中英文国际化 | ✅ |
| iCloud 规则与设置同步 | ✅ |

## ⚠️ 重要提示

- **默认浏览器**：要使用 URL 分流功能，必须在 macOS 设置中将 BrowSync 设置为默认系统浏览器。

## 🛡 许可证

本项目采用 MIT License，详见 [LICENSE](LICENSE)。
