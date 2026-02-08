import 'package:uuid/uuid.dart';

import '../template.dart';
import 'tab.dart';

class AATabTemplate implements AATemplate {
  final String _elementId;

  final List<AATab> tabs;
  final String activeTabContentId;

  AATabTemplate({
    required this.tabs,
    required this.activeTabContentId,
  }) : _elementId = const Uuid().v4();

  @override
  String get uniqueId => _elementId;

  @override
  Map<String, dynamic> toJson() => {
        '_elementId': _elementId,
        'tabs': tabs.map((AATab tab) => tab.toJson()).toList(),
        'activeTabContentId': activeTabContentId,
      };
}
