import 'package:flutter/material.dart';

class SelectDialog<T> extends StatefulWidget {
  final List<T> items;
  final Function(T) displayFunction;
  final Function(T) onItemSelected;
  final Function(T)? searchFunction;
  final Widget Function(BuildContext context, T item)? itemBuilder;

  const SelectDialog({
    super.key,
    required this.items,
    required this.displayFunction,
    this.searchFunction,
    required this.onItemSelected,
    this.itemBuilder,
  });

  @override
  _SelectDialogState<T> createState() => _SelectDialogState<T>();
}

class _SelectDialogState<T> extends State<SelectDialog<T>> {
  List<T> searchResults = [];
  final FocusNode _focusNode = FocusNode();
  final TextEditingController _controller = TextEditingController();

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
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20.0),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.searchFunction != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 4, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.onSurface.withOpacity(0.06),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: TextFormField(
                        focusNode: _focusNode,
                        controller: _controller,
                        onChanged: _filterSearchResults,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface,
                          fontSize: 16,
                        ),
                        decoration: InputDecoration(
                          hintText: 'Caută o stație...',
                          hintStyle: TextStyle(
                            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.4),
                            fontSize: 16,
                          ),
                          prefixIcon: Icon(
                            Icons.search,
                            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.4),
                            size: 22,
                          ),
                          suffixIcon: _controller.text.isNotEmpty
                              ? GestureDetector(
                                  onTap: () {
                                    _controller.clear();
                                    _filterSearchResults('');
                                  },
                                  child: Icon(
                                    Icons.clear,
                                    color: Theme.of(context).colorScheme.onSurface.withOpacity(0.4),
                                    size: 20,
                                  ),
                                )
                              : null,
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(
                      Icons.close,
                      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                      size: 22,
                    ),
                    splashRadius: 20,
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Flexible(
            child: searchResults.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        'Nicio stație găsită.',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                          fontSize: 15,
                        ),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 8),
                    itemCount: searchResults.length,
                    itemBuilder: (context, index) {
                      final item = searchResults[index];
                      return InkWell(
                        onTap: () {
                          widget.onItemSelected(item);
                          Navigator.of(context).pop();
                        },
                        child: widget.itemBuilder != null
                            ? widget.itemBuilder!(context, item)
                            : ListTile(
                                title: Text(widget.displayFunction(item)),
                              ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }
}
