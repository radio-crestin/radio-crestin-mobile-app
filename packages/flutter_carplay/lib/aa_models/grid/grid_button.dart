import 'package:uuid/uuid.dart';

class AAGridButton {
  final String _elementId;

  final String title;
  final String? imageUrl;
  final Function()? onPress;

  AAGridButton({
    required this.title,
    this.imageUrl,
    this.onPress,
  }) : _elementId = const Uuid().v4();

  String get uniqueId => _elementId;

  Map<String, dynamic> toJson() => {
        '_elementId': _elementId,
        'title': title,
        'imageUrl': imageUrl,
        'onPress': onPress != null ? true : false,
      };
}
