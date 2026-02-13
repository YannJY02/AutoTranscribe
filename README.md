# 🎙 AutoTranscribe

<p align="center">
  <strong>
    <a href="#-features">Features</a> •
    <a href="#-quick-start">Quick Start</a> •
    <a href="#-architecture">Architecture</a> •
    <a href="#-中文说明">中文说明</a>
  </strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-compatible-brightgreen?logo=apple" alt="macOS">
  <img src="https://img.shields.io/badge/Python-3.11-blue?logo=python" alt="Python 3.11">
  <img src="https://img.shields.io/badge/FunASR-1.3-orange" alt="FunASR">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License">
</p>

**AutoTranscribe** is a fully automated, offline video transcription system for macOS. It monitors your Desktop and Downloads for new video files, prompts for confirmation, then automatically transcribes audio with speaker diarization — all running locally with zero cloud costs.

---

## ✨ Features

| Feature                     | Description                                                               |
| --------------------------- | ------------------------------------------------------------------------- |
| 🎯 **Auto-Detection**       | Monitors `~/Desktop` and `~/Downloads` via macOS FSEvents (near-zero CPU) |
| 🌐 **Language Detection**   | Automatically detects Chinese, English, or mixed (en_cn) content          |
| 🗣️ **Speaker Diarization**  | Identifies and labels different speakers (2–4 people)                     |
| ⏱️ **Timestamps**           | Sentence-level timestamps for every segment                               |
| 📝 **Markdown Output**      | Clean, readable `.md` files with metadata and speaker labels              |
| 🔔 **Native Notifications** | Stage-by-stage progress + result dialog via macOS Notification Center     |
| 🔄 **Weekly Auto-Update**   | Automatically updates models and dependencies every Sunday                |
| 🚀 **Boot on Startup**      | LaunchAgent ensures the service runs automatically                        |
| 🔒 **100% Offline**         | All processing happens locally — no data leaves your machine              |

## 🚀 Quick Start

### Prerequisites

- **macOS** (Apple Silicon or Intel)
- **[Miniconda](https://docs.conda.io/en/latest/miniconda.html)** or Anaconda
- **ffmpeg** (`brew install ffmpeg`)

### Installation

```bash
git clone https://github.com/YannJY02/AutoTranscribe.git
cd AutoTranscribe
bash install.sh
```

That's it! The installer will:

1. Create a conda environment (`transcribe`, Python 3.11)
2. Install all dependencies (FunASR, PyTorch, etc.)
3. Set up directory structure
4. Register LaunchAgents for auto-start and weekly updates

### Usage

**Just save a video file to your Desktop or Downloads.** A dialog will appear:

1. 📋 **Confirm** — Click "转录" to start, or "跳过" to skip
2. ⏳ **Progress** — Notification center shows 4 stages (extract → detect → transcribe → save)
3. ✅ **Result** — A popup shows full stats: language, duration, segments, speakers

### Output

Transcription files are saved to `txt/` with standardized names:

```
txt/2026_2_13_zh_1.md      # Chinese
txt/2026_2_13_en_1.md      # English
txt/2026_2_13_en_cn_1.md   # Mixed Chinese-English
```

### Management

```bash
bash status.sh    # View service status
bash stop.sh      # Stop the service
bash start.sh     # Start the service
```

## 🏗️ Architecture

```
AutoTranscribe/
├── scripts/
│   ├── config.py          # Paths, model names, constants
│   ├── notifier.py        # macOS dialogs & notifications
│   ├── transcriber.py     # FunASR engine (LID + ASR + diarization)
│   ├── file_manager.py    # Naming, moving, Markdown generation
│   ├── watcher.py         # FSEvents file monitoring
│   ├── main.py            # Entry point & orchestration
│   └── update.py          # Weekly model & dependency updater
├── install.sh             # One-click installer
├── start.sh / stop.sh / status.sh
├── video/                 # (gitignored) Processed videos
├── txt/                   # (gitignored) Transcription output
└── logs/                  # (gitignored) Runtime logs
```

### Models Used

| Component   | Model            | Purpose                  |
| ----------- | ---------------- | ------------------------ |
| Language ID | SenseVoiceSmall  | Detect zh / en / mixed   |
| ASR         | Paraformer-large | Speech-to-text (zh + en) |
| VAD         | FSMN-VAD         | Voice activity detection |
| Punctuation | CT-Transformer   | Sentence segmentation    |
| Speaker     | CAM++            | Speaker diarization      |

All models are from [FunASR](https://github.com/modelscope/FunASR) / [ModelScope](https://modelscope.cn) and are downloaded automatically on first use (~1–2 GB).

## 📄 License

MIT License — see [LICENSE](LICENSE) for details.

---

# 🎙 AutoTranscribe — 中文说明

**AutoTranscribe** 是一个全自动的本地视频转录系统，专为 macOS 设计。它监控桌面和下载文件夹中的新视频文件，弹窗确认后自动完成语音转文字和说话人分离，全程本地运行，零云端费用。

## ✨ 功能特点

- 🎯 **自动检测** — 通过 macOS FSEvents 监控桌面和下载目录，待机 CPU 占用近零
- 🌐 **语言识别** — 自动检测中文、英文或中英混合内容
- 🗣️ **说话人分离** — 自动识别并标注不同说话人（2-4 人）
- ⏱️ **时间戳** — 每句话都有精确的起止时间
- 📝 **Markdown 输出** — 包含元信息、时间戳和说话人标签的清晰文档
- 🔔 **原生通知** — 转录各阶段进度通知 + 完成结果弹窗
- 🔄 **每周自动更新** — 每周日自动更新模型和 Python 依赖
- 🚀 **开机自启** — LaunchAgent 保证服务随系统自动启动
- 🔒 **完全离线** — 所有处理都在本地完成，数据不会上传

## 🚀 快速开始

### 前置条件

- **macOS**（Apple Silicon 或 Intel）
- **[Miniconda](https://docs.conda.io/en/latest/miniconda.html)** 或 Anaconda
- **ffmpeg**（`brew install ffmpeg`）

### 安装

```bash
git clone https://github.com/YannJY02/AutoTranscribe.git
cd AutoTranscribe
bash install.sh
```

安装脚本会自动完成所有配置：创建 conda 环境、安装依赖、建立目录结构、注册开机自启。

### 使用方法

**只需将视频保存到桌面或下载文件夹**，系统会自动弹窗提示：

1. 📋 **确认** — 点击「转录」开始，或「跳过」忽略
2. ⏳ **进度** — 通知中心分 4 个阶段显示进度（提取音频 → 检测语言 → 转录 → 保存）
3. ✅ **结果** — 弹窗显示完整统计：语言、时长、耗时、片段数、说话人数

### 输出格式

转录文稿保存在 `txt/` 目录，文件名标准化：

```
txt/2026_2_13_zh_1.md       # 中文
txt/2026_2_13_en_1.md       # 英文
txt/2026_2_13_en_cn_1.md    # 中英混合
```

### 管理命令

```bash
bash status.sh    # 查看服务状态
bash stop.sh      # 停止服务
bash start.sh     # 启动服务
```

## 📄 许可证

MIT 开源协议
