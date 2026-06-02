# 同览 (BrowSync)

[简体中文] | [English](README.md)

**同览 (BrowSync)** 是一款原生 macOS 应用，旨在让 Safari、Chrome、Arc、Edge 和 Brave 协同工作。它通过本地 WebSocket 守护进程、浏览器扩展、智能 URL 分流规则以及跨浏览器数据同步，统一您的浏览体验。

[![下载 同览](https://img.shields.io/badge/同览-最新版本-blue?style=for-the-badge&logo=apple)](https://github.com/chentao1006/browsync/releases/latest)

> [!IMPORTANT]
> **隐私优先的设计理念**
> 同览 (BrowSync) 基于严格的隐私优先架构构建。所有的同步和 URL 分流完全通过本地 WebSocket 守护进程在您的**本地设备上**进行。您的浏览数据（历史记录、书签、Cookie 等）**绝对不会**离开您的电脑，也不涉及任何外部服务器或云服务参与。

## 🚀 核心功能

- **智能 URL 分流**：将同览注册为 macOS 的默认浏览器。其强大的规则引擎可根据域名、URL 模式、查询参数、来源应用、时间段或专注模式，自动将链接定向到您偏好的浏览器。
- **跨浏览器同步**：在 Safari 和基于 Chromium 的浏览器（Chrome、Arc、Edge、Brave）之间无缝同步 Cookie、LocalStorage、sessionStorage、标签页状态和书签。
- **灵活的同步策略**：选择适合您工作流的同步逻辑：
  - *单向同步 (主从模式)*
  - *最后写入者胜出 (基于访问时间)*
  - *双向合并*
- **细粒度控制**：通过白名单/黑名单规则管理同步范围。为特定网站应用独立策略，实现极致的自定义。
- **本地化与安全**：所有通信都通过本地 WebSocket 守护进程 (`ws://127.0.0.1:62333`) 在您的设备上完成。不依赖任何外部服务器。
- **原生 macOS 体验**：使用 SwiftUI 构建。全面支持深色/浅色主题、菜单栏集成、专注模式和登录时启动。

## 🛠 安装与设置

### 1. 环境要求

| 工具 | 版本要求 |
|------|---------|
| macOS | 14.0+ |
| Xcode | 15.0+ |
| Swift | 5.10+ |
| Homebrew | 最新版 |
| XcodeGen | 2.40+ |

### 2. 快速开始

```bash
# 1. 克隆仓库
git clone https://github.com/chentao1006/browsync.git
cd browsync

# 2. 运行配置脚本
chmod +x setup.sh
./setup.sh

# 3. 打开生成的项目
open BrowSync.xcodeproj
```

在 Xcode 中：
1. 选择 **BrowSync** target → **Signing & Capabilities**
2. 设置您的 **Development Team**
3. 按下 **⌘R** 编译并运行

### 3. 加载 Chromium 扩展程序

适用于 Chrome, Arc, Edge, 或 Brave：

1. 打开浏览器 → 访问 `chrome://extensions/`
2. 开启右上角的 **开发者模式 (Developer Mode)**
3. 点击 **加载已解压的扩展程序 (Load Unpacked)**
4. 选择 `ChromiumExtension/` 文件夹
5. BrowSync 扩展图标将出现在工具栏中。Safari 用户可以直接在 Safari 设置中启用该扩展。

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
│   ├── Views/                  # 5标签 UI 界面
│   ├── Core/                   # 守护进程, 浏览器扫描器, 启动器
│   ├── Models/                 # 数据模型 (浏览器, 规则, 同步模型, WS消息)
│   ├── Services/               # 规则引擎, 同步服务, 设置服务
│   └── Resources/              # Info.plist, 国际化字符串 (en + zh-Hans)
│
├── BrowSyncExtension/          # Safari 网页扩展 target
│   ├── SafariWebExtensionHandler.swift
│   └── Resources/
│       ├── manifest.json
│       ├── background.js       # WebSocket 客户端, 书签/cookie/标签页同步
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
└── setup.sh                    # 一键环境配置脚本
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
├── logs/           # sync.log (同步日志)
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
| 书签同步 | ✅ |
| localStorage 与 sessionStorage 同步 | ✅ |
| Cookie 同步 | ✅ |
| 标签页状态同步 | ✅ |
| Safari 与 Chromium 扩展 | ✅ |
| 专注模式支持 (数据过滤与 UI) | ✅ |
| 深色/浅色/系统主题与中英文国际化 | ✅ |
| 自动同步与 iCloud 云同步 | 🔜 PRO |
| 历史记录同步 | ⚠️ 默认禁用 |

## ⚠️ 重要提示

- **默认浏览器**：要使用 URL 分流功能，必须在 macOS 设置中将 BrowSync 设置为默认系统浏览器。
- **历史记录同步**：出于性能和隐私的考量，历史记录同步目前默认处于禁用状态。

## 🛡 许可证

© 2026 BrowSync. 保留所有权利。
