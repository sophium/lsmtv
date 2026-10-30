# LSM TV

A native tvOS app for watching Latvijas Televīzija — live channels, the daily
schedule and the on-demand archive — from the streams behind
[replay.lsm.lv](https://replay.lsm.lv).

## Features

- **Tiešraide** — LTV1 and LTV7 live, plus your pinned favourites.
- **Favourites** — search a show, optionally pin its start time, pick a poster
  frame from the stream, and it sits on the home screen next to the channels.
  One click plays today's airing: live if it hasn't started, otherwise from its
  beginning. Broad favourites such as "sport" offer a chooser when several
  airings match.
- **Programma** — the full schedule for either channel (yesterday, today, tomorrow).
  Past programmes that LSM has recorded are marked **IERAKSTS** and play on
  selection; the programme currently on air opens the live channel.
- **Arhīvs** — the on-demand film/documentary catalogue with category filters.
- Native tvOS player (`AVPlayerViewController`): transport bar, Info panel,
  audio-track picker, and an in-player **Programma** panel so you can jump to
  another past or current show without leaving playback.

## Requirements

- Xcode 15 or newer (built and verified with Xcode 27 / tvOS 27 SDK).
- tvOS 17.0 or newer.

## Build and run

```sh
open LSMTV.xcodeproj
```

Pick the **LSMTV** scheme and either a tvOS simulator or a connected Apple TV.
For a physical Apple TV, select your development team under
*Signing & Capabilities* (the bundle identifier is `lv.lsm.tv`; change it if it
collides with something already registered).

From the command line:

```sh
# Simulator
xcodebuild -project LSMTV.xcodeproj -scheme LSMTV \
  -configuration Debug -sdk appletvsimulator \
  -destination 'generic/platform=tvOS Simulator' build

# Device (needs a signing team)
xcodebuild -project LSMTV.xcodeproj -scheme LSMTV \
  -configuration Release -sdk appletvos \
  -destination 'generic/platform=tvOS' build
```

## How the streams are resolved

The replay.lsm.lv web player is an embedded Redge Media player. The app speaks
to the same backend directly:

1. `GET https://telpa.lsm.lv/api/products/lives?platform=BROWSER&tenantUid=LsmP`
   resolves channels by their `externalUid` (`ltv1`, `ltv7`) and supplies logos.
   The channel ids are pinned as a fallback in `LiveChannel.catalogue`.
2. `GET /api/products/<assetId>/videos/player/configuration?platform=BROWSER&videoType=LIVE|MOVIE&tenantUid=LsmP`
   returns a `playlistUrl` carrying a short-lived `cdnToken`.
3. `GET <playlistUrl>` returns the source list. HLS is used; the URL already
   contains the token. On-demand sources also return
   `drm.FAIRPLAY = { src, cert }`.
4. The EPG comes from
   `GET /api/products/lives/programmes?...&liveId[]=<id>&since=...&till=...`
   (timestamps are UTC with a percent-encoded `+0000`).

A fresh token is requested every time playback starts, so the ~48-hour token
lifetime never matters.

### Favourites

A favourite is a *query* rather than a fixed stream: a title fragment, an
optional `HH:mm` start time and an optional channel. That is what turns
"Panorāma, 20:00, LTV1" into a one-click shortcut that works every day.

Adding one:

1. type a search string — the app scans a week of the EPG (both channels),
2. pick an airing from the results; its start time and channel become the
   favourite's filter (that is what keeps Panorāma 20:00 apart from Rīta
   Panorāma 04:30). Pressing **Pievienot “…”** instead saves a broad favourite
   with no channel or time,
3. pick the logo: the app opens a full-screen clip of the most recent airing
   spanning 10 seconds before the programme start through two minutes after it. Step through it with ⬅ ➡ (0.5 s per press) or the **◀ 1s / 1s ▶**
   buttons; **Select** on the video — or **Izvēlies kadru** — captures the frame
   on screen.

Focusing a favourite on the home screen shows a hint that holding **Select**
opens *Labot* / *Dzēst*. Editing works from two places: long-press a favourite on the home screen and
choose **Labot favorītu**, or press the **★** action in the player while
watching a favourite. The editor lets you change the name, regenerate the
poster, or delete the favourite.

Selecting a favourite resolves today's airings and picks the right mode:

| now | playback |
|---|---|
| before the programme | the channel, live |
| during it | the channel, timeshifted to the programme's start |
| after it | the channel, window from start to end |

Several matches (e.g. a "sport" favourite) open a chooser instead. Matching is
diacritic-insensitive and word-prefix based, so "sport" finds *Sporta ziņas*
but not *pašportrets*.

Favourites are stored in `UserDefaults`; poster images go to
`Library/Caches/LSMTV`, because tvOS denies writes inside `Application Support`
and `Documents`. (The system may purge the cache under disk pressure; the
favourite itself survives and falls back to the gradient tile.)

### In-player guide

The **Programma** action in the transport bar opens the schedule over the video.
Picking an entry replaces the current stream in place: future programmes open
the channel live, in-progress ones start at their beginning, and finished ones
play their full window. Playback never leaves the player.

### Back navigation

The player intercepts the remote's **Menu** press with a window-level
`UITapGestureRecognizer` (`allowedPressTypes = .menu`) plus a `pressesBegan`
override — AVKit consumes the press inside its own views, so a recognizer on
the player view never sees it. The handler pops the hosting `NavigationStack`
path explicitly. The gesture is disabled while the guide or editor sheet is
open, and the transport bar carries an explicit **Atpakaļ** action as well.

### Seeking and "Sākt no sākuma"

The transport bar carries a custom **Sākt no sākuma** action
(`AVPlayerViewController.transportBarCustomMenuItems`) that seeks to the start
of whatever is playing — a recording, a film, or the live channel's current
programme.

That works on live because the CDN does serve a timeshift window after all:
appending `startTime=<milliseconds since the 1904 epoch>` to the HLS playlist
returns a live playlist that begins at that instant. Verified back to seven
days, and the window keeps growing. Live playback therefore requests the
current programme's start as the window origin (while still starting at the
live edge), so the scrub bar spans the whole programme and the native **LIVE**
control returns to the edge.

### Past programmes (catch-up)

The telpa EPG knows the schedule but not which past entries were recorded. That
information lives in the editorial guide on `replay.lsm.lv`, which is a Nuxt
server-rendered page carrying its payload as
`window.__REPLAY__ = (function (…) {…})(…)`. `ReplayService` evaluates that
expression in a `JSContext` and reads the resulting JSON. Playable entries
carry a `mediaItem` (`external_source`, `external_id`, `slug`).

Selecting one resolves through three hops:

1. `https://replay.lsm.lv/lv/skaties/ieraksts/ltv/<id>/<slug>` →
   `playback.service.url` (an LTV embed URL),
2. that embed page → `"item_id"` (the telpa asset id),
3. `/api/products/<assetId>/videos/player/configuration?...&videoType=MOVIE`
   → playlist → HLS.

Descriptions shown in the schedule are merged in from the telpa EPG by start
time, so the list keeps both the rich metadata and the playability.

### FairPlay

Archive titles are `SAMPLE-AES` encrypted with `URI="skd://skd"`.
`FairPlayKeyLoader` implements the standard flow: load the FPS certificate,
turn each key request into an SPC with
`AVContentKeyRequest.makeStreamingContentKeyRequestData(forApp:contentIdentifier:)`,
POST the SPC to the license endpoint as `application/octet-stream`, then feed
the returned CKC back through `AVContentKeyResponse(fairPlayStreamingKeyResponseData:)`.

## Debug launch arguments

All hooks are inert unless `-debugHooks 1` is passed, so a normal launch can
never be affected by them:

```sh
xcrun simctl launch booted lv.lsm.tv -debugHooks 1 -startTab archive
xcrun simctl launch booted lv.lsm.tv -debugHooks 1 -play ltv1
xcrun simctl launch booted lv.lsm.tv -debugHooks 1 -play recording
xcrun simctl launch booted lv.lsm.tv -debugHooks 1 -play favorite
xcrun simctl launch booted lv.lsm.tv -debugHooks 1 -play addFavorite
xcrun simctl launch booted lv.lsm.tv -debugHooks 1 -play chooser
xcrun simctl launch booted lv.lsm.tv -debugHooks 1 -play editFavorite
```

## Known limitations

- Streams are subject to LSM's geo- and login-gating. If the device's network
  is not allowed to watch a title, the player shows the HTTP error it got.
- The archive lists standalone `VOD` titles. `SERIAL` containers (series
  pages) need an authenticated session to expand into episodes, so they are
  skipped — broadcast episodes are reachable through **Programma** instead.
- Some on-demand titles are geo- and login-gated; if the device's network is
  not allowed, the player shows the HTTP error it got.

## Layout

```
LSMTV/
  LSMTVApp.swift         app entry (main.swift starts it)
  RootView.swift         the three tabs
  ChannelBrowserView.swift home screen: channels, favourites, add tile
  ScheduleView.swift     schedule browser (playable past programmes)
  ArchiveView.swift      VOD catalogue
  AddFavoriteView.swift  search, start-time filter, poster picker
  Favorites.swift        favourite model, storage and resolution
  FramePickerView.swift  −10s…+10s scrubbable logo picker
  PlayerView.swift       AVPlayerViewController + playback model
  FairPlayKeyLoader.swift FPS key exchange
  LSMService.swift       Redge Media API client
  ReplayService.swift    replay.lsm.lv guide + recording resolution
  Models.swift           domain models
```

## Toolchain note

`@main` does not synthesise an entry point with the Xcode 27 / Swift 6.4
toolchain used here, so the app starts from `LSMTV/main.swift` calling
`LSMTVApp.main()`.

## License

MIT — see [LICENSE](LICENSE).
