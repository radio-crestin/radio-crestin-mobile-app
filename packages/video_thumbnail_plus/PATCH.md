# Vendored fork of `video_thumbnail_plus` 0.0.2

This is a local copy of
[`video_thumbnail_plus` 0.0.2](https://pub.dev/packages/video_thumbnail_plus),
vendored as a path dependency so we can harden the native method-channel reply
path against a launch-time heap-corruption crash.

## Why

On a physical iPhone (iOS 26.5.2, debug/JIT build) the app crashed during
startup, while the resumed playlist station's track list rendered and fired
several concurrent `VideoThumbnailPlus.thumbnailData(...)` calls:

```
thread #22, name = 'DartWorker', stop reason = EXC_BAD_ACCESS (code=50, address=0x12e1800c4)
->  0x12e1800c4: ldur   x6, [x24, #0x37]   ; x24 is a garbage Dart object pointer
    ...                                      ; JIT'd code incrementing a usage counter
```

Two consecutive runs crashed at **different** addresses with the **identical**
instruction pattern — JIT'd Dart code walking a now-garbage pointer. That is
heap corruption, not a flake. When an earlier UI exception truncated the tree
(so **no** thumbnails were requested), the exact same debug setup booted fine —
i.e. the corruption is triggered by this plugin's method-channel round-trips.

A method-channel reply (`FlutterResult` on iOS, `MethodChannel.Result` on
Android) must be invoked **exactly once**, **on the platform thread**, and
**not after the engine tears down**. Break any of those and the reply plumbing
touches Flutter's messaging/Dart-heap state from the wrong place — which
manifests, later and non-deterministically, as an `EXC_BAD_ACCESS` in unrelated
JIT'd Dart code (exactly the crash above).

Upstream 0.0.2 already hopped the happy/error replies to `main`/`mainHandler`
by hand, but nothing **enforced** the invariant: there was no single-delivery
guard, no thread guard on every path, and no protection against an in-flight
decode replying after its engine detached. This app runs **several Flutter
engines** (CarPlay / Android Auto) that attach and detach independently, so a
decode finishing after its engine is gone is a live path here. We make the
invariant guaranteed for every code path instead of incidental.

## The patch — iOS (`ios/Classes/VideoThumbnailPlusPlugin.swift`)

1. New `MainThreadReply` wrapper. It stores the `FlutterResult`, delivers it
   **at most once** (nils the stored closure under an `NSLock`), and always on
   the main thread (calls inline if already on main, else `DispatchQueue.main.
   async`).
2. `handle(_:result:)` wraps the incoming `FlutterResult` in a `MainThreadReply`
   once and passes a thin closure down; every reply for the call now flows
   through it.
3. The two background (`queue.async`) closures no longer wrap replies in their
   own `DispatchQueue.main.async` — the wrapper owns the hop — so there is a
   single, guaranteed delivery point.

## The patch — Android (`.../VideoThumbnailPlusPlugin.kt`)

1. New `inner class MainThreadReply`. It holds the `Result` in an
   `AtomicReference`, delivers **at most once** (`getAndSet(null)` is atomic
   across the 4 decode threads), always via `mainHandler`, and **drops** the
   reply if the engine has `detached`.
2. `onMethodCall` wraps the incoming `Result` in a `MainThreadReply`; all
   success/error/notImplemented paths go through it (the manual
   `mainHandler.post { ... }` calls in the executor bodies are removed — the
   wrapper posts).
3. New `@Volatile detached` flag, set `false` in `onAttachedToEngine` and
   `true` in `onDetachedFromEngine`, so decodes still running after detach can't
   deliver to a dead messenger.

No shared mutable state exists in the native decode paths themselves (each call
builds its own `AVAssetImageGenerator` / `MediaMetadataRetriever`), so the only
guard needed is on reply delivery.

## Dart-side hardening (not part of this package)

`lib/widgets/video_thumbnail_image.dart` now defers generation to a
post-frame callback (`WidgetsBinding.instance.addPostFrameCallback`), so the
platform-channel decodes don't race engine warm-up during app bootstrap. That
is cheap insurance; the native reply-safety guards above are the real fix.

## Housekeeping

Removed from the vendored copy (not needed to build the pod/aar): the `example/`
app, the `android/src/test` unit test, the empty `ios/Assets/` dir, and the
two demo PNGs (`video_file.png`, `video_url.png`).

## Upgrading

If bumping `video_thumbnail_plus`, re-apply these reply-safety guards (or
confirm upstream added single-delivery + platform-thread + post-detach
protection) before replacing this folder. Keep the Dart API identical so
`lib/widgets/video_thumbnail_image.dart` needs no changes.
