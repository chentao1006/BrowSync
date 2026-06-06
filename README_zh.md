# 同览 (BrowSync)

[简体中文] | [English](README.md)

**同览 (BrowSync)** 是一款原生 macOS 应用，旨在让 Safari、Chrome、Arc、Edge 和 Brave 协同工作。它通过本地 WebSocket 守护进程、浏览器扩展、智能 URL 分流规则以及跨浏览器数据同步，统一您的浏览体验。

[![下载 同览](https://img.shields.io/badge/同览-最新版本-blue?style=for-the-badge&logo=apple)](https://github.com/chentao1006/browsync/releases/latest)

```bash
brew install --cask chentao1006/tap/browsync
```

> [!IMPORTANT]
> **隐私优先的设计理念**
> 同览 (BrowSync) 基于严格的隐私优先架构构建。所有的同步和 URL 分流完全通过本地 WebSocket 守护进程在您的**本地设备上**进行。您的浏览数据（历史记录、书签、Cookie 等）**绝对不会**离开您的电脑，也不涉及任何外部服务器或云服务参与。

## 🚀 核心功能

- **智能 URL 分流**：将同览注册为 macOS 的默认浏览器。其强大的规则引擎可根据域名、URL 模式、查询参数、来源应用或时间段，自动将链接定向到您偏好的浏览器。
- **跨浏览器状态同步**：在 Safari 和基于 Chromium 的浏览器（Chrome、Arc、Edge、Brave）之间无缝同步 Cookie、LocalStorage、sessionStorage 和书签。
- **实时标签页共享 (Tab Sharing)**：跨浏览器实时查看和共享当前打开的标签页。支持自动过滤无痕模式及非 HTTP(S) 协议页面，并对跨浏览器相同 URL 进行智能去重展示，既保护隐私又保持界面清爽。
- **灵活的同步策略**：选择适合您工作流的同步逻辑：
  - *单向同步 (主从模式)*
  - *最后写入者胜出 (基于访问时间)*
  - *双向合并*
- **细粒度站点控制**：通过白名单/黑名单规则管理同步范围。为特定网站应用独立策略，实现极致的自定义。
- **本地化与安全**：所有通信都通过本地 WebSocket 守护进程 (`ws://127.0.0.1:62333`) 在您的设备上完成。不依赖任何外部服务器。
- **原生 macOS 体验**：使用 SwiftUI 构建。全面支持深色/浅色主题、菜单栏集成和登录时启动。

## 🛠 安装与设置

### 1. 环境要求

| 工具 | 版本要求 |
|------|---------|
| macOS | 14.0+ |
| Xcode | 15.0+ |
| Swift | 5.10+ |
| Homebrew | 最新版 |
| XcodeGen | 2.40+ |

### 2. Homebrew Cask 安装

您可以使用 Homebrew 安装同览 (BrowSync)：

```bash
brew install --cask chentao1006/tap/browsync
```

或者先添加 tap 仓库：

```bash
brew tap chentao1006/tap
brew install --cask browsync
```

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

### 4. 加载 Chromium 扩展程序

适用于 Chrome, Arc, Edge, 或 Brave：

1. 打开浏览器 → 访问 `chrome://extensions/`
2. 开启右上角的 **开发者模式 (Developer Mode)**
3. 点击 **加载已解压的扩展程序 (Load Unpacked)**
4. 选择 `ChromiumExtension/` 文件夹
5. BrowSync 扩展图标将出现在工具栏中。Safari 用户可以直接在 Safari 设置中启用对应的原生扩展。

## 🔍 架构与协议

### 系统架构

```text
Safari 扩展                 Chrome / Arc / Edge / Brave 扩展
      │                                    │
      └──────────── WebSocket ─────────────┘
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
├── BrowSyncExtension/          # Safari 网页扩展 target
│   ├── SafariWebExtensionHandler.swift
│   └── Resources/
│       ├── manifest.json
│       ├── background.js       # WebSocket 客户端, 书签/cookie/共享标签页
│       ├── content.js          # localStorage/sessionStorage 代理
│       ├── popup.html
│       └── popup.js
│
├── ChromiumExtension/          # 共享 MV3 扩展 (Chrome/Arc/Edge/Brave)
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
├── history/        # 历史记录 (启用时)
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
| Safari 与 Chromium MV3 扩展 | ✅ |
| 深色/浅色/系统主题与中英文国际化 | ✅ |

## ⚠️ 重要提示

- **默认浏览器**：要使用 URL 分流功能，必须在 macOS 设置中将 BrowSync 设置为默认系统浏览器。

## 🛡 许可证

© 2026 BrowSync. 保留所有权利。
