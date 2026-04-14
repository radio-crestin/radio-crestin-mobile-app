import 'dart:async';

import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';

import '../appAudioHandler.dart';
import '../types/Station.dart';
import 'tv_theme.dart';
import 'pages/tv_home_page.dart';
import 'pages/tv_favorites_page.dart';
import 'pages/tv_recent_page.dart';
import 'pages/tv_settings_page.dart';
import 'pages/tv_now_playing_page.dart';
import 'widgets/tv_mini_player.dart';

/// TV app shell with left navigation drawer and mini player.
class TvShell extends StatefulWidget {
  const TvShell({super.key});

  @override
  State<TvShell> createState() => _TvShellState();
}

class _TvShellState extends State<TvShell> {
  int _selectedIndex = 0;
  bool _drawerExpanded = false;
  bool _showNowPlaying = false;

  late final AppAudioHandler _audioHandler;
  final List<StreamSubscription> _subscriptions = [];

  Station? _currentStation;

  static const navItems = [
    _NavItem(icon: Icons.home_rounded, label: 'Acasă'),
    _NavItem(icon: Icons.favorite_rounded, label: 'Favorite'),
    _NavItem(icon: Icons.history_rounded, label: 'Recente'),
    _NavItem(icon: Icons.settings_rounded, label: 'Setări'),
  ];

  @override
  void initState() {
    super.initState();
    // Lock TV to landscape orientation
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    _audioHandler = GetIt.instance<AppAudioHandler>();

    _subscriptions.add(
      _audioHandler.currentStation.stream.listen((station) {
        if (mounted) setState(() => _currentStation = station);
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

  void _onNavItemSelected(int index) {
    setState(() {
      _selectedIndex = index;
      _drawerExpanded = false;
    });
  }

  void _openNowPlaying() {
    if (_currentStation != null) {
      setState(() => _showNowPlaying = true);
    }
  }

  void _closeNowPlaying() {
    setState(() => _showNowPlaying = false);
  }

  Widget _buildPage() {
    if (_showNowPlaying) {
      return TvNowPlayingPage(onBack: _closeNowPlaying);
    }
    switch (_selectedIndex) {
      case 0:
        return TvHomePage(onOpenNowPlaying: _openNowPlaying);
      case 1:
        return TvFavoritesPage(onOpenNowPlaying: _openNowPlaying);
      case 2:
        return TvRecentPage(onOpenNowPlaying: _openNowPlaying);
      case 3:
        return const TvSettingsPage();
      default:
        return TvHomePage(onOpenNowPlaying: _openNowPlaying);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DpadNavigator(
      enabled: true,
      child: Scaffold(
        backgroundColor: TvColors.background,
        body: Row(
          children: [
            // Navigation rail
            _TvNavRail(
              selectedIndex: _selectedIndex,
              expanded: _drawerExpanded,
              onItemSelected: _onNavItemSelected,
              onExpandToggle: () {
                setState(() => _drawerExpanded = !_drawerExpanded);
              },
            ),
            // Page content
            Expanded(
              child: Column(
                children: [
                  Expanded(child: _buildPage()),
                  // Mini player at bottom
                  if (_currentStation != null && !_showNowPlaying)
                    TvMiniPlayer(onTap: _openNowPlaying),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavItem {
  final IconData icon;
  final String label;
  const _NavItem({required this.icon, required this.label});
}

/// Left navigation rail with collapsed (icon) and expanded (icon + label) states.
class _TvNavRail extends StatelessWidget {
  final int selectedIndex;
  final bool expanded;
  final ValueChanged<int> onItemSelected;
  final VoidCallback onExpandToggle;

  const _TvNavRail({
    required this.selectedIndex,
    required this.expanded,
    required this.onItemSelected,
    required this.onExpandToggle,
  });

  @override
  Widget build(BuildContext context) {
    final width = expanded
        ? TvSpacing.drawerExpandedWidth
        : TvSpacing.drawerCollapsedWidth;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      width: width,
      color: TvColors.surface,
      child: Column(
        children: [
          const SizedBox(height: TvSpacing.lg),
          // App logo / expand button
          DpadFocusable(
            autofocus: false,
            onSelect: onExpandToggle,
            builder: FocusEffects.border(
              focusColor: TvColors.focusBorder,
              width: 2,
              borderRadius: BorderRadius.circular(TvSpacing.radiusSm),
            ),
            child: Padding(
              padding: const EdgeInsets.all(TvSpacing.sm),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    expanded ? Icons.menu_open_rounded : Icons.menu_rounded,
                    color: TvColors.textPrimary,
                    size: 28,
                  ),
                  if (expanded) ...[
                    const SizedBox(width: TvSpacing.sm),
                    Expanded(
                      child: Text(
                        'Radio Crestin',
                        style: TvTypography.title.copyWith(fontSize: 16),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: TvSpacing.md),
          const Divider(color: TvColors.divider, height: 1),
          const SizedBox(height: TvSpacing.sm),
          // Navigation items
          ...List.generate(_TvShellState.navItems.length, (index) {
            final item = _TvShellState.navItems[index];
            final isSelected = index == selectedIndex;
            return _TvNavItem(
              icon: item.icon,
              label: item.label,
              isSelected: isSelected,
              expanded: expanded,
              autofocus: index == 0 && selectedIndex == 0,
              onTap: () => onItemSelected(index),
            );
          }),
        ],
      ),
    );
  }
}

class _TvNavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isSelected;
  final bool expanded;
  final bool autofocus;
  final VoidCallback onTap;

  const _TvNavItem({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.expanded,
    required this.autofocus,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: TvSpacing.xs,
        vertical: 2,
      ),
      child: DpadFocusable(
        autofocus: autofocus,
        onSelect: onTap,
        builder: FocusEffects.border(
          focusColor: TvColors.focusBorder,
          width: 2,
          borderRadius: BorderRadius.circular(TvSpacing.radiusSm),
        ),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            color: isSelected
                ? TvColors.primary.withValues(alpha: 0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(TvSpacing.radiusSm),
          ),
          padding: const EdgeInsets.symmetric(
            vertical: TvSpacing.sm + 2,
            horizontal: TvSpacing.sm,
          ),
          child: Row(
            mainAxisAlignment: expanded
                ? MainAxisAlignment.start
                : MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                color: isSelected ? TvColors.primary : TvColors.textSecondary,
                size: 24,
              ),
              if (expanded) ...[
                const SizedBox(width: TvSpacing.md),
                Text(
                  label,
                  style: TvTypography.label.copyWith(
                    color: isSelected
                        ? TvColors.primary
                        : TvColors.textSecondary,
                    fontWeight:
                        isSelected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
