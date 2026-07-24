# DIBar

**A native macOS menu bar app for [DI.FM](https://di.fm) and the whole AudioAddict radio family** — JazzRadio, RadioTunes, ClassicalRadio, RockRadio, and ZenRadio. Built entirely in Swift — no Electron, no Chromium, no web views. Sits quietly in your menu bar using virtually zero CPU when idle and just a few MB of RAM.

<img width="352" height="498" alt="image" src="https://github.com/user-attachments/assets/4dc191c8-cb75-4be8-9adc-f68821eca365" /><br>
<img width="485" height="457" alt="image" src="https://github.com/user-attachments/assets/59f9a6c7-4ee8-4889-865b-058ac8e97305" /><br>
<img width="362" height="295" alt="image" src="https://github.com/user-attachments/assets/e7f1d36f-fdc1-4ca4-beac-f26cc5707e12" /><br>



## Features

### Listen
- **Six radio sites, one app** — switch between DI.FM, JazzRadio, RadioTunes, ClassicalRadio, RockRadio, and ZenRadio; one premium account covers them all
- **Hundreds of channels** with instant station search
- **Favorites** — star stations right in the app, synced with your DI.FM account; favorites pin to the top of the list
- **Like / dislike songs** — vote on the current track (counts on DI.FM like the website's buttons) with instant feedback
- **Stream quality selection** — 320k MP3, 128k AAC, or 64k AAC
- **Now playing** — album art, artist, track title, elapsed time, duration, and community votes; click the art to expand it
- **Remembers your station** — resumes your last channel per site on launch

### Your listening, remembered (locally)
- **Listening history** — every song you hear is saved to a local SQLite database on your Mac (nothing is sent anywhere); browse it in the History window with Listened / Liked / Disliked tabs
- **Listening stats** — today and all-time totals, with liked songs highlighted in your history
- Optional — one checkbox turns it off

### Menu bar, your way
- **Configurable menu bar text** — show any combination of play/pause state, site, station, artist, and song title next to the icon, with a live preview in Settings; up to two compact lines
- **Icon-only mode** for minimalists (the default)

### Desk-worthy details
- **Media key support** — play/pause from your keyboard; integrates with macOS Now Playing
- **Keyboard control** — type to search, arrow keys + Return to pick a station, Space to play/pause, Esc to clear
- **Launch at login**, membership status at a glance, clear error messages when a stream misbehaves

## Why native?

| | DIBar | Typical Electron app |
|---|---|---|
| **App size** | ~2 MB | 150–300 MB |
| **RAM at idle** | ~15 MB | 200–500 MB |
| **CPU at idle** | 0% | 0.5–2% |
| **Startup** | Instant | 2–5 seconds |

DIBar uses `AVPlayer` for audio, `MPRemoteCommandCenter` for media keys, a hand-managed `NSStatusItem` with a SwiftUI panel for the interface, and the system SQLite for history. No runtime overhead from bundled browsers — and zero third-party dependencies.

## Requirements

- macOS 14.0 (Sonoma) or later
- A [DI.FM](https://di.fm) premium membership for high-quality streaming (works across all six sites)

## Download

- Latest release: <https://github.com/drmikexo2/DIBar-macOS/releases/latest>

Releases are Developer ID signed and notarized by Apple — no Gatekeeper hoops. Unzip, drag `DIBar.app` to Applications, and launch.

## Build From Source

```bash
git clone https://github.com/drmikexo2/DIBar-macOS.git
cd DIBar-macOS
xcodebuild -project DIBar.xcodeproj -scheme DIBar -configuration Release build
```

## Privacy

Your DI.FM login is exchanged only with DI.FM's own API. Listening history and song votes are stored in a local database on your Mac and never leave it.
