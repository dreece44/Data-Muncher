import 'package:flutter/material.dart';

class StorageItem {
  final String name;
  final String size;
  bool selected;
  StorageItem({
    required this.name,
    required this.size,
    this.selected = false,
  });
}

class GarbageCollectionPage extends StatefulWidget {
  const GarbageCollectionPage({super.key, this.items, this.onSend});

  /// Items to list, e.g. from a storage scan. Null shows the sample items.
  final List<StorageItem>? items;

  /// Moves the chosen items to the garbage bin. Sent items leave the list.
  /// Returns a message to show instead of the usual one, e.g. when some
  /// files couldn't be moved; null keeps the usual message.
  final Future<String?> Function(List<StorageItem> selected)? onSend;

  @override
  State<GarbageCollectionPage> createState() => _GarbageCollectionPageState();
}

class _GarbageCollectionPageState extends State<GarbageCollectionPage> {
  late final List<StorageItem> items = widget.items != null ? List.of(widget.items!) : [
    StorageItem(
      name: 'Temporary Files',
      size: '42 GB',
      selected: true,
    ),
    StorageItem(
      name: 'Duplicate Files',
      size: '38 GB',
      selected: true,
    ),
    StorageItem(
      name: 'Old Downloads',
      size: '27 GB',
      selected: false,
    ),
    StorageItem(
      name: 'Cache Files',
      size: '15 GB',
      selected: true, 
    ),
  ];

  @override
  Widget build(BuildContext context){
    final  selectedItems = items.where((item) => item.selected).toList();
    return Scaffold(
      appBar: AppBar(title: const Text("Garbage Collection")),

      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Detected Storage Items",
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(height: 8),
            const Text(
              "Select the items you want to send to the garbage bin.",
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 25),

            Expanded(
              child: ListView.builder(
                itemCount: items.length,
                itemBuilder: (context, index){
                  final item = items[index];
                  return Card(
                    child: CheckboxListTile(
                      value: item.selected,
                      onChanged: (value){
                        setState((){
                          item.selected = value ?? false;
                        });
                      },
                      title: Text(item.name,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      subtitle: Text(
                        item.size,
                      ),

                      secondary: const Icon(
                        Icons.delete_outline,
                      ),

                    ),
                  );
                },
              ),
            ),

            //---------------------------------
            //Selected summary
            //---------------------------------
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),

                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      "${selectedItems.length} items selected",
                      style: const TextStyle(
                        fontWeight:FontWeight.bold,
                      ),
                    ),

                    Text(
                      _totalSize(selectedItems),
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],

                
                ),
              ),
            ),

            const SizedBox(height: 15),

            //-------------------------------
            //Garbage Button
            //-------------------------------
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: selectedItems.isEmpty ? null : (){
                  _showConfirmationDialog(context, selectedItems);
                },
                icon: const Icon(Icons.delete),
                label: const Text("Send selected items to garbage bin"),

                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.all(16),
                ),
              ),
            ),
            

          ],
        ),
      ),
    );


  }

  //---------------------------------
  //Confirmation dialog
  //---------------------------------
  void _showConfirmationDialog(
    BuildContext context,
    List<StorageItem> selectedItems,
  ){
    showDialog(
      context: context,
      builder: (context){
        return AlertDialog(
          title: const Text("Send to Garbage Bin?"),
          content: Text(
            "${selectedItems.length} selected items will be sent to the garbage bin. Are you sure you want to continue?",
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
              },
              child: const Text(
                "Cancel",
              ),
            ),

            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);

                _sendToGarbageBin(selectedItems);
              },

              child: const Text(
                "Continue?",
              ),
            ),
          ],


        );
      },
    );
  }
  //---------------------------------
  //Garbage Collection
  //---------------------------------
  Future<void> _sendToGarbageBin(List<StorageItem> selectedItems) async {
    //This is where your garbage collection/ file-system
    //will eventually go.
    final onSend = widget.onSend;
    final message = onSend == null ? null : await onSend(selectedItems);
    if (!mounted) return;

  setState((){
    for(final item in selectedItems){
      item.selected = false;
    }
    if (onSend != null) items.removeWhere(selectedItems.contains);
  });
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message ?? "Selected items sent to the garbage bin."),
    ),
  );
 }

  //---------------------------------
  //Selected total, from sizes like "42 GB" or "1.5 MB"
  //---------------------------------
  static String _totalSize(List<StorageItem> selectedItems) {
    const units = {'B': 1.0, 'KB': 1e3, 'MB': 1e6, 'GB': 1e9, 'TB': 1e12};
    var bytes = 0.0;
    for (final item in selectedItems) {
      final parts = item.size.trim().split(RegExp(r'\s+'));
      final value = double.tryParse(parts.first) ?? 0;
      bytes += value * (units[parts.length > 1 ? parts[1].toUpperCase() : 'B'] ?? 1);
    }
    for (final unit in ['TB', 'GB', 'MB', 'KB']) {
      final size = units[unit]!;
      if (bytes >= size) {
        final value = bytes / size;
        return '${value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toStringAsFixed(1)} $unit';
      }
    }
    return '${bytes.round()} B';
  }
}
