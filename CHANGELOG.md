# Changelog

## 1.4.0

### Automatic updates

- DIBar now checks for signed updates automatically and can download, install, and relaunch new versions in place.
- Scheduled checks stay out of the way: an available update appears as a small menu bar badge and an Update action inside DIBar instead of interrupting the current app.
- Settings now shows the installed version and build date, with a button to check for updates immediately.

### Release safety

- Releases are notarized, stapled, verified, and published with a signed Sparkle appcast.
- The release workflow now validates credentials and release notes up front, verifies the uploaded artifact, and can recover safely from partial failures.

## 1.3.2

### Memory

- Bounded the artwork cache by decoded image size instead of compressed download size, capped it at 16 MiB and 48 images, and stopped retaining duplicate URL-cache responses.
- The hidden menu panel now releases its SwiftUI view graph, elapsed-time timeline, and playback observations instead of retaining them for the life of the app.
- Isolated the speaker animation from the application model and kept all three symbol layers structurally stable, preventing long-running SwiftUI allocation growth while the panel is open.

### macOS integration

- On macOS 26, channel search no longer launches an unnecessary Security Code AutoFill helper. Login credential AutoFill remains available when the sign-in screen is actually shown.

## 1.3.1

### Performance

- Fixed DIBar consuming roughly 25–35% CPU while playing because the animated speaker kept SwiftUI rendering continuously, even with the menu panel closed.
- Replaced the display-rate SF Symbol effect with one lightweight shared animation clock that runs only while the panel is visible and audio is audible.
- The speaker now advances outward at half a cycle per second, keeps its body and waves anchored in place, and stays static when Reduce Motion is enabled.

### Navigation

- Command-L now switches to the playing channel's site when needed, then reveals and centers that channel after its catalog loads.

## 1.3

### Faster windows

- Settings and Listening History now appear immediately from the menu bar instead of sometimes waiting several seconds for app activation.
- The launch-at-login status and registration work now run away from the main thread, so macOS service lookups cannot stall the Settings window.

### Navigation and playback

- Recently Played rows now include favorite controls and stay synchronized with each site's server-side favorites.
- Command-L jumps to the currently playing channel and expands All Channels when needed.
- The playing indicator and accent colors are clearer, including a more polished speaker animation.
- Fixed the elapsed counter getting stuck at 0:00 when stream metadata advances before the DI.FM API catches up.

## 1.2

### All Sites

- The site picker has a new All Sites entry that merges all six networks into one list: your favorites from every site together, every channel together, and one search across the lot.
- Rows in the merged view are labeled with their site, and playing one does not bounce you out of it. The picker keeps saying All Sites while the playing site's row shows the speaker.
- All Sites sticks across relaunches. Picking any single site returns to the normal per-site view.

### Channel list

- Sites in the picker are sorted alphabetically.
- Section headers now say what they cover: My DI.FM Favorites, All DI.FM Channels with a count, and My Recently Played Channels. In All Sites view they read My Favorites and All Channels.
- Fixed pinned section headers drawing a lighter, mismatched stripe while scrolling, most visible with the desktop behind the panel.
- DI.FM channels in mixed lists are labeled DI.FM instead of DI.

### Settings

- The account row shows which DI.FM account you are signed in with.
- Buttons say Log Out instead of Logout.

### Under the hood

- Idle cost is way down: the menu bar label redraws when something changes instead of every second, track polling stops while paused, and the housekeeping timers coalesce their wakeups.
- Pausing for more than a minute releases the stream instead of holding the connection open. Resuming rejoins the live broadcast.
- Album artwork is fetched once and kept in a shared cache.
- The raw login response is no longer written to the system log.
- New unit tests cover the channel list merging, metadata matching, and history logic.

## 1.1

Drive it without opening it: global shortcuts, media keys, Last.fm scrobbling, sleep timer, output device selection, stream self-recovery, and a Recently Played section. Full notes: <https://github.com/drmikexo2/DIBar-macOS/releases/tag/v1.1>

## 1.0

Every AudioAddict site, listening history, and a redesigned player. Full notes: <https://github.com/drmikexo2/DIBar-macOS/releases/tag/v1.0>
