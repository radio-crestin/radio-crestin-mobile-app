import 'dart:async';

import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:radio_crestin/seek_mode_manager.dart';
import 'package:radio_crestin/services/analytics_service.dart';
import 'package:radio_crestin/services/song_history_service.dart';
import 'package:radio_crestin/theme.dart';
import 'package:url_launcher/url_launcher.dart';

/// Full-screen modal showing song history for a station.
/// Features: grouped by date/hour, date filter, infinite scroll (1-hour pages).
class SongHistoryModal extends StatefulWidget {
  final String stationSlug;
  final String stationTitle;
  final String? stationThumbnailUrl;

  const SongHistoryModal({
    super.key,
    required this.stationSlug,
    required this.stationTitle,
    this.stationThumbnailUrl,
  });

  static Future<void> show(
    BuildContext context, {
    required String stationSlug,
    required String stationTitle,
    String? stationThumbnailUrl,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => SongHistoryModal(
        stationSlug: stationSlug,
        stationTitle: stationTitle,
        stationThumbnailUrl: stationThumbnailUrl,
      ),
    );
  }

  @override
  State<SongHistoryModal> createState() => _SongHistoryModalState();
}

class _SongHistoryModalState extends State<SongHistoryModal> {
  final ScrollController _scrollController = ScrollController();
  List<SongHistoryItem> _history = [];
  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  int? _oldestTimestamp;

  // Date filter state
  DateTime? _filterDate;
  TimeOfDay? _filterTime;

  static const _pageSize = 3600; // 1 hour in seconds

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadInitial();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 300) {
      _loadMore();
    }
  }

  Future<void> _loadInitial({int? targetTimestamp}) async {
    setState(() {
      _isLoading = true;
      _history = [];
      _hasMore = true;
      _oldestTimestamp = null;
    });

    final nowUnix = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // When buffer delay is active (2 or 5 min), show history relative to
    // what the user is actually hearing (offset time), not live time.
    final offset = SeekModeManager.currentOffset;
    final effectiveNow = nowUnix - offset.inSeconds;
    final ts = targetTimestamp ?? effectiveNow;
    // Align to hour ceiling, cap at now
    final aligned = [((ts / 3600).ceil() * 3600), nowUnix].reduce((a, b) => a < b ? a : b);

    final data = await SongHistoryService.fetchHistory(
      widget.stationSlug,
      toTimestamp: aligned,
    );

    if (!mounted) return;

    final items = data?.history ?? [];
    final fromTs = data?.fromTimestamp;

    if (fromTs != null) {
      // Preload 3 hours in parallel
      final results = await Future.wait([
        SongHistoryService.fetchHistory(widget.stationSlug, fromTimestamp: fromTs - _pageSize, toTimestamp: fromTs),
        SongHistoryService.fetchHistory(widget.stationSlug, fromTimestamp: fromTs - _pageSize * 2, toTimestamp: fromTs - _pageSize),
        SongHistoryService.fetchHistory(widget.stationSlug, fromTimestamp: fromTs - _pageSize * 3, toTimestamp: fromTs - _pageSize * 2),
      ]);

      if (!mounted) return;

      final allItems = <SongHistoryItem>[
        ...items,
        ...results.expand((r) => r?.history ?? <SongHistoryItem>[]),
      ];
      _deduplicateAndSet(allItems, fromTs - _pageSize * 3);
    } else {
      setState(() {
        _history = items;
        _hasMore = items.isNotEmpty;
        _isLoading = false;
      });
    }
  }

  void _deduplicateAndSet(List<SongHistoryItem> allItems, int oldestTs) {
    final seen = <String>{};
    final deduped = <SongHistoryItem>[];
    for (final item in allItems) {
      if (seen.add(item.timestamp)) {
        deduped.add(item);
      }
    }
    setState(() {
      _history = deduped;
      _oldestTimestamp = oldestTs;
      _hasMore = deduped.isNotEmpty;
      _isLoading = false;
    });
  }

  Future<void> _loadMore() async {
    if (_oldestTimestamp == null || _isLoadingMore || !_hasMore) return;
    _isLoadingMore = true;

    final from = _oldestTimestamp! - _pageSize;
    final data = await SongHistoryService.fetchHistory(
      widget.stationSlug,
      fromTimestamp: from,
      toTimestamp: _oldestTimestamp,
    );

    if (!mounted) return;

    final items = data?.history ?? [];
    if (items.isEmpty) {
      setState(() {
        _hasMore = false;
        _isLoadingMore = false;
      });
    } else {
      final existing = _history.map((s) => s.timestamp).toSet();
      final fresh = items.where((s) => !existing.contains(s.timestamp)).toList();
      setState(() {
        _history = [..._history, ...fresh];
        _oldestTimestamp = from;
        _isLoadingMore = false;
      });
    }
  }

  Future<void> _onFilterApply(DateTime date, TimeOfDay? time) async {
    final targetDate = DateTime(
      date.year,
      date.month,
      date.day,
      time?.hour ?? 23,
      time?.minute ?? 59,
    );
    setState(() {
      _filterDate = date;
      _filterTime = time;
    });
    await _loadInitial(targetTimestamp: targetDate.millisecondsSinceEpoch ~/ 1000);
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
  }

  Future<void> _clearFilter() async {
    setState(() {
      _filterDate = null;
      _filterTime = null;
    });
    await _loadInitial();
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
  }

  void _showDateFilterDialog() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _filterDate ?? now,
      firstDate: DateTime(2020),
      lastDate: now,
      helpText: 'Alege o dată',
      cancelText: 'Anulează',
      confirmText: 'Continuă',
    );
    if (picked == null || !mounted) return;

    TimeOfDay? pickedTime;
    if (mounted) {
      pickedTime = await showTimePicker(
        context: context,
        initialTime: _filterTime ?? const TimeOfDay(hour: 23, minute: 59),
        helpText: 'Alege ora (opțional)',
        cancelText: 'Sari peste',
        confirmText: 'Aplică',
      );
    }

    if (mounted) {
      _onFilterApply(picked, pickedTime);
    }
  }

  void _openYouTubeSearch(SongHistoryItem item) async {
    AnalyticsService.instance.capture('button_clicked', {'button_name': 'song_history_youtube', 'station_slug': widget.stationSlug, 'song_name': item.songName});
    final query = item.artistName != null && item.artistName!.isNotEmpty
        ? '${item.songName} ${item.artistName}'
        : item.songName ?? '';
    final encoded = Uri.encodeQueryComponent(query);
    final url = 'https://www.youtube.com/results?search_query=$encoded';
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  String _formatFilterLabel() {
    if (_filterDate == null) return '';
    final d = _filterDate!;
    final dateStr = '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
    if (_filterTime != null) {
      return '$dateStr ${_filterTime!.hour.toString().padLeft(2, '0')}:${_filterTime!.minute.toString().padLeft(2, '0')}';
    }
    return dateStr;
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          _buildHeader(theme, isDark),
          Expanded(child: _buildBody(theme, isDark)),
        ],
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, bool isDark) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Drag handle
        Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 6),
          child: Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: isDark ? Colors.white24 : Colors.black12,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        // Title row
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Melodii redate recent',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontSize: 20,
                  ),
                ),
              ),
              IconButton(
                icon: Icon(Icons.close, size: 22, color: theme.colorScheme.onSurfaceVariant),
                onPressed: () => Navigator.of(context).pop(),
                style: IconButton.styleFrom(
                  padding: const EdgeInsets.all(8),
                  minimumSize: const Size(36, 36),
                ),
              ),
            ],
          ),
        ),
        // Filter toolbar
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 2, 12, 0),
          child: Row(
            children: [
              if (_filterDate != null) ...[
                _FilterChip(
                  label: _formatFilterLabel(),
                  onRemove: _clearFilter,
                ),
                const SizedBox(width: 8),
              ],
              const Spacer(),
              _FilterButton(
                onPressed: _showDateFilterDialog,
                isDark: isDark,
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Divider(height: 1, thickness: 0.5, color: isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.06)),
      ],
    );
  }

  Widget _buildBody(ThemeData theme, bool isDark) {
    if (_isLoading) {
      return _buildSkeletonList(theme, isDark);
    }

    if (_history.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 48),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.music_off_rounded,
                size: 48,
                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
              ),
              const SizedBox(height: 16),
              Text(
                'Niciun istoric disponibil\npentru această stație.',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.4,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    final grouped = SongHistoryService.groupByDateAndHour(_history);

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.only(bottom: 40),
      itemCount: grouped.length + 1, // +1 for loading indicator
      itemBuilder: (context, index) {
        if (index == grouped.length) {
          return _buildFooter(theme);
        }
        return _buildDateGroup(theme, isDark, grouped[index]);
      },
    );
  }

  Widget _buildDateGroup(ThemeData theme, bool isDark, HistoryDateGroup dateGroup) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Sticky date header
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          decoration: BoxDecoration(
            color: isDark
                ? Colors.white.withValues(alpha: 0.04)
                : Colors.black.withValues(alpha: 0.03),
          ),
          child: Text(
            dateGroup.dateLabel,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              fontSize: 13,
              letterSpacing: 0.3,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ),
        ...dateGroup.hours.map((hourGroup) => _buildHourGroup(theme, isDark, hourGroup)),
      ],
    );
  }

  Widget _buildHourGroup(ThemeData theme, bool isDark, HistoryHourGroup hourGroup) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
          child: Text(
            hourGroup.hourLabel,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white38 : Colors.black38,
              letterSpacing: 0.2,
            ),
          ),
        ),
        ...hourGroup.songs.map((item) => _buildSongItem(theme, isDark, item)),
        const SizedBox(height: 4),
      ],
    );
  }

  Widget _buildSongItem(ThemeData theme, bool isDark, SongHistoryItem item) {
    final time = item.dateTime.toLocal();
    final timeStr = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: item.hasSong ? () => _openYouTubeSearch(item) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: Row(
            children: [
              // Thumbnail
              _SongThumbnail(
                songThumbnailUrl: item.songThumbnailUrl,
                fallbackUrl: widget.stationThumbnailUrl,
                isDark: isDark,
              ),
              const SizedBox(width: 14),
              // Song info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.songName ?? 'Necunoscut',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        fontSize: 15.5,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 3),
                    if (item.artistName != null && item.artistName!.isNotEmpty)
                      Text(
                        item.artistName!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          color: isDark ? Colors.white54 : Colors.black54,
                          height: 1.3,
                        ),
                      ),
                    const SizedBox(height: 3),
                    Text(
                      timeStr,
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? Colors.white30 : Colors.black26,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              // YouTube icon
              if (item.hasSong)
                Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: FaIcon(
                    FontAwesomeIcons.youtube,
                    size: 20,
                    color: isDark ? Colors.white30 : Colors.black26,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFooter(ThemeData theme) {
    if (_isLoadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: AppColors.primary,
            ),
          ),
        ),
      );
    }
    if (!_hasMore && _history.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text(
            'Nu mai sunt melodii de afișat.',
            style: TextStyle(
              fontSize: 13,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _buildSkeletonList(ThemeData theme, bool isDark) {
    final shimmerBase = isDark ? Colors.white.withValues(alpha: 0.06) : Colors.black.withValues(alpha: 0.05);
    final shimmerHighlight = isDark ? Colors.white.withValues(alpha: 0.1) : Colors.black.withValues(alpha: 0.08);

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      physics: const NeverScrollableScrollPhysics(),
      children: [
        // Fake date header
        Container(
          height: 14,
          width: 60,
          margin: const EdgeInsets.only(bottom: 16, top: 4),
          decoration: BoxDecoration(
            color: shimmerBase,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        // Fake hour label
        Container(
          height: 12,
          width: 100,
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: shimmerBase,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        ...List.generate(10, (index) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Row(
              children: [
                // Thumbnail skeleton
                Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    color: index.isEven ? shimmerBase : shimmerHighlight,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        height: 14,
                        width: 100.0 + (index % 3) * 50,
                        decoration: BoxDecoration(
                          color: index.isEven ? shimmerHighlight : shimmerBase,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        height: 12,
                        width: 70.0 + (index % 4) * 25,
                        decoration: BoxDecoration(
                          color: shimmerBase,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      const SizedBox(height: 5),
                      Container(
                        height: 10,
                        width: 34,
                        decoration: BoxDecoration(
                          color: shimmerBase,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ],
                  ),
                ),
                // YouTube icon skeleton
                Container(
                  width: 18,
                  height: 18,
                  margin: const EdgeInsets.only(left: 12),
                  decoration: BoxDecoration(
                    color: shimmerBase,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Extracted widgets
// ---------------------------------------------------------------------------

class _SongThumbnail extends StatelessWidget {
  final String? songThumbnailUrl;
  final String? fallbackUrl;
  final bool isDark;

  const _SongThumbnail({
    this.songThumbnailUrl,
    this.fallbackUrl,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final url = songThumbnailUrl ?? fallbackUrl;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 60,
        height: 60,
        child: url != null && url.isNotEmpty
            ? Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _placeholder(),
              )
            : _placeholder(),
      ),
    );
  }

  Widget _placeholder() {
    return Container(
      color: isDark ? Colors.white.withValues(alpha: 0.06) : Colors.black.withValues(alpha: 0.05),
      child: Icon(
        Icons.music_note_rounded,
        color: isDark ? Colors.white24 : Colors.black26,
        size: 22,
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final VoidCallback onRemove;

  const _FilterChip({required this.label, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.primary.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onRemove,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.close_rounded, size: 14, color: AppColors.primary),
            ],
          ),
        ),
      ),
    );
  }
}

class _FilterButton extends StatelessWidget {
  final VoidCallback onPressed;
  final bool isDark;

  const _FilterButton({required this.onPressed, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: isDark ? Colors.white.withValues(alpha: 0.06) : Colors.black.withValues(alpha: 0.05),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.calendar_month_rounded,
                size: 15,
                color: isDark ? Colors.white60 : Colors.black54,
              ),
              const SizedBox(width: 6),
              Text(
                'Filtrează',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: isDark ? Colors.white60 : Colors.black54,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
