# 2026-05-02 — Radio Eldad HLS disconnect investigation

User report: **Flutter iOS app** on device `2803A46D-80D1-469F-9601-C38CACC302F5` running v1.5.0+77, station `radio-eldad`, stream `HLS 1/2` (`https://hls.radiocrestin.ro/hls/radio-eldad/index.m3u8`), heard a multi-minute audio disconnect. Diagnostic generated 2026-05-02T11:31:40 (Bucharest = 08:31:40 UTC).

User's broader concern: complaints have spiked since recent HLS work (the live transcoding rewrite that started 2026-04-10), whereas the system was stable before.

## Diagnostic timeline (UTC, parsed from device-local Bucharest stamps)

| UTC | Event | Notes |
| --- | --- | --- |
| 08:08:23 | Attempt 1/2 HLS | first HLS attempt of the radio-eldad session |
| 08:08:23 | HLS loaded in 461ms | OK |
| 08:08:24 | Rebuffer 391ms — buf 132009ms ahead, end=ready | textbook decoder-stall signature |
| 08:16:32 | Rebuffer 279ms — buf 378020ms ahead, end=ready | another decoder-stall |
| 08:29:10 | Attempt 1/2 HLS | auto-recovery |
| 08:29:11 | HLS loaded in 622ms | OK |
| 08:29:11 | Rebuffer 702336ms — buf 438021ms ahead, end=ready | **the 11:42 silence the user heard** |
| 08:29:11 | Rebuffer 341ms — buf 132009ms ahead, end=ready | post-recovery decoder-stall |

## Backend, radio-eldad pod (PostHog, distinct_id = "radio-eldad")

- **Zero `ffmpeg_exit`, `pod_started`, `stream_warning`, `stream_monitor_started` events** in 07:00–10:00 UTC on 2026-05-02. The pod was completely stable during the disconnect window.
- Last `stream_warning` for radio-eldad before the incident: 06:50:41 UTC (well before the user's window).
- Image deployed: `v1.1.170`, started 2026-05-01T16:35:53Z. v1.1.170 is the build that includes commit `b44bf14` (committed 2026-05-01 16:02 UTC — 33 min before the pod started).
- Live playlist re-fetched twice 12s apart: **58 segments shared, 0 PDT mismatches.** The b44bf14 stable-PDT cache is doing its job in production.
- HLS playlist served end-to-end through Cloudflare looks healthy: `200`, `Cache-Control: no-store`, segments fresh (~3s lag from wallclock when measured).

**Conclusion: the radio-eldad backend was not the cause of this user's disconnect.**

## Flutter iOS app side (PostHog, distinct_id = device UUID)

- Last heartbeat (`listening_active`) before silence: **2026-05-02T08:02:45.045Z** on station `rve-targoviste` (NOT radio-eldad), `stream_type=direct_stream`.
- After that timestamp: nothing from this device until the diagnostic dump at 08:31:40. **~28 min of telemetry silence.**
- The diagnostic's first radio-eldad event is `Attempt 1/2 HLS` at 08:08:23 — meaning the user switched stations to radio-eldad somewhere between 08:02:45 and 08:08:23, but the `listening_started` for radio-eldad never reached PostHog (consistent with telemetry silence above).
- Pattern strongly suggests the device lost network or was suspended mid-session.

## The 11:42 stall vs the textbook 132009ms signature

These are two different failure modes in the same diagnostic:

1. **`Rebuffer ~300ms — buf ~132000ms ahead` (PDT-decoder confusion)**
   - This is the textbook signature `b44bf14` was designed to fix.
   - Mechanism (per commit message): PDT drifted ~10–14ms forward each playlist refresh, AVPlayer interpreted it as a moving live edge and seek-forwarded, stalling the decoder for a few hundred ms even though the buffer was full.
   - **Status post-fix:** still firing. Seven `stream_buffering_drop` events on 2026-05-01, two of them at 19:55–19:56 UTC, **after** the v1.1.170 deploy at 16:35 UTC. Same iOS 1.5.0, same device, all on radio-eldad, all `buffered_ahead_at_start_ms = 131986–132009`. The PDT cache is stable per playlist — but this signature is still surfacing on already-stale segments or on the cold-start fallback path.

2. **`Rebuffer 702336ms — buf 438021ms ahead`**
   - 11:42 stall, with 7:18 of buffer at the start. The buffer had to drain (seven minutes of silence playable) **then** four more minutes with no recovery before reconnect.
   - Correlated with the device's 28-min PostHog telemetry blackout starting at 08:02:45.
   - This looks like a **device-side connectivity drop**, not a backend bug. A healthy radio-eldad pod and a stable Cloudflare playlist do not produce 11+ minute audible silence on a connected client.

## Cluster-wide health — last 7 days

`stream_warning` counts by `warning_kind`:

| Kind | Count | Notes |
| --- | --- | --- |
| `1 segment 404s in interval` | 17,322 | clients fetching segments after origin deletion |
| `5/4/2/3 segment 404s` | 2,011 | bursts of segment 404s |
| `MEDIA-SEQUENCE stuck at 0` | 513 | playlist not advancing — could mean a wedged ffmpeg or cold-start mis-detection |
| `XX playlist 5xx` (10/20/40/50/70/80) | 1,733 | nginx returning 5xx for playlist requests |
| `live.m3u8 missing` | 165 | playlist file gone from disk |
| `no segments on disk` | 165 | empty `/data/hls/aac/` |
| `ffmpeg stalled (newest segment NN s old)` | ≥830 across NN buckets | input source stuttering |

`ffmpeg_exit` counts by station (last 7 days, top offenders):

| Station | Exits | Total restarts |
| --- | --- | --- |
| rve-viena | 400 | 807 |
| rve-viena-tineri | 386 | 778 |
| rve-viena-muzica | 338 | 674 |
| aripi-spre-cer | 91 | 136 |
| aripi-spre-cer-instrumental | 87 | 130 |
| radio-o-noua-sansa | 30 | 43 |
| (others single-digit) | | |

**The `rve-viena*` triplet is essentially crashlooping FFmpeg** (~50 exits/day each). Their upstream sources are unstable. radio-eldad is fine — only one `pod_started` in 7 days.

## Recent HLS work (chronological context for "since the updates")

The user's "the HLS backend was in another folder" matches: the previous HLS lived in `backend_hls_streaming/` (legacy supervisor + S3 mirror); the current one is in `backend_streams_transcoding/live_streaming/`. The cutover commit was `355d578` on 2026-04-10 ("replace HLS streaming with per-station DASH+HLS live transcoding"). Subsequent commits:

- 2026-04-10..04-15: full new pipeline — DASH dropped, HLS standardized, per-station ingresses, segment naming, cache-control, retention.
- 2026-04-26 `9c3c2d8`: 16-min retention + stream_monitor + restart visibility.
- 2026-04-27 `c324827`: PostHog server-side reporting (this is when our infra metrics start).
- 2026-04-30 `585baaa`: HE-AAC 64k → AAC-LC 96k — segments ~50% larger, more bandwidth required (compatibility win, but a possible factor in client-side rebuffers on flaky networks).
- 2026-05-01 `b44bf14`: stable per-segment PDT + atomic playlist writes (addresses the 132s decoder-stall signature).

## Rebuffer accounting (Flutter app)

Verified in `lib/appAudioHandler.dart`:

- `_bufferingStartedAt` is set on **first** entry into `ProcessingState.buffering` per episode (uses `??=`, line 673) and cleared in `_recordBufferingExit` (line 254) when state transitions out of `buffering`.
- `Rebuffer Nms` in the diagnostic = `DateTime.now() - _bufferingStartedAt`. **Real wallclock time the player reported `buffering` continuously**, no maths trickery.
- `buf Mms ahead at start` = `_bufferingStartBuffered - _bufferingStartPosition`, both captured at the moment the buffering listener fires. **Minor quirk:** `_bufferingStartPosition` and `_bufferingStartBuffered` are overwritten on **every** buffering event (lines 674–675) without the `??=` guard that `_bufferingStartedAt` has. just_audio's `processingStateStream` typically only fires on transitions, so in practice these get set once per episode — but it's an asymmetric guard that's worth tightening.
- `_bufferingDropMinDuration = 250ms` (line 199): rebuffers below 250ms are intentionally dropped from the diagnostic and PostHog as sub-perceptual decoder reseeding. So every line you see in the diagnostic represents an audible/perceptual stall.
- `_bufferingStallTimeout = 15s` (line 196): if `buffering` doesn't resolve in 15s, the player gives up and fires `stream_buffering_stall` then stops with a `network` connection error.

**Implication for the user's `Rebuffer 702336ms — buf 438021ms ahead`:**
- The 702 336 ms (11:42) is the genuine wallclock duration AVPlayer reported `buffering` continuously.
- For that to happen **without the 15s stall timer firing**, the Dart isolate's `Timer` must have been frozen during the window — which is exactly what iOS does when it suspends a background app whose audio engine is buffering (no active audio output → no `audio` background task keeping the app awake).
- The `438021ms` (7:18) buffered-ahead at start is unusually large for HLS (AVPlayer caps live HLS forward buffer around 30s–2min). The plausible explanation is that the player was bufferedPosition-advancing without playback-head-advancing for a while before processingState reported `buffering` — iOS audio session was interrupted or the route changed and the player kept fetching while output was muted. When state finally moved to `buffering`, the gap was already large.
- Lines up with the 28-min PostHog blackout from the same device: when iOS suspends the isolate, PostHog's batch flush also pauses.
- Bottom line: **the 11:42 figure is real, not an artifact, and the symptom is iOS suspending the app while AVPlayer was waiting on the network. Backend was fine for the entire window.**

## Open questions / next steps

1. **The 132s decoder-stall signature is still firing post-`b44bf14` (see 19:55–19:56 UTC events).** Worth opening a new ticket. Hypotheses to test:
   - sidecar-cold-start path: the very first playlist render after pod start anchors PDT on `_extract_epoch(first_segment)`, which is integer-second; if segment 0 of the cold playlist gets a PDT a few hundred ms different than what AVPlayer sees in MPEG-TS PCRs, AVPlayer can still drift.
   - cross-pod-restart: when a pod is replaced (rolling update), the new pod's segments start with new sidecars; clients holding old playlists continue to see old PDTs while new ones arrive — discontinuity at the boundary.
   - check whether the `+temp_file` flag on FFmpeg HLS output is honored on the FS in use (emptyDir vs PVC); if FFmpeg writes `live.m3u8` non-atomically and `playlist_generator.py` reads mid-write, an enhanced playlist with a partial PDT chain can surface to clients.
2. **rve-viena cluster.** Source stream URL is the likely culprit. Pull the current `stream_url` from Django and check upstream availability. Crashlooping FFmpegs explain a non-trivial fraction of cross-station complaints.
3. **17k segment 404s/week.** Drill into which clients/CDN POPs are requesting old segments. With `Cache-Control: no-store` on the playlist this should be rare. Could be: clients holding their own m3u8 cache longer than retention; Cloudflare cache for the m3u8 leaking despite `no-store`; a known iOS AVPlayer quirk where it requests the segment **after** a playlist refresh whose new window dropped it.
4. **Flutter iOS device `2803A46D-…`.** Aside from the systemic stuff, this device's specific 08:17–08:29 silence is most plausibly a device-side event — iOS app suspended / background-audio session interrupted / Wi-Fi handoff — based on the 28-min PostHog blackout and zero correlated backend signals. Worth checking what `lib/appAudioHandler.dart` (and the just_audio iOS bridge) does when the app is backgrounded for >N minutes and whether it surrenders the audio session under iOS pressure.

## Files referenced

- Backend pipeline: `backend_streams_transcoding/live_streaming/scripts/{entrypoint.sh,playlist_generator.py,stream_monitor.py}`
- Controller: `backend_streams_transcoding/controller.py`
- Latest HLS commit: `b44bf14 fix(streaming): stable per-segment PDT + atomic playlist writes`
