import 'package:uuid/uuid.dart';

/// A titled row of pictures pinned at the top of a list (iOS 26+).
///
/// CarPlay draws the pictures as rounded squares with a title under each,
/// in a grid that wraps onto more lines when [allowsMultipleLines] is true.
/// Ignored before iOS 26.
class CPImageRow {
  /// Unique id of the object.
  final String _elementId = const Uuid().v4();

  /// Text shown above the pictures.
  final String title;

  /// The pictures, in display order.
  final List<CPImageRowElement> elements;

  /// Whether the pictures may wrap onto more lines; otherwise CarPlay shows
  /// only those that fit on one.
  final bool allowsMultipleLines;

  /// Fired after the user taps [title]; null leaves the title inert.
  final Function()? onTitlePress;

  CPImageRow({
    required this.title,
    required this.elements,
    this.allowsMultipleLines = true,
    this.onTitlePress,
  });

  Map<String, dynamic> toJson() => {
        '_elementId': _elementId,
        'title': title,
        'elements': elements.map((e) => e.toJson()).toList(),
        'allowsMultipleLines': allowsMultipleLines,
        'onTitlePress': onTitlePress != null,
      };

  String get uniqueId => _elementId;
}

/// One picture of a [CPImageRow], with its title under it.
class CPImageRowElement {
  /// Unique id of the object.
  final String _elementId = const Uuid().v4();

  /// Text shown under the picture.
  final String title;

  /// The picture, in the formats `CPGridButton.image` takes: an asset path,
  /// a `file://` path, an `http(s)` URL or an SF Symbol as `sf:<name>`.
  final String image;

  /// Fired after the user taps the picture.
  final Function() onPress;

  CPImageRowElement({
    required this.title,
    required this.image,
    required this.onPress,
  });

  Map<String, dynamic> toJson() => {
        '_elementId': _elementId,
        'title': title,
        'image': image,
      };

  String get uniqueId => _elementId;
}
