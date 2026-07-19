# Island Radio

An internet radio app that runs on the macOS Dynamic Island, with real-time speech subtitles and instant word lookup.

## What Problem It Solves

Listening to foreign-language radio is a great way to build language intuition, but traditional radio apps lack two key capabilities:

1. **No instant lookup** — unfamiliar words are forgotten the moment they pass
2. **No subtitle support** — pure audio input makes it hard for beginners to follow along

Island Radio combines radio playback, real-time subtitles, and instant word lookup into the macOS Dynamic Island — an always-visible entry point that lets you complete the full loop of *listen → read subtitles → tap a word → save to vocabulary* without switching apps.

## Architecture

### Overview

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
│  │ Audio Stream│    │  Subtitle    │    │  Word Translation │  │
│  │ Playback   │    │  Data (JSON) │    │  Result (JSON)    │  │
│  └────────────┘    └──────────────┘    └───────────────────┘  │
│                                                             │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │              IslandCapsuleView (Dynamic Island)          │  │
│  │  [Station] 🎵 ▶ ⏭ 🎙  │  Subtitle (tap to look up)     │  │
│  └─────────────────────────────────────────────────────────┘  │
│                                                             │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │              MainContentView (Main Window)               │  │
│  │  Stations │ Vocabulary │ STT Status │ LLM Config         │  │
│  └─────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                         │
                    WebSocket (localhost:17394)
                         │
              ┌──────────▼──────────┐
              │   Browser STT Page   │
              │ (auto-opens on       │
              │  localhost)          │
              │                      │
              │ Web Speech API       │
              │ (mic → recognition)  │
              └──────────────────────┘
```

### Audio Playback — AudioPlayer

- Built on `AVPlayer` for decoding and streaming network audio
- Supports AAC live streams (`.aac`) and HLS streams (`.m3u8`)
- For m3u8 video streams: parses the master playlist and automatically selects an audio-only variant to avoid downloading video data; falls back to disabling video tracks if no audio-only variant exists
- Connectivity check: performs HEAD/GET requests to all stations at startup — green = reachable, red = unreachable, gray = checking

### Speech-to-Text Subtitles — STTBridgeServer

> Audio playback and speech recognition run on **two independent paths** — the Island never sends audio data to the browser.

Island Radio starts a local TCP server (port 17394) that provides two capabilities:

1. **`GET /`** — serves an embedded HTML page using the browser's native **Web Speech API** (`webkitSpeechRecognition`) for speech recognition
2. **WebSocket** — bidirectional communication with the browser page for control commands and recognition results

Workflow:

```
User taps record → IslandRadio sends {"type":"start","lang":"en-US"}
                  → Browser page starts SpeechRecognition (listens via mic)
                  → Results sent back via WebSocket {"type":"result","text":"...","isFinal":true}
                  → IslandRadio updates subtitles on the Island
```

Key points:
- The audio source for speech recognition is the **browser microphone** (system audio or ambient sound), not Island Radio's playback stream
- Recognition is handled by the browser's built-in Web Speech API (typically Google's cloud API) — the app itself does no speech recognition
- The browser page is opened automatically by Island Radio; the user only needs to keep it open
- Multi-language support: en-US / zh-CN / ja-JP / ko-KR / fr-FR / de-DE — switches automatically with the station language

### Audio Routing — BlackHole Aggregate Device

The Web Speech API can only capture audio from **microphone input** and cannot directly access system audio output. To have STT recognize what the radio is playing (rather than room ambient sound), you need to loop system audio back to microphone input via **BlackHole + Aggregate Device**.

#### Why It's Needed

```
Without BlackHole:
  Radio audio → speakers → air → mic pickup → Speech API
  ❌ Poor quality, high latency, ambient noise interference

With BlackHole:
  Radio audio → BlackHole virtual device → Speech API
               ↘ Speakers (simultaneous) → User hears audio
  ✅ Pure digital loopback, lossless, zero latency
```

#### Setup Steps

1. **Install BlackHole** — download from [existential.audio/blackhole](https://existential.audio/blackhole/) (free, 2ch version is sufficient)

2. **Create Aggregate Device** — open Audio MIDI Setup:
   - Click `+` at the bottom left → "Create Aggregate Device"
   - Check both **BlackHole 2ch** and your **speakers/headphones**
   - Set the aggregate device as the default output

3. **Set browser mic input** — in the browser STT page or Chrome settings, select **BlackHole 2ch** or the aggregate device as microphone input

4. **Verify** — play a station, confirm speakers have audio and the STT page recognizes the station content

#### Audio Routing Diagram

```
┌──────────────┐
│  IslandRadio │ (AVPlayer decodes and plays)
│  Audio Out   │
└──────┬───────┘
       │ System audio stream
       ▼
┌──────────────────────────┐
│   Aggregate Device        │
│  ┌─────────┐ ┌─────────┐ │
│  │BlackHole│ │Speakers │ │  ← Both receive audio simultaneously
│  │  2ch    │ │/Headset │ │
│  └────┬────┘ └────┬────┘ │
└───────┼───────────┼──────┘
        │           │
        ▼           ▼
  Browser Mic     User Hears Audio
  (Speech API     (normal listening)
   recognition)
```

> **Tip**: If you only want to recognize your own speech (shadowing practice), no BlackHole setup is needed — just use your physical microphone. BlackHole is only required when you want to recognize the radio audio.

### Word Lookup — LLMService

Tap any word in the Island subtitle:

1. Playback pauses
2. Loading card appears
3. LLM API (OpenAI-compatible / Anthropic) is called for translation, returning: phonetic transcription, root analysis, syllable breakdown, definition, example sentence, full sentence translation, vocabulary level
4. Result card is displayed and the word is added to your vocabulary
5. Playback resumes automatically after dismissing the card

Translation results are cached locally (UserDefaults) — the same word + sentence context won't trigger a duplicate API call.

### Vocabulary — WordStore

- Learned words are highlighted in Island subtitles
- Spot which words you've already learned at a glance
- Mark words as "mastered"
- Data persisted to UserDefaults

### Dynamic Island — IslandCapsuleView

Uses macOS 14+ `NSPanel` to simulate the Dynamic Island effect:

- Always on top, transparent background, no title bar
- Shows current station, playback controls, recording status
- Real-time scrolling subtitles with learned-word highlighting
- Word lookup card pop-up animation

### Media Key Support

Registers system media keys (play/pause, next track) and keyboard shortcut `Cmd+Shift+M` to toggle recording.

## Building

### Requirements

- macOS 14.0+
- Xcode 15+ / Swift 5.9+
- No third-party dependencies

### Build the .app

```bash
cd IslandRadio
chmod +x run.sh
./run.sh build
```

`run.sh` performs: `swift build` → create `.app` bundle with Info.plist → copy binary and resources → codesign with entitlements

To build and run:

```bash
./run.sh run
```

## Project Structure

```
IslandRadio/
├── src/
│   ├── IslandRadioApp.swift          # Entry point, AppDelegate lifecycle
│   ├── Island/
│   │   ├── IslandWindow.swift        # NSPanel wrapper, Dynamic Island simulation
│   │   └── IslandCapsuleView.swift   # Island SwiftUI view
│   ├── Views/
│   │   └── MainContentView.swift     # Main window: stations, vocabulary, settings
│   ├── Services/
│   │   ├── AudioPlayer.swift         # AVPlayer audio + m3u8 parsing + health check
│   │   ├── STTBridgeServer.swift     # WebSocket server + embedded STT page
│   │   ├── LLMService.swift          # OpenAI/Anthropic translation API
│   │   └── Logger.swift              # Unified logging
│   ├── Models/
│   │   ├── RadioStation.swift        # Station model + language options
│   │   ├── StationStore.swift        # Station list persistence
│   │   └── WordStore.swift           # Vocabulary + translation cache
│   └── Resources/                    # App icon and other resources
├── Package.swift                      # SPM configuration
├── IslandRadio.entitlements           # Sandbox/network entitlements
└── run.sh                             # Build & run script
```

## Configuration

- **LLM API**: configure Provider / Endpoint / API Key / Model in the main window settings
- **STT Language**: each station can have a BCP-47 language code, automatically passed to the Speech API during playback
- **Station Management**: add, edit, and remove stations; supports AAC live streams and m3u8 streams

## Known Limitations

- STT relies on the browser's Web Speech API — a browser tab must remain open
- The Web Speech API only captures microphone input by default; recognizing radio audio requires BlackHole aggregate device setup (see Audio Routing section above)
- Ad-hoc signed, not notarized — you may need to allow the app in System Settings on first launch
- macOS 14+ only

## License

MIT
