import 'package:flutter/material.dart';

class SelectDialog<T> extends StatefulWidget {
  final List<T> items;
  final Function(T) displayFunction;
  final Function(T) onItemSelected;
  final Function(T)? searchFunction;

  const SelectDialog({
    super.key, // Corrected the super keyword
    required this.items,
    required this.displayFunction,
    this.searchFunction,
    required this.onItemSelected,
  });

  @override
  _SelectDialogState<T> createState() => _SelectDialogState<T>();
}

class _SelectDialogState<T> extends State<SelectDialog<T>> {
  List<T> searchResults = [];
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 100), () {
      FocusScope.of(context).requestFocus(_focusNode);
    });
    searchResults = widget.items;
  }

  void _filterSearchResults(String query) {
    setState(() {
      searchResults = widget.items.where((item) {
        return widget.searchFunction!(item).toLowerCase().contains(query.toLowerCase());
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
            if (widget.searchFunction != null) // Conditionally show search bar
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      focusNode: _focusNode,
                      onChanged: _filterSearchResults,
                      decoration: const InputDecoration(
                        hintText: 'Type to search...',
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
                  ? const Center(child: Text('No results found.'))
                  : ListView.builder(
                itemCount: searchResults.length,
                itemBuilder: (context, index) {
                  final item = searchResults[index];
                  return GestureDetector(
                    onTap: () {
                      widget.onItemSelected(item);
                      Navigator.of(context).pop();
                    },
                    child: ListTile(
                      title: Text(widget.displayFunction(item)),
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
