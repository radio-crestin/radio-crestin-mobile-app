import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../constants.dart';
import '../globals.dart' as globals;
import '../services/analytics_service.dart';
import '../services/announcement_actions.dart';
import '../services/announcement_copy.dart';
import '../services/announcements_service.dart';
import '../theme.dart';

/// A form (question, poll or survey) in a sheet over the app: the
/// backend's form page in a WebView, themed like the app, with a skeleton
/// until the page says it is ready.
///
/// The page talks back through the `RadioCrestinForm` channel
/// (`{type: "rc-form", event: ready|step|submitted|close|resize}`). Only
/// the API's own pages load inside; other web links open in the browser,
/// and anything else is blocked.
class AnnouncementFormSheet extends StatefulWidget {
  const AnnouncementFormSheet({
    super.key,
    required this.formSlug,
    required this.announcementSlug,
  });

  final String formSlug;
  final String announcementSlug;

  /// Opens the form [formSlug] of the announcement [announcementSlug].
  static Future<void> show(
    BuildContext context, {
    required String formSlug,
    required String announcementSlug,
  }) {
    final properties = {
      'form_slug': formSlug,
      'announcement_slug': announcementSlug,
    };
    AnalyticsService.instance.capture('form_opened', properties);
    final colors = Theme.of(context).announcementColors;
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: colors.sheet,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      clipBehavior: Clip.antiAlias,
      builder: (_) => AnnouncementFormSheet(
        formSlug: formSlug,
        announcementSlug: announcementSlug,
      ),
    ).whenComplete(
        () => AnalyticsService.instance.capture('form_closed', properties));
  }

  @override
  State<AnnouncementFormSheet> createState() => _AnnouncementFormSheetState();
}

class _AnnouncementFormSheetState extends State<AnnouncementFormSheet> {
  WebViewController? _controller;
  bool _ready = false;
  bool _failed = false;
  Timer? _readyFallback;

  /// When the page loaded but never said "ready" (an older page), it
  /// shows anyway after this.
  static const _readyGrace = Duration(milliseconds: 1500);

  Uri get _apiOrigin => Uri.parse(CONSTANTS.API_BASE_URL);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller ??= _createController();
  }

  @override
  void dispose() {
    _readyFallback?.cancel();
    super.dispose();
  }

  WebViewController _createController() {
    final colors = Theme.of(context).announcementColors;
    return WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(colors.sheet)
      ..addJavaScriptChannel('RadioCrestinForm',
          onMessageReceived: (message) => _onMessage(message.message))
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: _onNavigation,
        onPageFinished: (_) =>
            _readyFallback ??= Timer(_readyGrace, () => _show()),
        onWebResourceError: (error) {
          if (error.isForMainFrame ?? true) setState(() => _failed = true);
        },
      ))
      ..loadRequest(_pageUri(colors.isDark));
  }

  /// The form page, themed, with the device in the fragment so the page
  /// stays the same (and cacheable) for everyone.
  Uri _pageUri(bool dark) {
    final page = Uri.parse(
      '${CONSTANTS.API_BASE_URL}/forms/'
      '${Uri.encodeComponent(widget.formSlug)}/page/',
    ).replace(queryParameters: {'theme': dark ? 'dark' : 'light'});
    final device = {
      'device_id': globals.deviceId,
      'platform': AnnouncementsService.platform,
      'app_version': globals.appVersion,
      'locale': ui.PlatformDispatcher.instance.locale.toLanguageTag(),
    };
    return page.replace(fragment: Uri(queryParameters: device).query);
  }

  /// Keeps the API's own pages inside; opens other web links outside.
  NavigationDecision _onNavigation(NavigationRequest request) {
    final uri = Uri.tryParse(request.url);
    if (uri == null) return NavigationDecision.prevent;
    final origin = _apiOrigin;
    final sameOrigin = uri.scheme == origin.scheme &&
        uri.host == origin.host &&
        uri.port == origin.port;
    if (sameOrigin && (uri.scheme == 'https' || _isLocalTest(uri))) {
      return NavigationDecision.navigate;
    }
    if (AnnouncementActions.safeLink(request.url) != null) {
      unawaited(AnnouncementActions.openLink(
          request.url, LaunchMode.externalApplication));
    }
    return NavigationDecision.prevent;
  }

  /// The e2e tests' fake API, served over http on the device's loopback.
  static bool _isLocalTest(Uri uri) =>
      uri.scheme == 'http' && uri.host == '127.0.0.1';

  void _onMessage(String raw) {
    final Object? message;
    try {
      message = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (message is! Map || message['type'] != 'rc-form') return;
    final properties = {
      'form_slug': widget.formSlug,
      'announcement_slug': widget.announcementSlug,
      if (message['step'] != null) 'step': message['step'],
    };
    switch (message['event']) {
      case 'ready':
        _show();
      case 'step':
        AnalyticsService.instance.capture('form_step', properties);
      case 'submitted':
        AnalyticsService.instance.capture('form_submitted', properties);
      case 'close':
        if (mounted) Navigator.of(context).maybePop();
    }
  }

  void _show() {
    _readyFallback?.cancel();
    if (mounted && !_ready) setState(() => _ready = true);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).announcementColors;
    final controller = _controller!;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.92,
      child: Column(
        children: [
          _SheetTop(onClose: () => Navigator.of(context).maybePop()),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(child: WebViewWidget(controller: controller)),
                if (_failed)
                  Positioned.fill(child: _FailedForm(colors: colors))
                else if (!_ready)
                  Positioned.fill(
                    child: _FormSkeleton(
                      key: const ValueKey('form-skeleton'),
                      colors: colors,
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

/// The drag handle, and the close button on the right.
class _SheetTop extends StatelessWidget {
  const _SheetTop({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).announcementColors;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return SizedBox(
      height: 52,
      child: Stack(
        children: [
          Align(
            alignment: Alignment.topCenter,
            child: Container(
              margin: const EdgeInsets.only(top: 8),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: onSurface.withValues(alpha: 0.22),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Positioned(
            right: 10,
            top: 8,
            child: Tooltip(
              message: AnnouncementCopy.close,
              child: Material(
                color: colors.backButton,
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: onClose,
                  child: SizedBox.square(
                    dimension: 36,
                    child:
                        Icon(Icons.close_rounded, size: 18, color: onSurface),
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

/// Grey blocks where the form comes, on the sheet's own color, so the
/// WebView never flashes white while it loads.
class _FormSkeleton extends StatelessWidget {
  const _FormSkeleton({super.key, required this.colors});

  final AnnouncementColors colors;

  @override
  Widget build(BuildContext context) {
    final block = colors.text.withValues(alpha: 0.08);
    Widget bar(double widthFactor, double height) => Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: FractionallySizedBox(
            widthFactor: widthFactor,
            alignment: Alignment.centerLeft,
            child: Container(
              height: height,
              decoration: BoxDecoration(
                color: block,
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        );
    return ColoredBox(
      color: colors.sheet,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            bar(0.7, 22),
            bar(0.45, 14),
            const SizedBox(height: 10),
            for (var i = 0; i < 4; i++) bar(1, 52),
          ],
        ),
      ),
    );
  }
}

/// What shows when the form page could not load.
class _FailedForm extends StatelessWidget {
  const _FailedForm({required this.colors});

  final AnnouncementColors colors;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: colors.sheet,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.link_off_rounded, size: 32, color: colors.muted),
              const SizedBox(height: 12),
              Text(
                AnnouncementCopy.linkFailed,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: colors.text,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                AnnouncementCopy.linkFailedHint,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13.5, color: colors.muted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
