import 'package:flutter_carplay/aa_models/tab/tab_template.dart';
import 'package:flutter_carplay/aa_models/template.dart';
import 'package:flutter_carplay/flutter_carplay.dart';

class FlutterAutoAndroidHelper {
  const FlutterAutoAndroidHelper();

  AAListItem? findAAListItem({
    required List<AATemplate> templates,
    required String elementId,
  }) {
    for (var t in templates) {
      final List<AAListTemplate> listTemplates = [];

      if (t is AAListTemplate) {
        listTemplates.add(t);
      } else if (t is AATabTemplate) {
        for (var tab in t.tabs) {
          if (tab.content is AAListTemplate) {
            listTemplates.add(tab.content as AAListTemplate);
          }
        }
      }

      for (var list in listTemplates) {
        for (var section in list.sections) {
          for (var item in section.items) {
            if (item.uniqueId == elementId) {
              return item;
            }
          }
        }
      }
    }
    return null;
  }

  AAGridButton? findAAGridButton({
    required List<AATemplate> templates,
    required String elementId,
  }) {
    for (var t in templates) {
      if (t is AAGridTemplate) {
        for (var button in t.buttons) {
          if (button.uniqueId == elementId) {
            return button;
          }
        }
      } else if (t is AATabTemplate) {
        for (var tab in t.tabs) {
          if (tab.content is AAGridTemplate) {
            for (var button in (tab.content as AAGridTemplate).buttons) {
              if (button.uniqueId == elementId) {
                return button;
              }
            }
          }
        }
      }
    }
    return null;
  }

  String makeFAAChannelId({String event = ''}) =>
      'com.oguzhnatly.flutter_android_auto$event';
}
