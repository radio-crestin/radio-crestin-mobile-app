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
    // Set focus on the text form field when the dialog is opened
    Future.delayed(const Duration(milliseconds: 100), () {
      FocusScope.of(context).requestFocus(_focusNode);
    });
    searchResults = widget.stationsMediaItems;
  }

  void _filterSearchResults(String query) {
    setState(() {
      searchResults = widget.stationsMediaItems.where((item) {
        // Use a case-insensitive comparison for search
        return item.title.toLowerCase().contains(query.toLowerCase());
      }).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      surfaceTintColor: Colors.transparent,
      backgroundColor: Colors.white, // Set the background color to white
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8.0),
      ),
      child: SingleChildScrollView(
        child: Container(
          padding: const EdgeInsets.only(top: 6.0, left: 8.0, right: 2.0, bottom: 8.0),
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
                  Container(
                    margin: const EdgeInsets.only(top: 8, right: 0),
                    child: CloseButton(
                      color: Colors.grey[800],
                      onPressed: () {
                        Navigator.of(context).pop();
                      },
                    ),
                  )
                ],
              ),
              const SizedBox(height: 16.0), // Spacing
              // List of results
              ListView.builder(
                physics: const NeverScrollableScrollPhysics(),
                shrinkWrap: true,
                itemCount: searchResults.length, // Replace with your actual data count
                itemBuilder: (context, index) {
                  final item = searchResults[index];

                  return GestureDetector(
                    onTap: () {
                      widget.audioHandler.playMediaItem(item);
                      Navigator.of(context).pop();
                    },
                    child: ListTile(
                      title: Text(searchResults[index].title),
                      // Add more content or customize as needed
                    ),
                  );
                },
              ),
            ],
          ),
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
