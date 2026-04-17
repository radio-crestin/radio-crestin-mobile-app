# Chromecast Testing with CaCTool

Harness for exercising the Cast sender path (LOAD payloads produced by
`lib/services/cast_service.dart`) directly from a Chrome browser, without
rebuilding the app. Use this to:

- Validate HLS and MP3 playback on real Cast devices.
- Reproduce receiver errors before shipping a sender change.
- Inspect the actual MediaInfo the receiver sees (via the debug overlay).

## Prerequisites

1. Chrome (desktop). CaCTool uses the Cast Web Sender SDK.
2. A Cast device on the same Wi-Fi (Chromecast, Chromecast Ultra, Google TV,
   Google Nest Hub, Google Home Mini, Nest Audio, or Android TV).
3. The stream endpoints are publicly reachable — no VPN needed.

## App ID

The app uses the **Google Default Media Receiver**:

```
CC1AD845
```

This is the correct App ID to paste into CaCTool's **Receiver App ID**
field. No Cast SDK Developer Console registration is required.

> If you ever bring back the custom receiver at `cast.radiocrestin.ro`
> (source in `cast_receiver/`), register it in the Cast SDK Console, put
> the target Cast device in developer mode, and substitute its assigned
> App ID here.

## Launch Flow

1. Open <https://casttool.appspot.com/cactool/> in Chrome.
2. Paste `CC1AD845` into **Receiver App ID**. Leave the Android TV options
   checkbox off.
3. Click the Cast button in the browser toolbar / page and pick a device.
   CaCTool establishes a Cast session against the Default Media Receiver.
4. Scroll to **Load Media → Custom Load Request** and paste one of the
   payloads below. Pick **LOAD** as request type and hit
   **Send Custom Load Request**.
5. Use the Media Control row (Play, Pause, Stop) to exercise state
   transitions. Use **Media Status → Check** to dump the current
   `MediaStatus` JSON from the receiver.
6. Toggle **Receiver Debug Overlay → SHOW** on the Cast device to see
   what the receiver parsed (content type, streamType, HLS segment
   format, player errors).

## Sample Payloads

These mirror what `CastService._buildMediaInfo` emits — keep them in sync
if the sender contract changes.

### HLS live stream (preferred path)

Target station: `cross-one` — any station with `station_streams.type = HLS`
works. The sender now picks HLS first for all stations that expose one
(56 of 64 stations at the time of writing).

```json
{
  "media": {
    "contentId": "https://hls.radiocrestin.ro/hls/cross-one/index.m3u8?ref=radio-crestin-chromecast-cactool&s=cactool-device",
    "contentUrl": "https://hls.radiocrestin.ro/hls/cross-one/index.m3u8?ref=radio-crestin-chromecast-cactool&s=cactool-device",
    "contentType": "application/x-mpegURL",
    "streamType": "LIVE",
    "hlsSegmentFormat": "TS",
    "metadata": {
      "metadataType": 3,
      "title": "Cross One",
      "albumName": "Radio Creștin",
      "artist": "Now Playing — Artist",
      "images": [
        { "url": "https://cdn.radiocrestin.ro/?url=https%3A%2F%2Ffsn1.your-objectstorage.com%2Fprod-rke2-radiocrestin-admin-storage%2Fpublic%2Fstations%2Fcross-one.jpg&sig=9556e9d08dbaf694c86bd875eee7735ea7ad9c6a3c892f3d99eb52db173d65a3&w=480&f=jpeg&max_age=2592000" }
      ]
    }
  },
  "autoplay": true
}
```

Notes:

- `hlsSegmentFormat: TS` matches the real segment Content-Type
  `video/mp2t` served at `hls.radiocrestin.ro`. The wire format for this
  field is UPPER_SNAKE_CASE (`TS`, `TS_AAC`, `AAC`, …) per the Cast
  protocol, even though the Dart plugin models it as lowercase `ts`.
- `streamType: LIVE` — required; Default Media Receiver disables the
  scrubber and seek commands for live.
- `metadataType: 3` = `MUSIC_TRACK`. `GoogleCastMusicMediaMetadata` in
  the sender maps to this.

### MP3 direct stream (fallback path)

Target station: `aripi-spre-cer` — stations with only `direct_stream`
will hit this path.

```json
{
  "media": {
    "contentId": "https://mobile.stream.aripisprecer.ro/radio.mp3?ref=radio-crestin-chromecast-cactool&s=cactool-device",
    "contentUrl": "https://mobile.stream.aripisprecer.ro/radio.mp3?ref=radio-crestin-chromecast-cactool&s=cactool-device",
    "contentType": "audio/mpeg",
    "streamType": "LIVE",
    "metadata": {
      "metadataType": 3,
      "title": "Aripi Spre Cer",
      "albumName": "Radio Creștin",
      "artist": "Now Playing — Artist",
      "images": [
        { "url": "https://cdn.radiocrestin.ro/?url=https%3A%2F%2Ffsn1.your-objectstorage.com%2Fprod-rke2-radiocrestin-admin-storage%2Fpublic%2Fstations%2Faripisprecer_61Mv959.jpg&sig=68325911be5dc0004a88a77d38a2af5e805dcfcfe945e060f327dd363cd9f483&w=480&f=jpeg&max_age=2592000" }
      ]
    }
  },
  "autoplay": true
}
```

Notes:

- No `hlsSegmentFormat` — irrelevant for progressive MP3.
- `audio/mpeg` is what `_guessContentType` returns for non-HLS URLs. If
  a station ever switches to AAC (`.aac`) or OGG (`.ogg`) the guesser
  picks `audio/aac` / `audio/ogg`; test those too if you add one.

### Metadata-only refresh (simulates `updateCastMetadata`)

Fire a second LOAD with the same URL and a different `title` / `artist`
/ `images` to confirm the receiver re-renders the now-playing overlay
without audible interruption. The sender does this every time the
station poll detects a new song while casting.

## What to Verify

For both HLS and MP3 payloads, on each target device class:

- [ ] Playback starts within ~3 s.
- [ ] `artwork` renders (480 px JPEG from `cdn.radiocrestin.ro`).
- [ ] Title / artist text shows the sent metadata.
- [ ] **Pause** from CaCTool pauses audio on the device.
- [ ] **Stop** leaves the receiver idle and the app's
      `castPlayerState` transitions to `unknown`.
- [ ] A second LOAD with new metadata replaces the overlay text without
      killing audio glitchily for HLS (expect a brief buffer on MP3).
- [ ] Debug Overlay shows the parsed `contentType` and, for HLS,
      `hlsSegmentFormat = TS`.

## Known Compatibility Concerns

- **Audio-only Cast devices** (Google Home Mini, Nest Audio, Nest Hub
  Max speaker output): HLS support is historically inconsistent on
  these. If LOAD fails or playback stalls, the sender's MP3 fallback
  kicks in for any station that exposes `direct_stream`. Eight stations
  have only `direct_stream` — those are always MP3 even via
  Cast-preferred paths.
- **Cloudflare HEAD 501 on HLS**: `hls.radiocrestin.ro` returns HTTP 501
  for `HEAD` requests but 200 for `GET`. Cast devices always use `GET`
  for playlists and segments, so this is a non-issue for playback — but
  note it if you probe with `curl -I`.
- **Playlist content-type variance**: the origin serves
  `application/vnd.apple.mpegurl` while the sender declares
  `application/x-mpegURL`. Both are accepted by the Default Media
  Receiver and are interchangeable on the wire.
- **Tracking query params**: `?ref=...&s=...` are appended by
  `_addCastTrackingParams`. Make sure they survive the LOAD → receiver
  → segment request chain. Easy check: analytics on the origin shows
  the `radio-crestin-chromecast-*` ref on segment fetches.
- **Live-edge jumps after long pause**: HLS playlists have finite window
  (target duration 6 s). Pausing > ~30 s and resuming can trigger a
  seek to live edge; the receiver handles it, but the audio skip may
  confuse the listener. MP3 streams don't have this issue (no seek
  surface).

## Cross-checking Against the Real App

If a CaCTool scenario succeeds but the app does not (or vice versa),
diff the actual JSON the sender produces. On iOS, bundle-debug logs
print `CastService: _buildMediaInfo: ... streamType=HLS, contentType=application/x-mpegURL`
for every LOAD. On Android, `adb logcat | grep CastService` surfaces the
same lines. Match those against the CaCTool payloads here.
