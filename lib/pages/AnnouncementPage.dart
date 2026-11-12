import 'dart:async';

import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:get_it/get_it.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/announcement.dart';
import '../services/announcement_actions.dart';
import '../services/announcement_copy.dart';
import '../services/announcements_service.dart';
import '../theme.dart';
import '../widgets/announcement_card.dart';
import '../widgets/announcement_icons.dart';
import '../widgets/retrying_network_image.dart';

/// An announcement's own page: a cover, its title and date, and full
/// markdown, with its button pinned at the bottom (the design's
/// `.mdpage`).
class AnnouncementPage extends StatefulWidget {
  const AnnouncementPage({super.key, required this.item});

  final Announcement item;

  static Route<void> route(Announcement item) => MaterialPageRoute<void>(
        settings: const RouteSettings(name: '/announcement'),
        builder: (_) => AnnouncementPage(item: item),
      );

  @override
  State<AnnouncementPage> createState() => _AnnouncementPageState();
}

class _AnnouncementPageState extends State<AnnouncementPage> {
  AnnouncementsService get _service => GetIt.instance<AnnouncementsService>();

  @override
  void initState() {
    super.initState();
    _service.report(AnnouncementEvent.pageViewed, widget.item, 0);
  }

  /// The button pinned under the page: the main one, unless it is the one
  /// that opened this page; then the second one, when it has an action.
  ({AnnouncementButton button, AnnouncementEvent event})? get _cta {
    final item = widget.item;
    final main = item.button;
    if (main != null && main.action.type != AnnouncementActionType.page) {
      return (button: main, event: AnnouncementEvent.clicked);
    }
    final second = item.secondaryButton;
    final action = second?.action;
    if (second == null ||
        action == null ||
        action.type == AnnouncementActionType.page) {
      return null;
    }
    return (
      button: AnnouncementButton(
        label: second.label,
        style: AnnouncementButtonStyle.filled,
        color: item.color,
        textColor: readableOn(item.color),
        icon: 'auto',
        action: action,
      ),
      event: AnnouncementEvent.secondaryClicked,
    );
  }

  void _onCta(AnnouncementButton button, AnnouncementEvent event) {
    _service.report(event, widget.item, 0);
    unawaited(AnnouncementActions.run(widget.item, button.action));
  }

  @override
  Widget build(BuildContext context) {
    final cta = _cta;
    final background = Theme.of(context).scaffoldBackgroundColor;
    return Scaffold(
      backgroundColor: background,
      body: Stack(
        children: [
          Column(
            children: [
              const _TopBar(),
              Expanded(
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                    20,
                    0,
                    20,
                    cta == null
                        ? 32 + MediaQuery.paddingOf(context).bottom
                        : 110 + MediaQuery.paddingOf(context).bottom,
                  ),
                  child: _Content(item: widget.item),
                ),
              ),
            ],
          ),
          if (cta != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _StickyButton(
                button: cta.button,
                background: background,
                onTap: () => _onCta(cta.button, cta.event),
              ),
            ),
        ],
      ),
    );
  }
}

/// The back arrow, in a bar that stays while the page scrolls.
class _TopBar extends StatelessWidget {
  const _TopBar();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).announcementColors;
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      padding:
          EdgeInsets.fromLTRB(12, MediaQuery.paddingOf(context).top + 8, 12, 8),
      alignment: Alignment.centerLeft,
      child: Tooltip(
        message: AnnouncementCopy.back,
        child: Material(
          color: colors.backButton,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => Navigator.of(context).maybePop(),
            child: SizedBox.square(
              dimension: 36,
              child: Icon(
                Icons.arrow_back_rounded,
                size: 20,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The cover, tag, title, date and markdown.
class _Content extends StatelessWidget {
  const _Content({required this.item});

  final Announcement item;

  @override
  Widget build(BuildContext context) {
    final page = item.page;
    final cover = page?.coverImageUrl;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final startsAt = item.startsAt;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (cover != null) _Cover(url: cover, color: item.category.color),
        if (item.category.name.isNotEmpty) ...[
          AnnouncementTag(category: item.category),
          const SizedBox(height: 8),
        ],
        Text(
          page?.title ?? item.title,
          style: TextStyle(
            fontSize: 25,
            height: 1.18,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.25,
            color: onSurface,
          ),
        ),
        const SizedBox(height: 6),
        if (startsAt != null)
          Text(
            AnnouncementCopy.publishedOn(startsAt),
            style: TextStyle(
              fontSize: 12.5,
              color: onSurface.withValues(alpha: 0.6),
            ),
          ),
        const SizedBox(height: 16),
        _Markdown(
          data: page?.markdown ?? item.bodyMarkdown,
          accent: item.category.color,
        ),
      ],
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover({required this.url, required this.color});

  final String url;
  final Color color;

  @override
  Widget build(BuildContext context) {
    Widget placeholder(BuildContext context) =>
        ColoredBox(color: color.withValues(alpha: 0.18));
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 18),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          height: 170,
          width: double.infinity,
          child: RetryingNetworkImage(
            url: url,
            cache: true,
            loading: placeholder,
            failed: placeholder,
          ),
        ),
      ),
    );
  }
}

/// The page's markdown: headings, lists, quotes, images and links.
class _Markdown extends StatelessWidget {
  const _Markdown({required this.data, required this.accent});

  final String data;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.announcementColors;
    final onSurface = theme.colorScheme.onSurface;
    final body = TextStyle(fontSize: 15, height: 1.6, color: onSurface);
    return MarkdownBody(
      data: data,
      // Quotes and pictures as wide as the text column, as on the website.
      fitContent: false,
      onTapLink: (text, href, title) => _openLink(href),
      imageBuilder: (uri, title, alt) =>
          _MarkdownImage(uri: uri, caption: title ?? alt),
      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
        p: body,
        listBullet: body,
        strong: const TextStyle(fontWeight: FontWeight.w700),
        a: TextStyle(color: colors.inkOf(accent)),
        h1: body.copyWith(
            fontSize: 20, height: 1.3, fontWeight: FontWeight.w700),
        h1Padding: const EdgeInsets.only(top: 22),
        h2: body.copyWith(
            fontSize: 17, height: 1.35, fontWeight: FontWeight.w700),
        h2Padding: const EdgeInsets.only(top: 22),
        h3: body.copyWith(fontSize: 15.5, fontWeight: FontWeight.w700),
        h3Padding: const EdgeInsets.only(top: 16),
        blockSpacing: 10,
        listIndent: 18,
        blockquote: body.copyWith(fontStyle: FontStyle.italic),
        blockquotePadding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        blockquoteDecoration: BoxDecoration(
          color: accent.withValues(alpha: 0.10),
          border: Border(left: BorderSide(color: accent, width: 3)),
        ),
        horizontalRuleDecoration: BoxDecoration(
          border: Border(top: BorderSide(color: colors.border)),
        ),
      ),
    );
  }

  static void _openLink(String? href) {
    final uri = href == null ? null : Uri.tryParse(href);
    if (uri != null) {
      unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));
    }
  }
}

/// A picture in the markdown, as wide as the text, with its caption.
class _MarkdownImage extends StatelessWidget {
  const _MarkdownImage({required this.uri, required this.caption});

  final Uri uri;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final caption = this.caption;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: ExtendedImage.network(
              uri.toString(),
              cache: true,
              width: double.infinity,
              fit: BoxFit.fitWidth,
              loadStateChanged: (state) =>
                  switch (state.extendedImageLoadState) {
                LoadState.completed => null,
                _ => Container(
                    height: 130,
                    color: onSurface.withValues(alpha: 0.06),
                  ),
              },
            ),
          ),
          if (caption != null && caption.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              caption,
              style: TextStyle(
                fontSize: 12.5,
                color: onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The button pinned at the bottom, over a fade of the page.
class _StickyButton extends StatelessWidget {
  const _StickyButton({
    required this.button,
    required this.background,
    required this.onTap,
  });

  final AnnouncementButton button;
  final Color background;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final icon = announcementButtonIcon(button);
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: const [0, 0.35],
          colors: [background.withValues(alpha: 0), background],
        ),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            20, 14, 20, bottomInset > 0 ? bottomInset + 8 : 26),
        child: Material(
          color: button.color,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: const ValueKey('announcement-page-button'),
            onTap: onTap,
            child: SizedBox(
              height: 48,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (icon != null) ...[
                    Icon(
                      icon,
                      size: 18 * announcementIconScale(icon),
                      color: button.textColor,
                    ),
                    const SizedBox(width: 8),
                  ],
                  Flexible(
                    child: Text(
                      button.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: button.textColor,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
