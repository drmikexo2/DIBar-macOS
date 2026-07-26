# DIBar

**A native macOS menu bar app for [DI.FM](https://di.fm) and the whole AudioAddict radio family**: JazzRadio, RadioTunes, ClassicalRadio, RockRadio, and ZenRadio. Built entirely in Swift. No Electron, no Chromium, no web views. It sits quietly in your menu bar using virtually zero CPU when idle and a few MB of RAM.

<img width="352" height="498" alt="image" src="https://github.com/user-attachments/assets/4dc191c8-cb75-4be8-9adc-f68821eca365" /><br>
<img width="485" height="455" alt="image" src="https://github.com/user-attachments/assets/fba18cf4-4e8e-4660-ae8b-01be692b962e" /><br>
<img width="357" height="294" alt="image" src="https://github.com/user-attachments/assets/4151fc93-856f-4134-a8da-7940f0bd196e" />


## Features

### Listen

- **Six radio sites, one app**: switch between DI.FM, JazzRadio, RadioTunes, ClassicalRadio, RockRadio, and ZenRadio. One premium account covers them all.
- **All Sites view**: merge every network into a single list and search hundreds of channels at once. Each row shows which site it belongs to.
- **Instant search** with full keyboard control: type to filter, arrows and Return to play.
- **Favorites**: star channels right in the app, synced with your DI.FM account, pinned to the top of the list. Works across sites in the All Sites view.
- **Recently played**: the last channels you played across all sites, one click to jump back.
- **Like / dislike songs**: vote on the current track with instant feedback. Votes count on DI.FM like the website's buttons.
- **Now playing**: album art, artist, title, elapsed time, duration, and community votes. Click the art to expand it.
- **Song actions**: copy artist and title, or search the current song on Spotify, Apple Music, and YouTube.
- **Stream quality selection**: 320k MP3, 128k AAC, or 64k AAC.
- **Self-healing streams**: network drops, stalls, and sleep/wake trigger an automatic reconnect with visible Buffering and Reconnecting states.
- **Remembers your channel**: resumes the last channel per site on launch.

### Control it from anywhere

- **Global shortcuts** that work in any app: play/pause, previous/next favorite channel, previous/next site.
- **Media keys**: play/pause, and the seek keys step through your favorites. Integrates with macOS Now Playing.
- **Switch notifications**: changing channels from the keyboard pops a banner with the site, channel, and current song. A separate opt-in banner announces every track change, artwork included.
- **Sleep timer**: 15, 30, 60, or 90 minutes, or type your own, with a live countdown. Optionally quits the app instead of just pausing.
- **Output device picker**: play through any audio device, AirPlay included, independent of the system default. The route survives reconnects.
- **Mute button** with an unmissable muted state in both the player and the menu bar.

### Scrobbling

- **Last.fm**: DIBar scrobbles what you actually heard, at least half the song or four minutes of it, with ads and jingles filtered out. Scrobbles queue locally through offline stretches and send when you are back.
- Anything that reads Last.fm, like Airbuds, picks up your radio listening automatically.

### Your listening, remembered (locally)

- **Listening history**: every song you hear is saved to a local SQLite database on your Mac. Nothing is sent anywhere. Browse it in the History window with Listened, Liked, and Disliked tabs, album art on every row.
- **Listening stats**: today and all-time totals, with liked songs highlighted.
- **stats.fm export**: export your history as a Spotify-format endsong.json for import into stats.fm.
- Optional: one checkbox turns history off.

### Menu bar, your way

- **Configurable menu bar text**: show any combination of play state, site, channel, artist, and song next to the icon, up to two compact lines, with a live preview in Settings.
- **Icon-only mode** for minimalists (the default).
- **Launch at login**, membership status and signed-in account at a glance, clear error messages when a stream misbehaves.

## Why native?

| | DIBar | Typical Electron app |
|---|---|---|
| **App size** | ~2 MB | 150-300 MB |
| **RAM at idle** | ~15 MB | 200-500 MB |
| **CPU at idle** | 0% | 0.5-2% |
| **Startup** | Instant | 2-5 seconds |

DIBar uses `AVPlayer` for audio, `MPRemoteCommandCenter` for media keys, a hand-managed `NSStatusItem` with a SwiftUI panel for the interface, and the system SQLite for history. No runtime overhead from bundled browsers, and zero third-party dependencies.

## Requirements

- macOS 14.0 (Sonoma) or later
- A [DI.FM](https://di.fm) premium membership for high-quality streaming (works across all six sites)

## Download

- Latest release: <https://github.com/drmikexo2/DIBar-macOS/releases/latest>

Releases are Developer ID signed and notarized by Apple, so there are no Gatekeeper hoops. Unzip, drag `DIBar.app` to Applications, and launch.

## Build From Source

```bash
git clone https://github.com/drmikexo2/DIBar-macOS.git
cd DIBar-macOS
cp DIBar/Services/Secrets.swift.example DIBar/Services/Secrets.swift
xcodebuild -project DIBar.xcodeproj -scheme DIBar -configuration Release build
```

Last.fm scrobbling needs your own API key and secret in `Secrets.swift`; everything else works without it.

## Privacy

Your DI.FM login is exchanged only with DI.FM's own API. Listening history and song votes are stored in a local database on your Mac and never leave it. Scrobbling is off until you connect an account.
