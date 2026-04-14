import 'dart:async';

import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../../appAudioHandler.dart';
import '../../types/Station.dart';
import '../../widgets/animated_play_button.dart';
import '../tv_theme.dart';

/// Persistent bottom mini player bar for TV.
/// Shows station thumbnail, station name, song title, and play/pause.
class TvMiniPlayer extends StatefulWidget {
  final VoidCallback onTap;

  const TvMiniPlayer({super.key, required this.onTap});

  @override
  State<TvMiniPlayer> createState() => _TvMiniPlayerState();
}

class _TvMiniPlayerState extends State<TvMiniPlayer> {
  late final AppAudioHandler _audioHandler;
  final List<StreamSubscription> _subscriptions = [];
  Station? _station;
  final _playButtonKey = GlobalKey<AnimatedPlayButtonState>();

  @override
  void initState() {
    super.initState();
    _audioHandler = GetIt.instance<AppAudioHandler>();
    _subscriptions.add(
      _audioHandler.currentStation.stream.listen((station) {
        if (mounted) setState(() => _station = station);
      }),
    );
  }

  @override
  void dispose() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final station = _station;
    if (station == null) return const SizedBox.shrink();

    return Container(
      height: TvSpacing.miniPlayerHeight,
      color: TvColors.surfaceHigh,
      child: DpadFocusable(
        onSelect: widget.onTap,
        builder: FocusEffects.border(
          focusColor: TvColors.focusBorder,
          width: 2,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: TvSpacing.lg,
            vertical: TvSpacing.sm,
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(TvSpacing.radiusSm),
                child: SizedBox(
                  width: 52,
                  height: 52,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    child: SizedBox(
                      key: ValueKey(station.artUri.toString()),
                      width: 52,
                      height: 52,
                      child: station.displayThumbnail(cacheWidth: 104),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: TvSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      station.title,
                      style: TvTypography.label.copyWith(
                        color: TvColors.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      child: Text(
                        station.displaySubtitle,
                        key: ValueKey(station.songId),
                        style: TvTypography.caption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: TvSpacing.md),
              AnimatedPlayButton(
                key: _playButtonKey,
                playbackStateStream: _audioHandler.playbackState,
                iconSize: 32,
                iconColor: TvColors.textPrimary,
                onPlay: _audioHandler.play,
                onPause: _audioHandler.pause,
                onStop: _audioHandler.stop,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
