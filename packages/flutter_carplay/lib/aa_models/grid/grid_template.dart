import 'package:uuid/uuid.dart';

import '../template.dart';
import 'grid_button.dart';

class AAGridTemplate implements AATemplate {
  final String _elementId;

  final String title;
  final List<AAGridButton> buttons;

  AAGridTemplate({
    required this.title,
    required this.buttons,
  }) : _elementId = const Uuid().v4();

  @override
  String get uniqueId => _elementId;

  @override
  Map<String, dynamic> toJson() => {
        '_elementId': _elementId,
        'title': title,
        'buttons':
            buttons.map((AAGridButton button) => button.toJson()).toList(),
      };
}
