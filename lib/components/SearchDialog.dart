import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import '../appAudioHandler.dart';

class SearchDialog extends StatefulWidget {
  final List<MediaItem> stationsMediaItems;
  final AppAudioHandler audioHandler;

  SearchDialog({required this.stationsMediaItems, required this.audioHandler});

  @override
  _SearchDialogState createState() => _SearchDialogState();
}

class _SearchDialogState extends State<SearchDialog> {
  List<MediaItem> searchResults = [];
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 100), () {
      FocusScope.of(context).requestFocus(_focusNode);
    });
    searchResults = widget.stationsMediaItems;
  }

  void _filterSearchResults(String query) {
    setState(() {
      searchResults = widget.stationsMediaItems.where((item) {
        return item.title.toLowerCase().contains(query.toLowerCase());
      }).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      surfaceTintColor: Colors.transparent,
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8.0),
      ),
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    focusNode: _focusNode,
                    onChanged: _filterSearchResults,
                    decoration: const InputDecoration(
                      hintText: 'Tastează numele stației..',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 8.0),
                    ),
                  ),
                ),
                CloseButton(
                  color: Colors.grey[800],
                  onPressed: () => Navigator.of(context).pop(),
                )
              ],
            ),
            const SizedBox(height: 16.0),
            Flexible(
              child: searchResults.isEmpty
                  ? Center(child: Text('Nu am găsit nicio stație cu acest nume.'))
                  : ListView.builder(
                      itemCount: searchResults.length,
                      itemBuilder: (context, index) {
                        final item = searchResults[index];
                        return GestureDetector(
                          onTap: () {
                            widget.audioHandler.playMediaItem(item);
                            Navigator.of(context).pop();
                          },
                          child: ListTile(
                            title: Text(item.title),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }
}
