# Island Radio

运行在 macOS Dynamic Island 上的网络电台应用，带实时语音字幕和单词查询功能。

## 它解决什么问题

听外语电台是提升语感的有效方式，但传统电台应用缺少两个关键能力：

1. **听不懂的词只能跳过** — 没有即时查询，听过就忘
2. **没有字幕辅助** — 纯听觉输入，初学者难以跟上

Island Radio 把电台播放、实时字幕、即时查词整合到 macOS Dynamic Island 这个始终可见的入口里，无需切换应用即可完成「听 → 看字幕 → 点词查义 → 加入生词本」的闭环。

## 架构与原理

### 整体流程

```
┌─────────────────────────────────────────────────────────────┐
│                      Island Radio App                       │
│                                                             │
│  ┌──────────┐    ┌──────────────┐    ┌───────────────────┐  │
│  │ AudioPlayer│    │ STTBridgeServer│   │    LLMService     │  │
│  │           │    │ (localhost     │   │ (OpenAI/Anthropic)│  │
│  │ AVPlayer  │    │  :17394)      │   │                   │  │
│  └─────┬─────┘    └──────┬───────┘    └────────┬──────────┘  │
│        │                  │                      │            │
│        │          WebSocket│                      │            │
│        │                  │                      │            │
│  ┌─────▼──────┐    ┌──────▼───────┐    ┌────────▼──────────┐  │
│  │  音频流播放  │    │  字幕数据     │    │   单词翻译结果     │  │
│  │ (本地解码)  │    │  (JSON)      │    │   (JSON)          │  │
│  └────────────┘    └──────────────┘    └───────────────────┘  │
│                                                             │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │              IslandCapsuleView (Dynamic Island)          │  │
│  │  [电台名] 🎵 ▶ ⏭ 🎙  │  字幕文字（可点击查词）           │  │
│  └─────────────────────────────────────────────────────────┘  │
│                                                             │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │              MainContentView (主窗口)                     │  │
│  │  电台列表 │ 生词本 │ STT 连接状态 │ LLM 配置              │  │
│  └─────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                         │
                    WebSocket (localhost:17394)
                         │
              ┌──────────▼──────────┐
              │   浏览器 STT 页面     │
              │ (自动打开 localhost)  │
              │                      │
              │ Web Speech API       │
              │ (麦克风采集 → 识别)   │
              └──────────────────────┘
```

### 音频播放 — AudioPlayer

- 基于 `AVPlayer` 解码和播放网络音频流
- 支持 AAC 直播流（`.aac`）和 HLS 点播/直播流（`.m3u8`）
- 对 m3u8 视频流：解析 master playlist，自动选择纯音频变体（避免下载视频数据）；若无纯音频变体，则禁用视频轨道，只播放音频
- 连通性检测：启动时对所有电台做 HEAD/GET 请求，绿色=可达、红色=不可达、灰色=检测中

### 语音转字幕 — STTBridgeServer

> 音频播放和语音识别是**两条独立线路**，岛不会把音频数据发给浏览器。

IslandRadio 在本地启动一个 TCP 服务器（端口 17394），同时提供两个能力：

1. **`GET /`** — 返回一个内嵌的 HTML 页面，页面里使用浏览器原生的 **Web Speech API** (`webkitSpeechRecognition`) 进行语音识别
2. **WebSocket** — 与浏览器页面双向通信，传递控制指令和识别结果

工作流程：

```
用户点击录音 → IslandRadio 发送 {"type":"start","lang":"en-US"}
                → 浏览器页面启动 SpeechRecognition（监听麦克风）
                → 识别结果通过 WebSocket 回传 {"type":"result","text":"...","isFinal":true}
                → IslandRadio 更新字幕显示在 Island 上
```

关键点：
- 语音识别的音频源是**浏览器麦克风**（系统音频或环境音），不是 IslandRadio 的播放流
- 识别由浏览器内置的 Web Speech API 完成（通常调用 Google 云端 API），岛本身不做语音识别
- 浏览器页面由 IslandRadio 自动打开，用户只需保持该页面即可
- 支持多语言：en-US / zh-CN / ja-JP / ko-KR / fr-FR / de-DE，随电台语言自动切换

### 音频路由 — BlackHole 聚合设备

Web Speech API 只能从**麦克风输入**采集音频，无法直接访问系统音频输出。如果希望 STT 识别的是电台正在播放的声音（而非房间环境音），需要将系统音频"回环"到麦克风输入。这通过 **BlackHole + 聚合设备** 实现。

#### 为什么需要

```
没有 BlackHole 时：
  电台音频 → 扬声器播放 → 环境空气 → 麦克风拾取 → Speech API
  ❌ 音质差、延迟高、受环境噪音干扰

有 BlackHole 时：
  电台音频 → BlackHole 虚拟设备 → Speech API
             ↘ 扬声器同时播放 → 用户也能听到
  ✅ 纯数字回环，无音质损失，无线性延迟
```

#### 设置步骤

1. **安装 BlackHole** — 从 [existential.audio/blackhole](https://existential.audio/blackhole/) 下载安装（免费，2ch 版本即可）

2. **创建聚合设备** — 打开"音频 MIDI 设置"（Audio MIDI Setup）：
   - 点击左下角 `+` → "创建聚合设备"
   - 勾选 **BlackHole 2ch** 和 **外接扬声器/耳机**（两者都要勾，确保既能录音又能听到声音）
   - 将聚合设备设为默认输出设备

3. **设置浏览器麦克风输入** — 在浏览器 STT 页面或 Chrome 设置中，将麦克风输入选为 **BlackHole 2ch** 或聚合设备

4. **验证** — 播放电台，确认扬声器有声音，且 STT 页面能识别出电台内容

#### 音频路由关系图

```
┌──────────────┐
│  IslandRadio │ (AVPlayer 解码播放)
│  音频输出     │
└──────┬───────┘
       │ 系统音频流
       ▼
┌──────────────────────────┐
│    聚合设备 (Aggregate)    │
│  ┌─────────┐ ┌─────────┐ │
│  │BlackHole│ │ 扬声器   │ │  ← 两者同时接收音频
│  │  2ch    │ │/耳机    │ │
│  └────┬────┘ └────┬────┘ │
└───────┼───────────┼──────┘
        │           │
        ▼           ▼
  浏览器麦克风     用户听到声音
  (Speech API     (正常收听)
   语音识别)
```

> **提示**：如果只想识别自己的语音（跟读练习），无需配置 BlackHole，直接用物理麦克风即可。
> BlackHole 仅在需要识别电台音频时配置。

### 单词查询 — LLMService

在 Island 字幕上点击任意单词：

1. 暂停播放
2. 显示 Loading 卡片
3. 调用 LLM API（OpenAI 兼容 / Anthropic）获取翻译，包含：音标、词根分析、自然拼读分解、释义、例句、整句翻译、词汇等级
4. 展示结果卡片，同时加入生词本
5. 关闭卡片后自动恢复播放

LLM 返回的翻译结果会缓存到本地（UserDefaults），同一词 + 句子不重复调用 API。

### 生词本 — WordStore

- 已学单词在 Island 字幕中高亮显示
- 从字幕中一眼识别哪些词已经学过
- 支持标记"已掌握"
- 数据持久化到 UserDefaults

### Dynamic Island — IslandCapsuleView

利用 macOS 14+ 的 `NSPanel` 模拟 Dynamic Island 效果：

- 始终置顶、透明背景、无标题栏
- 显示当前电台、播放控制、录音状态
- 实时滚动字幕，已学单词高亮可点击
- 查词卡片弹出动画

### 媒体键支持

注册系统媒体键（播放/暂停、下一首），键盘快捷键 `Cmd+Shift+M` 切换录音状态。

## 构建

### 依赖

- macOS 14.0+
- Xcode 15+ / Swift 5.9+
- 无第三方依赖

### 构建 .app

```bash
cd IslandRadio
chmod +x build.sh
./build.sh
```

`build.sh` 执行：`swift build` → 复制二进制到 `.app` bundle → ad-hoc 签名（带 entitlements）→ 清除扩展属性

## 项目结构

```
IslandRadio/
├── Sources/IslandRadio/
│   ├── IslandRadioApp.swift          # 入口，AppDelegate 管理生命周期
│   ├── Island/
│   │   ├── IslandWindow.swift        # NSPanel 封装，模拟 Dynamic Island
│   │   └── IslandCapsuleView.swift   # Island SwiftUI 视图
│   ├── Views/
│   │   └── MainContentView.swift     # 主窗口：电台列表、生词本、设置
│   ├── Services/
│   │   ├── AudioPlayer.swift         # AVPlayer 音频播放 + m3u8 解析 + 连通检测
│   │   ├── STTBridgeServer.swift     # WebSocket 服务器 + 内嵌 STT 页面
│   │   ├── LLMService.swift          # OpenAI/Anthropic 翻译 API
│   │   └── Logger.swift              # 统一日志
│   ├── Models/
│   │   ├── RadioStation.swift        # 电台模型 + 语言选项
│   │   ├── StationStore.swift        # 电台列表持久化
│   │   └── WordStore.swift           # 生词本 + 翻译缓存
│   └── Resources/                    # App Icon 等资源
├── Package.swift                      # SPM 配置
├── IslandRadio.entitlements           # 沙盒/网络权限
└── build.sh                           # 构建脚本
```

## 配置

- **LLM API**：主窗口设置页配置 Provider / Endpoint / API Key / Model
- **STT 语言**：每个电台可设置 BCP-47 语言代码，播放时自动传给 Speech API
- **电台管理**：支持添加、编辑、删除电台，支持 AAC 直播流和 m3u8 流

## 已知限制

- STT 依赖浏览器 Web Speech API，需保持浏览器标签页打开
- Web Speech API 默认只采集麦克风输入；要识别电台音频需配置 BlackHole 聚合设备（见上方"音频路由"章节）
- ad-hoc 签名，未公证；首次打开需在系统设置中允许
- 仅支持 macOS 14+