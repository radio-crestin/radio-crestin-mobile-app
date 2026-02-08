import '../grid/grid_template.dart';
import '../list/list_template.dart';
import '../template.dart';

class AATab {
  final String contentId;
  final String title;
  final AATemplate content;

  AATab({
    required this.contentId,
    required this.title,
    required this.content,
  });

  Map<String, dynamic> toJson() => {
        'contentId': contentId,
        'title': title,
        'content': content.toJson(),
        'contentRuntimeType': _getContentRuntimeType(),
      };

  String _getContentRuntimeType() {
    if (content is AAGridTemplate) return 'FAAGridTemplate';
    if (content is AAListTemplate) return 'FAAListTemplate';
    return 'FAA${content.runtimeType}';
  }
}
