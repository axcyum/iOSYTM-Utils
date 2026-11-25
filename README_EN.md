<div align="center">

<img src="assets/icon.png" width="124" height="124" alt="iOSYTM-Utils Icon" />

# iOS YTMusic Utilities

**All-in-one synced lyrics, immersive player & utility suite for YouTube Music on iOS**

[![Build](https://img.shields.io/github/actions/workflow/status/axcyum/iOSYTM-Utils/build.yml?branch=main&style=flat-square&label=Build&color=FF2D55)](https://github.com/axcyum/iOSYTM-Utils/actions/workflows/build.yml)
![Platform](https://img.shields.io/badge/Platform-iOS%2018%2B-1C1C1E?style=flat-square&logo=apple&logoColor=white)
![Injection](https://img.shields.io/badge/Works%20With-Sideload%20%C2%B7%20LiveContainer%20%C2%B7%20Jailbreak-2C2C2E?style=flat-square)
[![License](https://img.shields.io/badge/License-GPL--3.0-FF3B30?style=flat-square)](LICENSE)

[日本語](README.md) · **English**

[Features](#features) · [Lyrics Providers](#lyrics-providers) · [Installation](#installation) · [Building](#building) · [License](#license)

</div>

---

## Overview

**iOSYTM-Utils** (`ivLyricsYTM.dylib`) brings **[ivLyrics](https://github.com/ivLis-Studio/ivLyrics)** (originally built for Spicetify) to YouTube Music on iOS with a touch-first UI redesigned from the ground up for effortless one-handed use.

It also unifies several companion tweaks and utilities under a single native settings sheet:

- **[LockLyrics](https://github.com/axcyum/LockLyrics)** — Live synced lyrics rendered directly on the iOS Lock Screen & Control Center artwork
- **[YTMusic-iOS-Presence](https://github.com/axcyum/YTMusic-iOS-Presence)** — Official SDK-powered Discord Rich Presence
- **[SimpMusic](https://github.com/maxrave-dev/SimpMusic)-inspired Utilities** — Apple Music-style immersive Now Playing sheet, scrobbling, ShazamKit song recognition, listening stats & WebNowPlaying LAN sync

> [!IMPORTANT]
> **Clean Policy**: This tweak focuses strictly on lyrics, playback UX, and ecosystem integrations. **It contains zero ad-blocking, Premium-unlocking, audio-downloading, or restriction-bypassing code.**
> Only playback-state and metadata hooks are used.

---

## Features

### 1. Full-Screen Synced Lyrics & Karaoke
- **Word-by-Word Karaoke Fill**: Smooth character/syllable progress powered by TTML (Unison) and enhanced LRC timestamps, complete with animated instrumental breaks (`• • •`) and right-aligned secondary vocals for duets.
- **Thumb-Friendly Mobile Gestures**:
  - **Tap** any line to seek, **pinch** to resize lyrics on the fly, or **swipe down** from the header to dismiss.
  - **Long-press** any lyric line to seek, sync timing to that line, copy text, or **share a stylized lyric image card**.
  - Reachable bottom toolbar for **Translation · Pronunciation · Font Size · Per-Song Sync Offset (`±0.1s` / `±0.5s`) · Settings**.
- **Draggable Mini-Lyric Pill**: A floating button on YouTube Music's Now Playing screen that remembers its position and can display the current lyric line live (tap to open lyrics, long-press for settings).

### 2. Translation & 100% On-Device Pronunciation
- **Zero-Key Translation**: Instant multi-language lyric translation via Google Translate's web endpoint — no API keys required.
- **Offline Pronunciation Engine**: Generated entirely on-device (`CFStringTokenizer` / ICU) with zero network traffic:
  - **Japanese**: Furigana (hiragana readings) or Romaji
  - **Korean**: Revised Romanization
  - **Chinese**: Tone-marked Pinyin
  - **Other Non-Latin Scripts**: Cyrillic, Thai, and more transliterated to Latin script
- **Localized UI**: English / 日本語 / 한국어.

### 3. Internal Player Sheet & Lock Screen Lyrics
- **Now Playing Sheet**: Tap the header artwork in the lyrics view (or set it as default) to switch to a sleek internal player with knobless 6pt capsule scrubber & volume bars that swell on touch, spring-animated frameless transport controls, and AirPlay / queue / sleep-timer badges.
  - **Standard Mode (Default)**: Displays clean framed `1:1` song covers or `16:9` video thumbnails over a blurred ambient color mesh.
  - **Apple Music Full-Bleed Style (Experimental)**: Optional setting that extends artwork behind the status bar and dissolves it optically through progressive Gaussian blur into the background mesh.
- **Lock Screen & Control Center Lyrics** (LockLyrics integrated):
  - Renders live synced lyrics (plus pronunciation/translation) onto the Lock Screen artwork canvas.
  - Upgraded with smooth slide + fade transitions, word-level karaoke fill, and configurable latency lead-time compensation.
- **Custom Themes**: Choose between Artwork Blur, Dynamic Color Mesh, Solid Color, or Pure OLED Black backgrounds, with custom Hex accent & solid colors.

### 4. Ecosystem Integrations & Extras
- **Discord Rich Presence** (YTMusic-iOS-Presence integrated): Displays track title, artist, remaining time, cover art, and optional "Listen on YouTube Music" / GitHub buttons. Supports custom activity names and update intervals (`3–60s`). Uses runtime `dlopen` stubs so **no framework injection is required — works out of the box in LiveContainer**.
- **WebNowPlaying (LAN)**: Streams live track metadata, artwork, and progress over LAN to PC adapters such as [WebNowPlaying-Rainmeter](https://github.com/keifufu/WebNowPlaying-Rainmeter) (revisions legacy / 1 / 2 / 3), with optional remote play/pause/skip/seek control from your PC.
- **Scrobbling**: **Last.fm** and **ListenBrainz** support with Keychain-stored credentials and a persistent offline retry queue.
- **Ambient Song Recognition**: Identify music playing around you via Apple's **ShazamKit** and open matches directly inside YouTube Music.
- **Listening Stats & Sleep Timer**: Private on-device listening analytics (7d / 30d / All-Time, hourly clock, top tracks & artists) and a sleep timer (custom minutes or end-of-track).

---

## Lyrics Providers

All enabled sources are queried in parallel and ranked automatically by **Word-Synced > Line-Synced > Plain Text**, breaking ties using your drag-and-drop provider order. You can also pin a specific provider per song.

| Provider | Sync Level | Notes |
| :--- | :---: | :--- |
| **YouTube Music** | Line-Synced | Official app lyrics fetched with timestamps via mobile InnerTube |
| **Unison** | Word-Synced | Rich TTML karaoke fill, instrumental breaks & duet vocal alignment |
| **LyricsPlus** | Word / Line | High-accuracy Apple Music / Musixmatch-sourced synced lyrics |
| **Lyrically** | Word / Line | Backed by Apple Music catalog & KuGou sources |
| **Spotify** | Line-Synced | Sign in to `open.spotify.com` in settings (credentials stay in local WebKit) |
| **LRCLIB** | Enhanced / Line | Includes manual keyword search, long-press preview & per-song pinning |
| **Video Subtitles** | Line-Synced | Uses official MV caption tracks (auto language match & track picker; skips auto-captions) |

---

## Installation

By default, `ivLyricsYTM.dylib` uses Logos's `internal` Objective-C runtime generator — **no CydiaSubstrate or ElleKit dependency**, making it ready for sideloaded IPAs and LiveContainer.

### LiveContainer
1. Open the `Tweaks` folder of your YouTube Music container.
2. Drop in `ivLyricsYTM.dylib` (and `discord_partner_sdk.dylib` if you want Discord Rich Presence).

### IPA Injection (cyan / Feather / ESign / Sideloadly)
1. Prepare a decrypted YouTube Music IPA.
2. Inject `ivLyricsYTM.dylib` (plus `discord_partner_sdk.dylib` if desired), sign, and install:

```bash
cyan -i YouTubeMusic.ipa -o YouTubeMusic_Utils.ipa -uwsf ivLyricsYTM.dylib discord_partner_sdk.dylib
```

- **Automated IPA via GitHub Actions**: Trigger `Build ivLyricsYTM` manually (`workflow_dispatch`) and pass a decrypted `ipa_url` to produce a ready-to-sign injected IPA in Artifacts.

### Jailbreak (`.deb`)
Rootful, Rootless, and Roothide `.deb` packages are supported and built automatically in CI.

> [!WARNING]
> **Do Not Double-Inject**: `LockLyrics` and `YTMusic-iOS-Presence` are already built into `ivLyricsYTM.dylib`. Remove standalone copies of those tweaks to avoid duplicate Lock Screen overlays or Discord updates.

---

## Building

Requires macOS, [Theos](https://theos.dev), and Xcode with the iOS 18+ SDK.

```bash
# Default: standalone Substrate-free dylib (.theos/obj/ivLyricsYTM.dylib)
make package

# Jailbreak .deb packages
make package JAILBREAK=1             # Rootful
make package JAILBREAK=1 ROOTLESS=1  # Rootless
make package JAILBREAK=1 ROOTHIDE=1  # Roothide

# Enable Discord Rich Presence (point to the ios-arm64 slice of the official Discord Social SDK)
make package DISCORD_SDK=/path/to/discord_partner_sdk.xcframework/ios-arm64
```

<details>
<summary><b>WebNowPlaying PC Port-Forwarding Setup (Rainmeter)</b></summary>
<br>

If your PC adapter only listens on `127.0.0.1` (default port `8974` for Rainmeter), expose it to your LAN in an elevated PowerShell / Command Prompt and allow TCP port `8974` in Windows Firewall:

```powershell
netsh interface portproxy add v4tov4 listenport=8974 listenaddress=0.0.0.0 connectport=8974 connectaddress=127.0.0.1
```

</details>

---

## License

Distributed under the **[GPL-3.0](LICENSE)** license.

- Includes code from `YTMusic-iOS-Presence` (GPL-3.0); `ivLyrics`-derived components (originally LGPL-2.1, see [LICENSE.ivLyrics-LGPL-2.1](LICENSE.ivLyrics-LGPL-2.1)) are conveyed under GPL-3.0 pursuant to LGPL-2.1 Section 3.
- The official Discord Social SDK is governed by Discord's own license and is not redistributed in source form in this repository.

### Credits
**[ivLyrics](https://github.com/ivLis-Studio/ivLyrics)** © ivLis STUDIO · **LyricsPlus** · **Unison** · **Lyrically (Paxsenix)** · **[LRCLIB](https://lrclib.net/)** · **[SimpMusic](https://github.com/maxrave-dev/SimpMusic)** · **[WebNowPlaying](https://github.com/keifufu/WebNowPlaying)** · **[YTMusicUltimate](https://github.com/dayanch96/YTMusicUltimate)**

<details>
<summary><sub>...</sub></summary>

<sub>Building <code>discord_partner_sdk.dylib</code> from the official Discord Social SDK (<code>ios-arm64</code> slice):</sub>

```bash
cp path/to/discord_partner_sdk.xcframework/ios-arm64/discord_partner_sdk.framework/discord_partner_sdk discord_partner_sdk.dylib
for lib in $(otool -L discord_partner_sdk.dylib | awk '/@rpath\/libswift/ {print $1}'); do
  install_name_tool -change "$lib" "/usr/lib/swift/${lib#@rpath/}" discord_partner_sdk.dylib
done
install_name_tool -id @rpath/discord_partner_sdk.dylib discord_partner_sdk.dylib
ldid -S discord_partner_sdk.dylib
```

<sub>Alternatively, upload the official SDK as <code>discord-sdk.zip</code> to a pre-release tagged <code>build-inputs</code> in your fork and run the <code>Build ivLyricsYTM</code> workflow.</sub>

</details>
