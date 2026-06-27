import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../globals.dart' as globals;
import '../tv_theme.dart';
import '../widgets/desktop_focusable.dart';

/// TV settings / about page.
///
/// TVs can't run WhatsApp, so contact happens through a **QR code**: scanning it
/// with a phone opens WhatsApp prefilled with the device id and app version —
/// exactly like the mobile "Contact" action (see [quick_actions_service]). Also
/// shows the app version and device id. BACK closes it.
class TvSettings extends StatelessWidget {
  final VoidCallback onClose;
  const TvSettings({super.key, required this.onClose});

  static const _whatsappNumber = '40766338046';

  /// The same wa.me URL the mobile app builds, encoded into the QR.
  String get _whatsappUrl {
    final info =
        '[RadioCrestin/Android TV/v${globals.appVersion}/${globals.deviceId}]';
    final message = '$info\n\nBuna ziua,\n';
    return 'https://wa.me/$_whatsappNumber?text=${Uri.encodeComponent(message)}';
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) onClose();
      },
      child: ColoredBox(
        color: TvColors.background,
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.all(TvSpacing.marginHorizontal),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _BackButton(onClose: onClose),
                    const SizedBox(width: 16),
                    const Text(
                      'Setări',
                      style: TextStyle(
                        color: TvColors.textPrimary,
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        flex: 6,
                        child: _ContactCard(qrData: _whatsappUrl),
                      ),
                      const SizedBox(width: 24),
                      const Expanded(flex: 4, child: _InfoPanel()),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BackButton extends StatelessWidget {
  final VoidCallback onClose;
  const _BackButton({required this.onClose});

  @override
  Widget build(BuildContext context) {
    return DesktopFocusable(
      autofocus: true,
      region: 'settings',
      isEntryPoint: true,
      onSelect: onClose,
      builder: (context, isFocused, child) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: isFocused ? TvColors.primary : TvColors.surfaceVariant,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isFocused ? TvColors.primary : Colors.transparent,
              width: 2,
            ),
          ),
          child: child,
        );
      },
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.arrow_back_rounded, color: TvColors.textPrimary, size: 22),
          SizedBox(width: 8),
          Text(
            'Înapoi',
            style: TextStyle(
              color: TvColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _ContactCard extends StatelessWidget {
  final String qrData;
  const _ContactCard({required this.qrData});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: TvColors.surfaceVariant,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          // QR must sit on white for reliable scanning.
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
            ),
            child: QrImageView(
              data: qrData,
              version: QrVersions.auto,
              size: 196,
              backgroundColor: Colors.white,
              gapless: true,
            ),
          ),
          const SizedBox(width: 24),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.chat_rounded,
                        color: Color(0xFF25D366), size: 26),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Contactează-ne pe WhatsApp',
                        style: TvTypography.headline.copyWith(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text(
                  'Scanează codul QR cu telefonul pentru a ne scrie direct pe '
                  'WhatsApp. Mesajul include automat versiunea aplicației.',
                  style: TextStyle(
                    color: TvColors.textTertiary,
                    fontSize: 15,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  '+40 766 338 046',
                  style: TextStyle(
                    color: TvColors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoPanel extends StatelessWidget {
  const _InfoPanel();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: TvColors.surfaceVariant,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Despre aplicație',
            style: TvTypography.headline
                .copyWith(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 18),
          _InfoRow(
            label: 'Versiune',
            value: '${globals.appVersion} (${globals.buildNumber})',
          ),
          const SizedBox(height: 14),
          _InfoRow(label: 'ID dispozitiv', value: globals.deviceId),
          const Spacer(),
          const Text(
            'Radio Crestin · radiocrestin.ro',
            style: TextStyle(color: TvColors.textTertiary, fontSize: 14),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: TvColors.textTertiary, fontSize: 13),
        ),
        const SizedBox(height: 3),
        Text(
          value.isEmpty ? '—' : value,
          style: const TextStyle(
            color: TvColors.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}
