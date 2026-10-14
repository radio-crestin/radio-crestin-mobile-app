import 'package:flutter_carplay/flutter_carplay.dart';
import 'package:flutter_carplay/models/template.dart';

class FlutterCarplayHelper {
  CPListItem? findCPListItem({
    required List<dynamic> templates,
    required String elementId,
  }) {
    CPListItem? listItem;
    l1:
    for (var t in templates) {
      final List<CPListTemplate> listTemplates = [];
      if (t is CPTabBarTemplate) {
        for (var template in t.templates) {
          if (template is CPListTemplate) {
            listTemplates.add(template);
          }
        }
      } else if (t is CPListTemplate) {
        listTemplates.add(t);
      }
      if (listTemplates.isNotEmpty) {
        for (var list in listTemplates) {
          for (var section in list.sections) {
            for (var item in section.items) {
              if (item.uniqueId == elementId) {
                listItem = item;
                break l1;
              }
            }
          }
        }
      }
    }
    return listItem;
  }

  /// Finds the grid button with [elementId] in a grid template or among the
  /// buttons pinned above a list, including the tabs of a tab bar.
  CPGridButton? findCPGridButton({
    required List<CPTemplate> templates,
    required String elementId,
  }) {
    for (final template in templates) {
      final tabs =
          template is CPTabBarTemplate ? template.templates : [template];
      for (final tab in tabs) {
        final buttons = switch (tab) {
          CPGridTemplate() => tab.buttons,
          CPListTemplate() => tab.headerGridButtons,
          _ => const <CPGridButton>[],
        };
        for (final button in buttons) {
          if (button.uniqueId == elementId) return button;
        }
      }
    }
    return null;
  }

  /// Finds the row of pictures with [elementId] above a list, including the
  /// tabs of a tab bar.
  CPImageRow? findCPImageRow({
    required List<CPTemplate> templates,
    required String elementId,
  }) {
    for (final row in _headerImageRows(templates)) {
      if (row.uniqueId == elementId) return row;
    }
    return null;
  }

  /// Finds the picture with [elementId] in a row of pictures above a list.
  CPImageRowElement? findCPImageRowElement({
    required List<CPTemplate> templates,
    required String elementId,
  }) {
    for (final row in _headerImageRows(templates)) {
      for (final element in row.elements) {
        if (element.uniqueId == elementId) return element;
      }
    }
    return null;
  }

  Iterable<CPImageRow> _headerImageRows(List<CPTemplate> templates) sync* {
    for (final template in templates) {
      final tabs =
          template is CPTabBarTemplate ? template.templates : [template];
      for (final tab in tabs) {
        if (tab is CPListTemplate) {
          if (tab.headerImageRow case final row?) yield row;
        }
      }
    }
  }

  String makeFCPChannelId({String? event = ''}) =>
      'com.oguzhnatly.flutter_carplay${event!}';
}
