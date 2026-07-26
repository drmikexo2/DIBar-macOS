# On-Demand Playback & Track Skipping — Implementation Reference

> Everything needed to add DI.FM-style **track skipping** to DIBar, reverse-engineered
> from the live AudioAddict API and the official di.fm web player on **2026-07-24**.
> Written so a future implementation needs **no packet sniffing** — every endpoint,
> auth requirement, payload, and response shape is documented below.

---

## 1. The core insight: two different playback models

DIBar today plays the **linear broadcast**. Skipping requires the **on-demand** model.
They are completely separate playback paths — skip is *not* a toggle on the current player.

| | **Linear (what DIBar does now)** | **On-demand (what skip needs)** |
|---|---|---|
| Source | `listen.di.fm/{quality}/{key}.pls` | `content.audioaddict.com/…/{hash}.mp3` |
| Nature | One shared Icecast/Shoutcast feed, synchronized for *all* listeners | Per-track discrete MP3 files, private to the member |
| Position | No per-user position — you join wherever the broadcast is | Each track plays from `0:00`; seekable (HTTP `206 Partial Content`) |
| Skip | **Physically impossible** (would skip for everyone) | Advance a local queue to the next track |
| Code today | `DIClient.streamURL(...)`, `AudioPlayer` | *does not exist yet* |

Because the on-demand feed hands you individual, seekable song files, "skip" simply means
**stop the current file and start the next track's file**. That's the whole trick.

---

## 2. Authentication — what you need and what you DON'T

### 2.1 Credentials DIBar already has (sufficient!)

The signed, playable per-track URLs come back using **only the credentials DIBar already
stores**. No new login, no extra token, no browser session is required.

- **Shared app basic-auth header** (already in `DIClient.swift`):
  `Authorization: Basic ZXBoZW1lcm9uOmRheWVpcGgwbmVAcHA=`
- **Member `api_key`** (already stored in `Prefs` under `com.dibar.api_key`, held on
  `AppState.apiKey`). Passed as the `?api_key=` query param.

That's it. Verified live via plain `curl` — no cookies, no session key — returning fully
signed `.mp3` URLs for premium_high (320k) audio across multiple channels.

### 2.2 The `X-Session-Key` red herring (NOT needed)

The web player authenticates its API calls with an `X-Session-Key` header — a **third**
32-hex-char token, distinct from both `api_key` and `listen_key`, minted by the web login
(`audio_addict_session` cookie). **You do not need it.** Investigation confirmed the
`api_key` path yields the same signed content URLs. Do not spend time trying to mint an
`X-Session-Key`.

### 2.3 One caveat to re-verify before shipping

On the very first `routines` fetch of the session (before any playback had been started),
one channel returned tracks **without** the `content` field. After a streaming session was
active, *every* channel returned signed `content.assets`. This *might* mean signed-asset
generation depends on premium/active-session state on the server side.

**Action before relying on this:** do a truly-cold test — fresh app launch, fetch a routine
for a channel you have not played, and confirm `content.assets[].url` is present. The
independent `curl` evidence strongly suggests `api_key` alone is sufficient, but this edge
deserves one confirmation.

---

## 3. The endpoints (complete reference)

Base URL: `https://api.audioaddict.com/v1/{network}` (e.g. `.../v1/di`).
`{network}` = the AudioAddict slug already modeled in `Network.apiSlug` / `Network.apiBaseURL`.
All calls carry the `Authorization: Basic …` header.

### 3.1 Get the queue + signed audio — `GET /routines/channel/{channelId}`

**This is the one endpoint that unlocks everything.** It returns the channel's programmed
playout (the "routine") as an ordered list of tracks, each with a **pre-signed, playable
MP3 URL**.

```
GET https://api.audioaddict.com/v1/di/routines/channel/{channelId}?api_key={apiKey}
Authorization: Basic ZXBoZW1lcm9uOmRheWVpcGgwbmVAcHA=
```

Response (trimmed to the fields that matter):

```jsonc
{
  "routine_id": 10,
  "expires_on": "2026-07-25T11:30:27-04:00",   // whole routine expires; re-fetch after this
  "tracks": [
    {
      "id": 1053783,
      "length": 451,                            // seconds — drives the progress bar
      "display_title": "Te Amo (Amir Hussain Remix)",
      "display_artist": "Bryan Kearney",
      "track": "Bryan Kearney - Te Amo (amir hussain remix)",
      "content_accessibility": 1,               // 1 = premium-playable
      "track_container_id": 190385,
      "isrc": "GBKQU1573134",
      "asset_url": "//cdn-images.audioaddict.com/…jpg",   // album art
      "waveform_url": "//waveform.audioaddict.com/…json", // optional scrubber waveform
      "votes": { "up": 441, "down": 35 },
      "content": {
        "interactive": false,
        "length": 327.0,
        "offset": null,
        "assets": [
          {
            "content_format_id": 1,
            "content_quality_id": 6,            // 6 = premium_high (320k MP3)
            "size": 13268971,
            "url": "//content.audioaddict.com/prd/2/7/a/c/4/7892…07e.mp3?purpose=playback&audio_token=<TOKEN>&member_id=14002006&network=di&device=other_other&ip=<IP>&ip_type=4&country_code=<CC>&channel_id=12&routine_id=10&exp=2026-07-25T15%3A52%3A58Z&auth=<SIG>"
          }
        ]
      }
    }
    // … typically 5 tracks per routine fetch
  ]
}
```

Key points:
- **`tracks[].content.assets[0].url`** is the playable file. Prepend `https:` (it comes
  protocol-relative). Serve it straight to `AVPlayer` — it supports HTTP range requests, so
  it's seekable.
- The URL is **self-authenticating** via the `audio_token` + `auth` query params. No extra
  header is needed when fetching the MP3 itself from `content.audioaddict.com`.
- **`exp`** on the URL (~24h out) and **`expires_on`** on the routine both bound validity.
  Re-fetch the routine when either passes.
- A single fetch returns ~5 tracks. When the local queue runs low, fetch the routine again
  for more (it advances server-side).
- `content_quality_id` maps to DIBar's existing `StreamQuality` (6 = premium_high). If DI
  exposes other qualities in `assets[]`, pick by `content_quality_id`.

### 3.2 Record a skip — `POST /skip_events`

Call this **when the user skips**. It enforces the skip quota and returns how many remain.

```
POST https://api.audioaddict.com/v1/di/skip_events?api_key={apiKey}
Authorization: Basic …
Content-Type: application/json
```

Request body (as sent by the web player):

```jsonc
{
  "track_id": 3109861,
  "skipped_at": 30,          // seconds into the track when skipped
  "playlist_id": null,
  "event_id": null,
  "channel_id": 12,
  "length": 199,             // track length in seconds
  "created_at": "Fri Jul 24 2026 09:48:54 GMT-0600",
  "skips_remaining": null,   // client sends null; server fills it in the response
  "expires": null
}
```

Response (`201 Created`):

```jsonc
{ "skips_remaining": 10, "expires_at": "2026-07-24T12:24:03-04:00" }
```

- **Skips are quota-limited even on premium.** `skips_remaining` is a rolling window that
  resets at `expires_at`. When it hits 0, disable the skip button until `expires_at`.
- Surfacing "N skips left" in the UI would match the official app's behavior.

### 3.3 Log the now-playing track — `POST /listen_history`

Call this **each time a new track starts** (including after a skip). Records the play for
history/recommendations. Fire-and-forget.

```
POST https://api.audioaddict.com/v1/di/listen_history?api_key={apiKey}
Content-Type: application/json

{ "track_id": 3044651, "channel_id": 12 }
```

Response: `201 Created`, empty body.

> Note: this is the official client's play-logging channel. It overlaps conceptually with
> DIBar's own scrobbler/history recorder — decide whether to also post here or keep DIBar's
> logging independent.

### 3.4 Optional — `POST /streaming/{audio_token}`

The web player also posts to `/v1/di/streaming/{audio_token}` (the `audio_token` from the
current track's URL) as a stream-start report. **Not required for playback or skipping** —
document-only. Skip it in v1.

### 3.5 Optional — `GET /currently_playing`

The web player polls `GET /v1/di/currently_playing` for the now-playing widget. In the
on-demand model DIBar already knows what's playing (it controls the queue), so this is
**not needed**. DIBar's existing `DIClient.fetchCurrentTrack` (`track_history/channel/{id}`)
is the linear-mode equivalent and stays as-is for linear playback.

---

## 4. The runtime flow

```
User taps a channel in on-demand mode
completed  │
           ▼
   GET /routines/channel/{id}?api_key=…          → tracks[] with signed content.assets
           │
           ▼
   Build a local queue from tracks[]
           │
           ▼
   Play queue[0].content.assets[0].url via AVPlayer   (plays from 0:00, seekable)
           │
           ├─ on track start ──► POST /listen_history {track_id, channel_id}
           │
           ├─ user taps SKIP ──► POST /skip_events {track_id, skipped_at, channel_id, length,…}
           │                     │
           │                     ├─ 201 + skips_remaining>0 → advance queue, play next
           │                     └─ skips_remaining==0      → disable skip until expires_at
           │
           ├─ track ends naturally ─► advance queue, play next (no skip_event)
           │
           └─ queue nearly empty OR routine expired ─► GET /routines again, append
```

---

## 5. Implementation outline (DIBar-specific)

The goal is a **parallel** on-demand path that reuses DIBar's models and auth, without
touching the working linear player.

### 5.1 New models (`Models/`)

```swift
struct Routine: Decodable {
    let routineId: Int
    let expiresOn: Date          // decode ISO8601; re-fetch after this
    let tracks: [RoutineTrack]
}

struct RoutineTrack: Decodable {
    let id: Int
    let length: Double           // seconds
    let displayTitle: String
    let displayArtist: String
    let contentAccessibility: Int
    let assetURL: String?        // album art
    let content: TrackContent?
}

struct TrackContent: Decodable {
    let assets: [ContentAsset]
}

struct ContentAsset: Decodable {
    let url: String              // protocol-relative; prepend "https:"
    let contentQualityId: Int    // 6 = premium_high
    let size: Int
}
```

Use `convertFromSnakeCase` (or explicit `CodingKeys`) — the API is snake_case throughout.

### 5.2 `DIClient` additions (`Services/DIClient.swift`)

Mirror the existing style (static funcs, shared `basicAuth`, `urlEncode`):

```swift
static func fetchRoutine(channelId: Int, apiKey: String, network: Network) async throws -> Routine
static func postSkipEvent(trackId: Int, channelId: Int, skippedAt: Int, length: Int,
                          apiKey: String, network: Network) async throws -> SkipResult   // {skipsRemaining, expiresAt}
static func postListenHistory(trackId: Int, channelId: Int, apiKey: String, network: Network) async throws
```

- Reuse the `Authorization: Basic` header pattern already in `favoritesData` / `voteRequest`.
- `postSkipEvent` returns the `{skips_remaining, expires_at}` payload so the UI can gate skips.
- Build the `created_at` string in the same format the web player uses, or send `null` if
  the server tolerates it (verify).

### 5.3 New player: `OnDemandPlayer` (`Services/`)

A sibling to `AudioPlayer`, not a modification of it:

- Owns an `AVPlayer` (or `AVQueuePlayer`) and a `[RoutineTrack]` queue + index.
- `start(channel:)` → fetch routine → load queue → play index 0.
- `skip()` → guard `skipsRemaining > 0` → `postSkipEvent` → advance index → play next →
  `postListenHistory`.
- On `AVPlayerItemDidPlayToEndTime` → advance index (no skip event) → play next →
  `postListenHistory`.
- Prefetch: when `index >= queue.count - 2`, fetch the routine again and append.
- Refresh: if a track's URL `exp` or the routine `expiresOn` has passed, re-fetch before play.
- **Now Playing / media keys:** reuse the existing `MPNowPlayingInfoCenter` +
  `MPRemoteCommandCenter` wiring in `AudioPlayer.swift:410-436`. In on-demand mode,
  **enable** `nextTrackCommand` (currently disabled at `AudioPlayer.swift:434`) and route it
  to `skip()`. This makes the F8-adjacent "next" media key skip tracks. Also set
  `MPNowPlayingInfoPropertyIsLiveStream = false` and publish `MPMediaItemPropertyPlaybackDuration`
  + `MPNowPlayingInfoPropertyElapsedPlaybackTime` so the OS shows a real scrubber.

### 5.4 State & UI (`State/AppState.swift`, `Views/`)

- Add a mode flag (linear vs on-demand). On-demand is premium-only.
- Show a **Skip** button and, optionally, "N skips left" from `skipsRemaining`.
- Disable Skip when `skipsRemaining == 0`, re-enable at `expiresAt`.
- On-demand gives a real position/duration → wire a working progress/seek bar
  (linear mode can't do this).

### 5.5 Suggested build order

1. Models + `DIClient.fetchRoutine`; log a decoded routine and confirm signed URLs appear
   from a **cold** launch (settles the §2.3 caveat).
2. Play a single track's `content.assets[0].url` through `AVPlayer` end-to-end.
3. Queue + auto-advance on track-end + `postListenHistory`.
4. `skip()` + `postSkipEvent` + quota gating.
5. Now Playing / media-key `nextTrackCommand` → `skip()`.
6. UI: mode toggle, Skip button, skips-remaining, progress/seek bar.
7. Prefetch + expiry refresh.

---

## 6. Quick reference — verified facts

- Auth for signed URLs: **`Basic …` + `api_key`** (DIBar already has both). No `X-Session-Key`.
- Playable file: `tracks[].content.assets[].url` (prepend `https:`), 320k MP3, seekable (206).
- Skip = `POST /skip_events` (returns `skips_remaining`/`expires_at`) + advance queue +
  `POST /listen_history`.
- Skips are **quota-limited on premium** (rolling window).
- URLs expire ~24h (`exp`); routine expires at `expires_on` — re-fetch past either.
- `content_quality_id`: 6 = premium_high (matches `StreamQuality.premiumHigh`).
- Network slugs / IDs already modeled in `Network.swift`.

*Cross-refs in code:* `DIClient.swift` (auth, `favoritesData`/`voteRequest` request patterns,
`streamURL`), `AudioPlayer.swift:410-436` (Now Playing + remote commands; `nextTrackCommand`
disabled at :434), `Models/Models.swift` (`StreamQuality`), `Network.swift` (`apiBaseURL`).
