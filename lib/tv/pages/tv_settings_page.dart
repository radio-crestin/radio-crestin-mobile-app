import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';

import '../../globals.dart' as globals;
import '../tv_theme.dart';

/// TV Settings page with large, D-pad navigable items.
class TvSettingsPage extends StatelessWidget {
  const TvSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(TvSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Setări', style: TvTypography.displayMedium),
          const SizedBox(height: TvSpacing.xl),
          Expanded(
            child: ListView(
              children: [
                _TvSettingsSection(
                  title: 'Despre',
                  items: [
                    _TvSettingsItem(
                      icon: Icons.info_outline_rounded,
                      title: 'Versiune',
                      subtitle: '${globals.appVersion} (${globals.buildNumber})',
                      autofocus: true,
                    ),
                    const _TvSettingsItem(
                      icon: Icons.tv_rounded,
                      title: 'Platformă',
                      subtitle: 'Android TV',
                    ),
                    const _TvSettingsItem(
                      icon: Icons.radio_rounded,
                      title: 'Radio Crestin',
                      subtitle: 'Ascultă radiouri creștine din România',
                    ),
                  ],
                ),
                const SizedBox(height: TvSpacing.xl),
                const _TvSettingsSection(
                  title: 'Audio',
                  items: [
                    _TvSettingsItem(
                      icon: Icons.headphones_rounded,
                      title: 'Calitate Audio',
                      subtitle: 'Automată (bazată pe conexiune)',
                    ),
                  ],
                ),
                const SizedBox(height: TvSpacing.xl),
                const _TvSettingsSection(
                  title: 'Legal',
                  items: [
                    _TvSettingsItem(
                      icon: Icons.description_outlined,
                      title: 'Termeni și Condiții',
                      subtitle: 'radiocrestin.ro/terms',
                    ),
                    _TvSettingsItem(
                      icon: Icons.privacy_tip_outlined,
                      title: 'Politica de Confidențialitate',
                      subtitle: 'radiocrestin.ro/privacy',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TvSettingsSection extends StatelessWidget {
  final String title;
  final List<_TvSettingsItem> items;

  const _TvSettingsSection({
    required this.title,
    required this.items,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: TvTypography.headline),
        const SizedBox(height: TvSpacing.md),
        ...items,
      ],
    );
  }
}

class _TvSettingsItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool autofocus;

  const _TvSettingsItem({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: TvSpacing.sm),
      child: DpadFocusable(
        autofocus: autofocus,
        builder: FocusEffects.border(
          focusColor: TvColors.focusBorder,
          width: 2,
          borderRadius: BorderRadius.circular(TvSpacing.radiusMd),
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: TvSpacing.md,
            vertical: TvSpacing.md,
          ),
          decoration: BoxDecoration(
            color: TvColors.surfaceVariant,
            borderRadius: BorderRadius.circular(TvSpacing.radiusMd),
          ),
          child: Row(
            children: [
              Icon(icon, color: TvColors.textSecondary, size: 28),
              const SizedBox(width: TvSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TvTypography.title.copyWith(fontSize: 18),
                    ),
                    const SizedBox(height: 2),
                    Text(subtitle, style: TvTypography.body),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
