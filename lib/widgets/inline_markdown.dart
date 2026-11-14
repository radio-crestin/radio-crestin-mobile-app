import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:markdown/markdown.dart' as md;

/// Short text with inline markdown only: `**bold**`, `*italic*` and
/// `[links](url)`, as an announcement card's body allows.
class InlineMarkdownText extends StatefulWidget {
  const InlineMarkdownText(
    this.data, {
    super.key,
    required this.style,
    required this.strongColor,
    required this.emphasisColor,
    required this.linkColor,
    required this.onTapLink,
    this.maxLines,
  });

  final String data;

  /// Lines shown at most; the rest ends in an ellipsis.
  final int? maxLines;
  final TextStyle style;
  final Color strongColor;
  final Color emphasisColor;
  final Color linkColor;
  final ValueChanged<String> onTapLink;

  @override
  State<InlineMarkdownText> createState() => _InlineMarkdownTextState();
}

class _InlineMarkdownTextState extends State<InlineMarkdownText> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final nodes = md.Document(encodeHtml: false)
        .parseInline(widget.data.replaceAll('\n', ' '));
    return Text.rich(
      TextSpan(children: nodes.map((node) => _span(node, null)).toList()),
      style: widget.style,
      maxLines: widget.maxLines,
      overflow: widget.maxLines == null ? null : TextOverflow.ellipsis,
    );
  }

  InlineSpan _span(md.Node node, TapGestureRecognizer? link) {
    if (node is! md.Element) {
      return TextSpan(text: node.textContent, recognizer: link);
    }
    final href = node.attributes['href'];
    final recognizer =
        node.tag == 'a' && href != null ? _linkRecognizer(href) : link;
    return TextSpan(
      style: _styleOf(node.tag),
      recognizer: recognizer,
      children: [
        for (final child in node.children ?? const <md.Node>[])
          _span(child, recognizer),
      ],
    );
  }

  TapGestureRecognizer _linkRecognizer(String href) {
    final recognizer = TapGestureRecognizer()
      ..onTap = () => widget.onTapLink(href);
    _recognizers.add(recognizer);
    return recognizer;
  }

  TextStyle? _styleOf(String tag) => switch (tag) {
        'strong' => TextStyle(
            color: widget.strongColor,
            fontWeight: FontWeight.w600,
          ),
        'em' => TextStyle(
            color: widget.emphasisColor,
            fontStyle: FontStyle.italic,
          ),
        'a' => TextStyle(
            color: widget.linkColor,
            fontWeight: FontWeight.w500,
            decoration: TextDecoration.underline,
            decorationColor: widget.linkColor,
          ),
        _ => null,
      };
}
