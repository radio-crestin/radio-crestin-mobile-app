import 'dart:async';
import 'dart:io' show Platform;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:like_button/like_button.dart';
import 'package:radio_crestin/theme.dart';
import 'package:radio_crestin/pages/HomePage.dart';
import 'package:radio_crestin/services/share_service.dart';
import 'package:radio_crestin/widgets/share_handler.dart';
import 'package:radio_crestin/services/review_service.dart';
import 'package:radio_crestin/services/song_like_service.dart';
import 'package:radio_crestin/widgets/review_modal.dart';
import 'package:radio_crestin/widgets/song_history_modal.dart';
import '../globals.dart' as globals;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:get_it/get_it.dart';
import 'package:radio_crestin/services/station_data_service.dart';
import '../appAudioHandler.dart';
import '../types/Station.dart';
import '../widgets/animated_play_button.dart';

class FullAudioPlayer extends StatefulWidget {
  final AppAudioHandler audioHandler;
  final CustomPanelController slidingUpPanelController;

  const FullAudioPlayer({
    super.key,
    required this.audioHandler,
    required this.slidingUpPanelController,
  });

  @override
  _FullAudioPlayerState createState() => _FullAudioPlayerState();
}

class _FullAudioPlayerState extends State<FullAudioPlayer> {
  Timer? sleepTimer;
  bool isTimerActive = false;
  Station? currentStation;
  final List _subscriptions = [];
  List<String> _favoriteSlugs = [];
  final _playButtonKey = GlobalKey<AnimatedPlayButtonState>();
  final _likeButtonKey = GlobalKey<LikeButtonState>();
  final StationDataService _stationDataService = GetIt.instance<StationDataService>();

  String _songInfo() {
    final title = currentStation?.songTitle ?? '';
    final artist = currentStation?.songArtist ?? '';
    if (artist.isNotEmpty) return '$title - $artist';
    if (title.isNotEmpty) return title;
    return currentStation?.title ?? '';
  }

  @override
  void initState() {
    super.initState();

    _subscriptions.add(_stationDataService.favoriteStationSlugs.stream.listen((slugs) {
      if (mounted) {
        setState(() {
          _favoriteSlugs = slugs;
        });
      }
    }));

    _subscriptions.add(widget.audioHandler.currentStation.stream.listen((Station? value) {
      if (mounted) {
        setState(() {
          currentStation = value;
        });
      }
    }));
  }

  @override
  void dispose() {
    sleepTimer?.cancel();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasYoutubeLink = (currentStation != null &&
        (currentStation!.songArtist.isNotEmpty || currentStation!.songTitle.isNotEmpty));

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = Theme.of(context).scaffoldBackgroundColor;

    return Container(
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(16.0),
          topRight: Radius.circular(16.0),
        ),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isDark
              ? [
                  const Color(0xFF2C1018),
                  const Color(0xFF1A0A0F),
                  bgColor,
                ]
              : [
                  const Color(0xFFFCE4EC),
                  const Color(0xFFF8BBD0).withValues(alpha: 0.3),
                  bgColor,
                ],
          stops: const [0.0, 0.35, 0.7],
        ),
      ),
      child: MediaQuery.removePadding(
        context: context,
        removeTop: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Container(
                  margin: const EdgeInsets.only(top: 3.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Container(
                        width: 32,
                        height: 4,
                        decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                            borderRadius: const BorderRadius.all(Radius.circular(12.0))),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 17.0),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              // Keyless transitionBuilder lets AnimatedSwitcher's internal
              // _childNumber counter ensure unique keys, preventing duplicate
              // key errors during rapid A -> B -> A station switches.
              transitionBuilder: (Widget child, Animation<double> animation) {
                return FadeTransition(opacity: animation, child: child);
              },
              child: Text(
                currentStation?.displayTitle ?? "",
                key: ValueKey('title-${currentStation?.id}'),
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 20,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 18.0),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              transitionBuilder: (Widget child, Animation<double> animation) {
                return FadeTransition(opacity: animation, child: child);
              },
              child: Container(
                key: ValueKey('thumb-${currentStation?.id}-${currentStation?.songId}'),
                width: 260.0,
                height: 260.0,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: const BorderRadius.all(Radius.circular(8)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.grey.withOpacity(0.35),
                      spreadRadius: 0,
                      blurRadius: 4,
                      offset: const Offset(2, 3),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: const BorderRadius.all(Radius.circular(8)),
                  child: currentStation?.displayThumbnail(
                    cacheWidth: (260 * MediaQuery.devicePixelRatioOf(context)).ceil(),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 18.0),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              transitionBuilder: (Widget child, Animation<double> animation) {
                return FadeTransition(opacity: animation, child: child);
              },
              child: Padding(
                key: ValueKey('song-${currentStation?.songTitle}-${currentStation?.id}'),
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Text(
                  currentStation?.songTitle ?? "Metadate indisponibile",
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 21,
                  ),
                ),
              ),
            ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              transitionBuilder: (Widget child, Animation<double> animation) {
                return FadeTransition(opacity: animation, child: child);
              },
              child: Text(
                currentStation?.songArtist ?? "",
                key: ValueKey('artist-${currentStation?.songArtist}-${currentStation?.id}'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            // Centered section: chips + transport controls
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Chip row: [like | dislike] ---- [share]
                  Builder(builder: (context) {
                    final songId = currentStation?.songId ?? -1;
                    final likeStatus = GetIt.instance<SongLikeService>().getLikeStatus(songId);
                    final chipBg = isDark
                        ? Colors.white.withValues(alpha: 0.12)
                        : Colors.black.withValues(alpha: 0.08);
                    final chipRadius = BorderRadius.circular(24);

                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24.0),
                      child: Row(
                        children: [
                          // Like chip
                          InkWell(
                            borderRadius: chipRadius,
                            onTap: () => _showReviewModal(context, initialStars: 5),
                            child: Container(
                              decoration: BoxDecoration(
                                color: chipBg,
                                borderRadius: chipRadius,
                              ),
                              padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 10.0),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    likeStatus == 1 ? Icons.thumb_up : Icons.thumb_up_outlined,
                                    size: 20,
                                    color: likeStatus == 1
                                        ? Theme.of(context).primaryColor
                                        : Theme.of(context).colorScheme.onSurface,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    'Îmi place',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: likeStatus == 1
                                          ? Theme.of(context).primaryColor
                                          : Theme.of(context).colorScheme.onSurface,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          // Dislike chip
                          InkWell(
                            borderRadius: chipRadius,
                            onTap: () => _showReviewModal(context, initialStars: 1),
                            child: Container(
                              decoration: BoxDecoration(
                                color: chipBg,
                                borderRadius: chipRadius,
                              ),
                              padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 10.0),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    likeStatus == -1 ? Icons.thumb_down : Icons.thumb_down_outlined,
                                    size: 20,
                                    color: likeStatus == -1
                                        ? Theme.of(context).primaryColor
                                        : Theme.of(context).colorScheme.onSurface,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    'Nu îmi place',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: likeStatus == -1
                                          ? Theme.of(context).primaryColor
                                          : Theme.of(context).colorScheme.onSurface,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          // Share pill
                          InkWell(
                            borderRadius: chipRadius,
                            onTap: () => _showShareDialog(context),
                            child: Container(
                              decoration: BoxDecoration(
                                color: chipBg,
                                borderRadius: chipRadius,
                              ),
                              padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 10.0),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.share_outlined,
                                    size: 20,
                                    color: Theme.of(context).colorScheme.onSurface,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    'Trimite',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: Theme.of(context).colorScheme.onSurface,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                  const SizedBox(height: 24.0),
                  // Transport controls: prev | play/pause | next
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      InkWell(
                        onTap: () {
                          _playButtonKey.currentState?.notifyWillPlay();
                          widget.audioHandler.skipToPrevious();
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(10.0),
                          child: Icon(
                            Icons.skip_previous,
                            size: 42,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                      ),
                      const SizedBox(width: 28.0),
                      AnimatedPlayButton(
                        key: _playButtonKey,
                        playbackStateStream: widget.audioHandler.playbackState,
                        iconSize: 54,
                        iconColor: Theme.of(context).colorScheme.onPrimary,
                        backgroundColor: Theme.of(context).bottomAppBarTheme.color,
                        onPlay: widget.audioHandler.play,
                        onPause: widget.audioHandler.pause,
                        onStop: widget.audioHandler.stop,
                      ),
                      const SizedBox(width: 28.0),
                      InkWell(
                        onTap: () {
                          _playButtonKey.currentState?.notifyWillPlay();
                          widget.audioHandler.skipToNext();
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(10.0),
                          child: Icon(
                            Icons.skip_next_rounded,
                            size: 42,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8.0),
            // Bottom row: favorit, recent, somn, youtube
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: <Widget>[
                InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => _likeButtonKey.currentState?.onTap(),
                  child: Container(
                    padding: const EdgeInsets.all(10.0),
                    child: Column(
                      children: [
                        IgnorePointer(
                          child: LikeButton(
                            key: _likeButtonKey,
                            size: 30,
                            bubblesSize: 30,
                            isLiked: currentStation != null && _favoriteSlugs.contains(currentStation!.slug),
                            likeBuilder: (bool isLiked) {
                              return Icon(
                                isLiked ? Icons.favorite_sharp : Icons.favorite_border_sharp,
                                color: isLiked
                                    ? Theme.of(context).primaryColor
                                    : Theme.of(context).colorScheme.onSurface,
                                size: 23,
                              );
                            },
                            onTap: (bool isLiked) async {
                              if (currentStation != null) {
                                widget.audioHandler.setStationIsFavorite(currentStation!, !isLiked);
                              }
                              return !isLiked;
                            },
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 8.0),
                          child: Text('favorit', style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          )),
                        ),
                      ],
                    ),
                  ),
                ),
                _buildActionButton(
                  context,
                  icon: Icons.history,
                  label: 'recent',
                  onTap: () {
                    if (currentStation != null) {
                      SongHistoryModal.show(
                        context,
                        stationSlug: currentStation!.slug,
                        stationTitle: currentStation!.title,
                        stationThumbnailUrl: currentStation!.thumbnailUrl,
                      );
                    }
                  },
                ),
                _buildActionButton(
                  context,
                  icon: Icons.nights_stay_sharp,
                  label: 'somn',
                  isActive: isTimerActive,
                  onTap: () => showSleepTimerDialog(context),
                ),
                _buildActionButton(
                  context,
                  icon: Icons.video_collection,
                  label: 'youtube',
                  isEnabled: hasYoutubeLink,
                  onTap: () async {
                    if (!hasYoutubeLink || currentStation == null) return;
                    final query = "${currentStation?.songArtist} - ${currentStation?.songTitle}";
                    final encodedQuery = Uri.encodeQueryComponent(query);
                    final searchUrl = 'https://www.youtube.com/results?q=$encodedQuery';
                    await launchUrl(Uri.parse(searchUrl), mode: LaunchMode.externalApplication);
                  },
                ),
              ],
            ),
            const SizedBox(height: 40.0),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButton(
    BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool isActive = false,
    bool isEnabled = true,
  }) {
    final color = !isEnabled
        ? Theme.of(context).disabledColor
        : isActive
            ? Theme.of(context).primaryColor
            : Theme.of(context).colorScheme.onSurface;
    final labelColor = !isEnabled
        ? Theme.of(context).disabledColor
        : isActive
            ? Theme.of(context).primaryColor
            : Theme.of(context).colorScheme.onSurfaceVariant;

    return InkWell(
      customBorder: const CircleBorder(),
      onTap: isEnabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.all(10.0),
        child: Column(
          children: [
            Icon(icon, color: color, size: 24),
            Padding(
              padding: const EdgeInsets.only(top: 8.0),
              child: Text(label, style: TextStyle(fontSize: 12, color: labelColor)),
            ),
          ],
        ),
      ),
    );
  }

  void _showReviewModal(BuildContext context, {required int initialStars}) async {
    if (currentStation == null) return;
    final songId = currentStation!.songId;
    final likeService = GetIt.instance<SongLikeService>();
    final currentStatus = likeService.getLikeStatus(songId);
    // Check if this tap is removing an existing like/dislike
    final isRemoving = (initialStars >= 4 && currentStatus == 1) ||
        (initialStars < 4 && currentStatus == -1);
    // Toggle the like/dislike status
    if (initialStars >= 4) {
      await widget.audioHandler.customAction('likeSong');
    } else {
      await widget.audioHandler.customAction('dislikeSong');
    }
    if (mounted) setState(() {});
    // Only show review modal when adding, not when removing
    if (isRemoving) return;
    if (!context.mounted) return;
    ReviewModal.show(
      context,
      stationId: currentStation!.id,
      stationTitle: currentStation!.title,
      songId: currentStation!.songId,
      songTitle: currentStation!.songTitle,
      songArtist: currentStation!.songArtist,
      initialStars: initialStars,
    );
  }

  void _showShareDialog(BuildContext context) {
    final slug = currentStation?.slug;
    final shareUrl = slug != null && slug.isNotEmpty
        ? 'https://www.radiocrestin.ro/$slug'
        : 'https://www.radiocrestin.ro/descarca-aplicatia-radio-crestin';

    ShareHandler.shareApp(
      context: context,
      shareUrl: shareUrl,
      shareMessage: 'Instalează și tu aplicația Radio Creștin și ascultă peste 60 de stații de radio creștin:\n$shareUrl',
      stationName: currentStation?.title,
      songName: currentStation?.songTitle,
      songArtist: currentStation?.songArtist,
      songId: currentStation?.songId,
      showDialog: true,
      shareLinkLoader: () async {
        final prefs = await SharedPreferences.getInstance();
        final deviceId = prefs.getString('device_id');
        if (deviceId == null) return null;
        final shareService = ShareService(widget.audioHandler.graphqlClient);
        return shareService.getShareLink(deviceId);
      },
    );
  }

  Future<void> showSleepTimerDialog(BuildContext context) async {
    if (Platform.isIOS) {
      // Cupertino dialog for iOS
      return showCupertinoModalPopup<void>(
        context: context,
        builder: (BuildContext context) {
          return CupertinoActionSheet(
            title: const Text(
              'Programare închidere',
              style: TextStyle(fontSize: 18),
            ),
            actions: <Widget>[
              for (var minutes in [5, 10, 15, 30, 60])
                CupertinoActionSheetAction(
                  child: Text('$minutes minute'),
                  onPressed: () => setSleepTimer(context, Duration(minutes: minutes)),
                ),
              if (isTimerActive)
                CupertinoActionSheetAction(
                  child: const Text('Anulează închiderea'),
                  onPressed: cancelSleepTimer,
                ),
            ],
            cancelButton: CupertinoActionSheetAction(
              child: const Text('Renunță'),
              onPressed: () => Navigator.of(context).pop(),
            ),
          );
        },
      );
    } else {
      // Material dialog for Android and other platforms
      return showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (BuildContext context) {
          return AlertDialog(
            title: const Text(
              'Oprește radioul după:',
              style: TextStyle(fontSize: 18),
            ),
            backgroundColor: Theme.of(context).colorScheme.surface,
            content: SingleChildScrollView(
              child: Column(
                children: [5, 10, 15, 30, 60]
                    .map((minutes) => ListTile(
                          title: Text('$minutes minute'),
                          onTap: () => setSleepTimer(context, Duration(minutes: minutes)),
                        ))
                    .toList()
                  ..addAll(
                    isTimerActive
                        ? [
                            ListTile(
                              title: const Text('Anulează închiderea'),
                              onTap: cancelSleepTimer,
                            ),
                          ]
                        : [],
                  ),
              ),
            ),
            actions: <Widget>[
              TextButton(
                child: const Text('Renunță'),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          );
        },
      );
    }
  }

  void setSleepTimer(BuildContext context, Duration duration) {
    Navigator.of(context).pop();
    Fluttertoast.showToast(
        msg: "Radioul se va opri după ${duration.inMinutes} minute",
        toastLength: Toast.LENGTH_SHORT,
        gravity: ToastGravity.BOTTOM,
        timeInSecForIosWeb: 1,
        backgroundColor: AppColors.primaryDark,
        textColor: Colors.white,
        fontSize: 14.0);

    setState(() {
      isTimerActive = true;
    });

    sleepTimer = Timer(duration, () {
      widget.audioHandler.stop();
      sleepTimer = null;
      if (mounted) {
        setState(() {
          isTimerActive = false;
        });
      }
    });
  }

  void cancelSleepTimer() {
    if (sleepTimer != null) {
      sleepTimer!.cancel();
      sleepTimer = null;
      setState(() {
        isTimerActive = false;
      });
      Fluttertoast.showToast(
          msg: "Programarea închiderii a fost anulată",
          toastLength: Toast.LENGTH_SHORT,
          gravity: ToastGravity.BOTTOM,
          timeInSecForIosWeb: 1,
          backgroundColor: AppColors.primaryDark,
          textColor: Colors.white,
          fontSize: 14.0);
    }
    Navigator.of(context).pop();
  }
}
