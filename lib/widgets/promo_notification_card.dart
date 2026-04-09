import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:radio_crestin/services/promo_notification_service.dart';

class PromoNotificationCard extends StatelessWidget {
  final PromoNotification notification;
  final VoidCallback onDismiss;

  const PromoNotificationCard({
    super.key,
    required this.notification,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isDark
              ? [const Color(0xFF1A2332), const Color(0xFF162029)]
              : [const Color(0xFFEEF4FB), const Color(0xFFF6F9FD)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : const Color(0xFF1565C0).withValues(alpha: 0.15),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.20 : 0.06),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 42, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title
                Text(
                  notification.title,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).colorScheme.onSurface,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 10),
                // Message
                Text(
                  notification.message,
                  style: TextStyle(
                    fontSize: 13.5,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.78),
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 14),
                // Official platform badges
                Row(
                  children: [
                    _PlatformBadge(
                      iconAsset: 'assets/icons/carplay_logo.svg',
                      worksWithLabel: 'Apple CarPlay',
                    ),
                    const SizedBox(width: 10),
                    _PlatformBadge(
                      iconAsset: 'assets/icons/android_auto_logo.svg',
                      worksWithLabel: 'Android Auto',
                    ),
                  ],
                ),
              ],
            ),
          ),
          // Close X button
          Positioned(
            top: 10,
            right: 10,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onDismiss,
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.06)
                        : Colors.black.withValues(alpha: 0.04),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.close,
                    size: 16,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.45),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlatformBadge extends StatelessWidget {
  final String iconAsset;
  final String worksWithLabel;

  const _PlatformBadge({
    required this.iconAsset,
    required this.worksWithLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SvgPicture.asset(
              iconAsset,
              width: 28,
              height: 28,
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Works with',
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w400,
                  color: Color(0xFF999999),
                  height: 1.2,
                ),
              ),
              Text(
                worksWithLabel,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

