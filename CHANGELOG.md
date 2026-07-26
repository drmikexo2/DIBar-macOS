# Changelog

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
