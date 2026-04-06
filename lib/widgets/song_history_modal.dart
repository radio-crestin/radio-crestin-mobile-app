import 'dart:async';

import 'package:flutter/material.dart';
import 'package:radio_crestin/seek_mode_manager.dart';
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
        _scrollController.position.maxScrollExtent - 200) {
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
    final query = item.artistName != null && item.artistName!.isNotEmpty
        ? '${item.songName} ${item.artistName}'
        : item.songName ?? '';
    final encoded = Uri.encodeQueryComponent(query);
    final url = 'https://www.youtube.com/results?search_query=$encoded';
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        children: [
          _buildHeader(theme),
          Expanded(child: _buildBody(theme)),
        ],
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Drag handle
          Center(
            child: Container(
              margin: const EdgeInsets.only(bottom: 8),
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.onSurfaceVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          // Title row
          Row(
            children: [
              Expanded(
                child: Text(
                  'Melodii redate recent',
                  style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // Station name + buffer delay indicator + filter toolbar
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        widget.stationTitle,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (SeekModeManager.currentOffset != Duration.zero)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.primary.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '-${SeekModeManager.currentOffset.inMinutes} min',
                            style: TextStyle(
                              fontSize: 11,
                              color: AppColors.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (_filterDate != null)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: ActionChip(
                    label: Text(
                      _formatFilterLabel(),
                      style: const TextStyle(fontSize: 12),
                    ),
                    onPressed: _clearFilter,
                    avatar: const Icon(Icons.close, size: 14),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              TextButton.icon(
                onPressed: _showDateFilterDialog,
                icon: const Icon(Icons.calendar_month, size: 16),
                label: const Text('Filtrează', style: TextStyle(fontSize: 13)),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
              ),
            ],
          ),
          const Divider(height: 1),
        ],
      ),
    );
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

  Widget _buildBody(ThemeData theme) {
    if (_isLoading) {
      return _buildSkeletonList(theme);
    }

    if (_history.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'Niciun istoric disponibil pentru această stație.',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final grouped = SongHistoryService.groupByDateAndHour(_history);

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.only(bottom: 32),
      itemCount: grouped.length + 1, // +1 for loading indicator
      itemBuilder: (context, index) {
        if (index == grouped.length) {
          return _buildFooter(theme);
        }
        return _buildDateGroup(theme, grouped[index]);
      },
    );
  }

  Widget _buildDateGroup(ThemeData theme, HistoryDateGroup dateGroup) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Date header
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.5),
          child: Text(
            dateGroup.dateLabel,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ),
        ...dateGroup.hours.map((hourGroup) => _buildHourGroup(theme, hourGroup)),
      ],
    );
  }

  Widget _buildHourGroup(ThemeData theme, HistoryHourGroup hourGroup) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            hourGroup.hourLabel,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        ...hourGroup.songs.map((item) => _buildSongItem(theme, item)),
      ],
    );
  }

  Widget _buildSongItem(ThemeData theme, SongHistoryItem item) {
    final time = item.dateTime.toLocal();
    final timeStr = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

    return InkWell(
      onTap: item.hasSong ? () => _openYouTubeSearch(item) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: [
            // Thumbnail
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 48,
                height: 48,
                child: _buildThumbnail(item),
              ),
            ),
            const SizedBox(width: 12),
            // Song info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.songName ?? 'Necunoscut',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (item.artistName != null && item.artistName!.isNotEmpty)
                    Text(
                      item.artistName!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  Text(
                    timeStr,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant.withOpacity(0.7),
                    ),
                  ),
                ],
              ),
            ),
            // YouTube icon
            if (item.hasSong)
              Icon(
                Icons.play_circle_outline,
                size: 20,
                color: theme.colorScheme.onSurfaceVariant,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildThumbnail(SongHistoryItem item) {
    final url = item.songThumbnailUrl ?? widget.stationThumbnailUrl;
    if (url != null && url.isNotEmpty) {
      return Image.network(
        url,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _defaultThumbnail(),
      );
    }
    return _defaultThumbnail();
  }

  Widget _defaultThumbnail() {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(
        Icons.music_note,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        size: 24,
      ),
    );
  }

  Widget _buildFooter(ThemeData theme) {
    if (_isLoadingMore) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
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
        padding: const EdgeInsets.all(16),
        child: Center(
          child: Text(
            'Nu mai sunt melodii de afișat.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _buildSkeletonList(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: List.generate(12, (index) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      height: 14,
                      width: 120.0 + (index % 3) * 40,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      height: 12,
                      width: 80.0 + (index % 4) * 20,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      height: 10,
                      width: 36,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      }),
    );
  }
}
