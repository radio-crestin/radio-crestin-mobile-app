# Chromecast Testing with CaCTool

Harness for exercising the Cast sender path (LOAD payloads produced by
`lib/services/cast_service.dart`) directly from a Chrome browser, without
rebuilding the app. Use this to:

- Validate direct-stream playback on real Cast devices.
- Reproduce receiver errors before shipping a sender change.
- Inspect the actual MediaInfo the receiver sees.

## Prerequisites

1. Chrome (desktop). CaCTool uses the Cast Web Sender SDK.
2. A Cast device on the same Wi-Fi (Chromecast, Chromecast Ultra, Google TV,
   Google Nest Hub, Google Home Mini, Nest Audio, or Android TV).
3. The stream endpoints are publicly reachable — no VPN needed.
4. macOS only: `System Settings → Privacy & Security → Local Network`
   must include **Google Chrome**, otherwise mDNS discovery is blocked
   and no Cast devices appear in the picker.

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
3. Connect via Chrome's menu: `⋮ → Cast, save, and share → Cast…` and
   pick a device. (Cactool does not draw its own Cast button.)
4. Send a LOAD — two options:
   - **Option A, UI fields.** In **Load Media**, paste the stream URL
     into **Content URL** and click **Send Request**. Simple but does
     **not** set `contentType` or `streamType` — see the caveats in
     "Why the UI fields aren't enough" below.
   - **Option B, Custom Load Request textarea.** Scroll past the UI
     fields to the **Custom Load Request** block. Paste one of the JSON
     payloads from the next section. Click **Send Custom Load Request**.
   - **Option C, DevTools console.** Paste one of the JS snippets below
     into the Chrome DevTools console on the Cactool tab — bulletproof
     against copy-paste whitespace and smart-quote corruption.
5. Use **Media Control → Play/Pause/Stop** to exercise state
   transitions. Use **Media Status → Check** to dump the current
   `MediaStatus` JSON from the receiver.

## Sample Payloads

The app now sends **non-HLS direct streams only** (see "Why not HLS"
below). Stations that only expose HLS (8 of 64 at the time of writing)
are skipped by `_pickCastStream` and cannot be cast.

### Direct MP3 (primary path)

Target station: `aripi-spre-cer`. Content-type `audio/mpeg` matches what
`_guessContentType` returns for `.mp3` URLs.

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
        {"url": "https://cdn.radiocrestin.ro/?url=https%3A%2F%2Ffsn1.your-objectstorage.com%2Fprod-rke2-radiocrestin-admin-storage%2Fpublic%2Fstations%2Faripisprecer_61Mv959.jpg&sig=68325911be5dc0004a88a77d38a2af5e805dcfcfe945e060f327dd363cd9f483&w=480&f=jpeg&max_age=2592000"}
      ]
    }
  },
  "autoplay": true
}
```

Same via DevTools console (no JSON parse to trip over):

```js
(async () => {
  const session = cast.framework.CastContext.getInstance().getCurrentSession();
  const m = new chrome.cast.media.MediaInfo(
    'https://mobile.stream.aripisprecer.ro/radio.mp3',
    'audio/mpeg'
  );
  m.streamType = chrome.cast.media.StreamType.LIVE;
  const r = new chrome.cast.media.LoadRequest(m); r.autoplay = true;
  await session.loadMedia(r);
})();
```

### Metadata-only refresh (simulates `updateCastMetadata`)

Fire a second LOAD with the same URL and a different `title` / `artist`
/ `images` to confirm the receiver re-renders the now-playing overlay.
Expect a brief audible re-buffer — the progressive MP3 stream restarts.
The sender does this every time the station poll detects a new song
while casting.

## Why the UI fields aren't enough

Cactool's top-of-page Content URL + Send Request builds a LOAD with
`streamType: BUFFERED` (wrong — our streams are `LIVE`) and no
`contentType` (receiver has to guess from URL extension). Media Status
after that sort of LOAD shows:

```
"contentType": "",
"streamType": "BUFFERED"
```

…which masks real problems. Always prefer Custom Load Request JSON or
the DevTools console snippet.

## What to Verify

On each target device class:

- [ ] Playback starts within ~3 s.
- [ ] `artwork` renders (480 px JPEG from `cdn.radiocrestin.ro`).
- [ ] Title / artist text shows the sent metadata.
- [ ] **Pause** from CaCTool pauses audio on the device.
- [ ] **Stop** leaves the receiver idle and the app's
      `castPlayerState` transitions to `unknown`.
- [ ] A second LOAD with new metadata replaces the overlay text.
- [ ] Media Status reports `contentType: audio/mpeg` and
      `streamType: LIVE`.

## Why not HLS

The Default Media Receiver on **audio-only Google/Nest speakers** (Home,
Home Mini, Mini, Nest Audio, and the speaker path of Nest Hub family)
does **not implement an HLS playlist parser**. Observed behavior:

- LOAD request is accepted (`Load Request Success`, `mediaSessionId`
  increments).
- Receiver enters `LOADING` and never leaves. `contentType` in Media
  Status stays empty, `playerState` stays `IDLE`, `idleReason` never
  populates, no audio.
- Tested payload variants that all fail identically:
  - TS segments with `hlsSegmentFormat: TS` (our origin today).
  - Packed AAC HLS (`hlsSegmentFormat: AAC`, Radio Mast reference).
  - Packed MP3 HLS (`hlsSegmentFormat: MP3`, Radio Mast reference).

The Cast streaming-protocols doc mentions "packed audio" support but
that's a codec-in-container claim (AAC/MP3 bytes are playable); the HLS
protocol layer itself isn't implemented on these receivers. Video-capable
Cast devices (Chromecast / Google TV / Chromecast Ultra) do parse HLS.

Because the app is one codebase shared across device classes, and
because every Romanian station with HLS also exposes a direct MP3
stream, the simplest correct choice is **never send HLS to Cast**. That
also means the 8 stations without a direct_stream variant cannot be
cast at all — `_pickCastStream` returns `null` for them.

### Reference: HLS on video-capable devices

If you ever need to verify HLS still works on a Chromecast, this is the
LOAD our previous code used. Run it from DevTools against a Chromecast
(not a Home Mini) to confirm:

```js
(async () => {
  const session = cast.framework.CastContext.getInstance().getCurrentSession();
  const m = new chrome.cast.media.MediaInfo(
    'https://hls.radiocrestin.ro/hls/cross-one/index.m3u8',
    'application/x-mpegURL'
  );
  m.streamType = chrome.cast.media.StreamType.LIVE;
  m.hlsSegmentFormat = 'TS';
  const r = new chrome.cast.media.LoadRequest(m); r.autoplay = true;
  await session.loadMedia(r);
})();
```

## Known Compatibility Concerns

- **HLS on audio-only receivers**: see above — always hangs in LOADING,
  never surfaces an error. The app sidesteps this by not sending HLS to
  Cast at all.
- **Cloudflare HEAD 501 on HLS**: `hls.radiocrestin.ro` returns HTTP 501
  for `HEAD` requests but 200 for `GET`. Cast devices always use `GET`
  for playlists and segments, so this is a non-issue for playback — but
  note it if you probe with `curl -I`.
- **Tracking query params**: `?ref=...&s=...` are appended by
  `_addCastTrackingParams`. Make sure they survive the LOAD → receiver
  → segment request chain. Easy check: analytics on the origin shows
  the `radio-crestin-chromecast-*` ref on segment fetches.

## Cross-checking Against the Real App

If a CaCTool scenario succeeds but the app does not (or vice versa),
diff the actual JSON the sender produces. On iOS, bundle-debug logs
print `CastService: _buildMediaInfo: ... streamType=direct_stream, contentType=audio/mpeg`
for every LOAD. On Android, `adb logcat | grep CastService` surfaces
the same lines. Match those against the CaCTool payloads here.
