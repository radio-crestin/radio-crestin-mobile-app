import 'package:uuid/uuid.dart';

/// Represents an action button on an Android Auto list item row.
class AAListItemAction {
  final String title;
  final String? iconName;
  final Function()? onPress;

  AAListItemAction({
    required this.title,
    this.iconName,
    this.onPress,
  });

  Map<String, dynamic> toJson() => {
        'title': title,
        'iconName': iconName,
        'onPress': onPress != null ? true : false,
      };
}

class AAListItem {
  /// Unique id of the object.
  final String _elementId;

  final String title;
  final String? subtitle;
  final String? imageUrl;
  final Function(Function() complete, AAListItem self)? onPress;
  final List<AAListItemAction> actions;

  AAListItem({
    required this.title,
    this.subtitle,
    this.imageUrl,
    this.onPress,
    this.actions = const [],
  }) : _elementId = const Uuid().v4();

  String get uniqueId => _elementId;

  Map<String, dynamic> toJson() => {
        '_elementId': _elementId,
        'title': title,
        'subtitle': subtitle,
        'imageUrl': imageUrl,
        'onPress': onPress != null ? true : false,
        'actions': actions.map((a) => a.toJson()).toList(),
      };
}
