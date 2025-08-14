import 'dart:async';

import 'package:flutter/material.dart';
import 'package:radio_crestin/utils/vibration_pattern.dart';

enum NotificationType { network, authentication, error, networkRestored }

class NotificationBanner extends StatefulWidget {
  final VoidCallback? onDismiss;
  final NotificationType notificationType;
  final String? message;
  final IconData? icon;
  final Color? color;

  const NotificationBanner({
    Key? key,
    this.onDismiss,
    this.notificationType = NotificationType.network,
    this.message,
    this.icon,
    this.color,
  }) : super(key: key);

  const NotificationBanner.noInternet({Key? key, VoidCallback? onDismiss})
    : this(
        key: key,
        onDismiss: onDismiss,
        notificationType: NotificationType.network,
      );

  @override
  State<NotificationBanner> createState() => _NotificationBannerState();
}

class _NotificationBannerState extends State<NotificationBanner>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    duration: const Duration(milliseconds: 300),
    vsync: this,
  )..forward();
  late final _slide = Tween<Offset>(
    begin: const Offset(0, -1),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  Timer? _timer;
  bool _isDismissed = false;

  @override
  void initState() {
    super.initState();
    
    // Trigger vibration based on notification type
    if (widget.notificationType == NotificationType.networkRestored) {
      VibrationPattern.lightImpact();
    } else {
      VibrationPattern.mediumImpact();
    }
    
    final duration = widget.notificationType == NotificationType.networkRestored
        ? const Duration(seconds: 4)
        : const Duration(seconds: 8);
    _timer = Timer(duration, _dismiss);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _dismiss() async {
    if (_isDismissed) return;
    _isDismissed = true;
    _timer?.cancel();
    await _controller.reverse();
    widget.onDismiss?.call();
  }

  ({String message, IconData icon, Color color}) get _notificationConfig {
    // Use custom values if provided, otherwise fall back to defaults
    if (widget.message != null && widget.icon != null && widget.color != null) {
      return (
        message: widget.message!,
        icon: widget.icon!,
        color: widget.color!,
      );
    }

    final message = widget.message;
    final icon = widget.icon;
    final color = widget.color;

    return switch (widget.notificationType) {
      NotificationType.network => (
        message:
            message ?? 'Verifică conexiunea la internet și încearcă din nou!',
        icon: icon ?? Icons.wifi_off,
        color: color ?? const Color(0xFFD32F2F),
      ),
      NotificationType.authentication => (
        message:
            message ??
            'Sesiunea ta a expirat. Te rugăm să te autentifici din nou!',
        icon: icon ?? Icons.person_off,
        color: color ?? const Color(0xFFD32F2F),
      ),
      NotificationType.error => (
        message: message ?? 'A apărut o eroare. Dacă persistă, te rugăm să ne contactezi!',
        icon: icon ?? Icons.error_outline,
        color: color ?? const Color(0xFFD32F2F),
      ),
      NotificationType.networkRestored => (
        message: message ?? 'Conexiunea la internet a fost restabilită!',
        icon: icon ?? Icons.wifi,
        color: color ?? const Color(0xFF4CAF50),
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final config = _notificationConfig;

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Material(
        type: MaterialType.transparency,
        child: SlideTransition(
          position: _slide,
          child: SafeArea(
            child: GestureDetector(
              onPanUpdate: (d) {
                if (d.delta.dy < -5) _dismiss();
              },
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: config.color,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        config.icon,
                        color: config.color,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        config.message,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    GestureDetector(
                      onTap: _dismiss,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Text(
                          'OK',
                          style: TextStyle(
                            color: config.color,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}