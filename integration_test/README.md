# End-to-end tests

The app's only tests. This file explains how to run them, how the harness works, and how to add one.
Open it before you write or debug an e2e test. The rule that there are no unit tests is in
[`CLAUDE.md`](../CLAUDE.md#testing).

## Run

```bash
xcrun simctl list devices booted; adb devices      # find a device id
flutter test integration_test/app_test.dart -d <device id>
flutter test integration_test/app_test.dart -d <device id> --plain-name "pause"   # one test
```

A run takes about 10 minutes on a simulator, most of it spent listening to audio. Keep the simulator to
yourself during a run: another install on it replaces the app under test.

## How it works

One test file, `app_test.dart`, launches the real app once (a fresh install: no settings, cache or
favorites) and runs every test against it, since its services are app-wide singletons. Each test gets the
app back on its home screen, silent, on a healthy network.

- **`harness/fake_radio_server.dart`** runs inside the test, on the device's loopback. It serves the REST
  API, the live HLS origin, the stations' MP3 servers, images and the internet probes. It answers each
  request on its raw socket, so a test can drop a connection in the middle of a body.
- **`harness/network_conditions.dart`** is the network a test sets, per origin (`api`, `hls`, `mp3`,
  `images`, `internetProbe`): latency, a bandwidth cap, and an outage (`refused`, `silent`,
  `serverError`, `notFound`). The server re-reads it for every 4 KB it sends, so a change hits streams
  already playing.
- **`harness/live_hls.dart`** is a live stream like the origin's: an 11-minute window of 6 s segments
  with program dates. A test can `freeze()` it, as when the origin's encoder dies.
- **`harness/radio_app.dart`** launches the app through `runRadioCrestin` with `AppLaunchOptions` (API
  and probes on the fake server, no PostHog, push or store prompts). It also drives the app through its
  screens (`tapStation`, `tapMiniPlayerButton`, `openFullPlayer`) and checks what a listener hears and
  sees:
  - `expectPlaying`: the station plays. Its position moves for 5 s, its stream was fetched, and the mini
    player shows it with a pause button.
  - `expectSilent`: nothing plays, and the mini player offers to play.
- **`harness/station_catalog.dart`** lists the stations: three with HLS and an MP3 fallback, as most real
  stations have, and one with only MP3.
- **`harness/media.g.dart`** holds the audio: tiny, nearly silent AAC and MP3 clips. Regenerate it with
  `tool/generate_media.sh` (needs ffmpeg).

## Add a test

1. Write it in `app_test.dart` with `e2eTest`, in the group of its flow.
2. Act as the listener does, through the screens. Reach into `app.audio` only to read state for an
   assertion or a failure message.
3. Set the network with `server.conditions.set(Link(...), origins: [...])` or `goOffline()`. The harness
   restores it after the test.
4. Assert with `expectPlaying`, `expectSilent` and `expectAudioAdvances`, never with a fixed wait alone:
   wait for the outcome with `waitFor` and a timeout a listener would accept.
