import 'package:flutter/material.dart';

void main() {
  runApp(const StorageScanApp());

}

class StorageScanApp extends StatelessWidget{
  const StorageScanApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Storage Scan Results',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const StorageResultsPage(),
    );
  }
}

class ScanResults{
  final String status;
  final String totalStorage;
  final String usedStorage;
  final String freeStorage;
  final String wastedStorage;
  final double usedPercent;

  final Map<String, String> reclaimable;

  final int filesScanned;
  final int directoriesScanned;

  ScanResults({
    required this.status,
    required this.totalStorage,
    required this.usedStorage,
    required this.freeStorage,
    required this.wastedStorage,
    required this.usedPercent,
    required this.reclaimable,
    required this.filesScanned,
    required this.directoriesScanned,
  });

}

//---------------------------------------------
// Results page
//---------------------------------------------

class StorageResultsPage extends StatelessWidget {
  const StorageResultsPage({super.key, this.scanResults, this.onReview, this.onExport});

  /// Real scan output from the app. Null shows the sample data below.
  final ScanResults? scanResults;

  /// Opens the swipe review of what the scan suggests removing (PB-20).
  /// The button is disabled when null.
  final VoidCallback? onReview;

  /// Saves the results somewhere the user picks. Disabled when null.
  final VoidCallback? onExport;

  // Sample data so the layout can be previewed. Replace with real scan output.
  ScanResults get results {
    if (scanResults != null) return scanResults!;
    return ScanResults(
      status: "Complete",
      totalStorage: "128 GB",
      usedStorage: "96.4 GB",
      freeStorage: "31.6 GB",
      wastedStorage: "8.7 GB",
      usedPercent: 0.75,

      reclaimable: {
        "Temporary Files": "1.2 GB",
        "Duplicate Files": "3.4 GB",
        "Old Downloads": "2.6 GB",
        "Cache Files": "1.5 GB",
      },

      filesScanned: 48213,
      directoriesScanned: 3127,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scan = results;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Storage Scan Results'),

      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,

          children: [
            //---------------------------------------------
            // Header Section
            //---------------------------------------------

            const Text(
              "Storage Scan Results",
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(height: 8),

            Row(
              children: [
                const Icon(
                  Icons.check_circle,
                  color: Colors.green
                ),

                const SizedBox(width: 8),
                Text(
                  "Scan ${scan.status}",
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

// Wasted Digital Space Notification, or the all-clear when nothing was found
if (scan.reclaimable.isEmpty)
  Card(
    color: Colors.green.shade50,
    child: const Padding(
      padding: EdgeInsets.all(16.0),
      child: Row(
        children: [
          Icon(Icons.check_circle_outline, color: Colors.green, size: 36),
          SizedBox(width: 15),
          Expanded(
            child: Text(
              "No wasted space found",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.green),
            ),
          ),
        ],
      ),
    ),
  )
else
Card(
  color: Colors.orange.shade50,
  child: Padding(
    padding: const EdgeInsets.all(16.0),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(
          Icons.warning_amber_rounded,
          color: Colors.deepOrange,
          size: 36,
        ),
        const SizedBox(width: 15),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "Wasted Digital Space Detected",
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.deepOrange,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                "${scan.wastedStorage} of storage may be wasted.",
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 5),
              const Text(
                "Review the scan results to identify "
                "unnecessary files and potentially "
                "reclaimable storage space.",
                style: TextStyle(fontSize: 14),
              ),
            ],
          ),
        ),
      ],
    ),
  ),
),
            const SizedBox(height: 30),

            //---------------------------------------------
            //STORAGE SUMMARY SECTION
            //---------------------------------------------

            const Text(
              "Storage Summary",
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(height: 15),

            LayoutBuilder(
              builder: (context, constraints) {
                if(constraints.maxWidth < 650){
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _statCard(
                        "Total Storage",
                        scan.totalStorage,
                        Icons.storage
                      ),

                      const SizedBox(height: 12),
                      _statCard(
                        "Free Storage",
                        scan.freeStorage,
                        Icons.check_circle_outline,
                      ),

                      const SizedBox(height: 12),
                      _statCard(
                        "Potentially Wasted Storage",
                        scan.wastedStorage,
                        Icons.warning_amber,

                      ),
                    ],
                  );
                }

                return Row(
                  children: [

                    Expanded(
                      child: _statCard(
                        "Total Storage",
                        scan.totalStorage,
                        Icons.storage,
                      ),
                    ),

                    const SizedBox(width: 15),
                    Expanded(
                      child: _statCard(
                        "Free Storage",
                        scan.freeStorage,
                        Icons.check_circle_outline,
                      ),
                    ),

                    const SizedBox(width: 15),

                    Expanded(
                      child: _statCard(
                        "Potentially Wasted Storage",
                        scan.wastedStorage,
                        Icons.warning_amber,
                      ),
                    ),
                  ],
                );
              },
            ),

            const SizedBox(height: 35),

            //---------------------------------------------
            //Storage Bar
            //---------------------------------------------

            const Text(
              "Storage Usage",
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(height: 15),

            LinearProgressIndicator(
              value: scan.usedPercent,
              minHeight: 20,
              borderRadius: BorderRadius.circular(10),
            ),

            const SizedBox(height: 10),

            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,

              children: [

                Text(
                  "Used: ${scan.usedStorage}",
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                  ),
                ),

                Text(
                  "Free: ${scan.freeStorage}",
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 35),

            //---------------------------------------------
            //Reclaimable Storage Section
            //---------------------------------------------

            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Reclaimable Storage",
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,

                      ),
                    ),

                    const SizedBox(height: 15),
                    if (scan.reclaimable.isEmpty) const Text("Nothing to reclaim."),
                    ...scan.reclaimable.entries.map(
                      (entry){
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: 8.0,
                          ),

                          child: Row(
                            mainAxisAlignment: 
                                MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                entry.key,
                                style: const TextStyle(
                                  fontSize: 16,
                                ),
                              ),
                              Text(
                                entry.value,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),

                        );
                      },
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 35),

            //---------------------------------------------
            // Scan Information
            //---------------------------------------------

            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),

                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Scan Information",
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),

                    const SizedBox(height: 15),
                    _infoRow(
                      "Files Scanned",
                      scan.filesScanned.toString(),
                    ),
                    _infoRow(
                      "Directories Scanned",
                      scan.directoriesScanned.toString(),
                    ),
                    _infoRow(
                      "Potentially Reclaimable",
                      scan.wastedStorage
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 30),
            //---------------------------------------------
            //Actions
            //---------------------------------------------
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onReview,

                    icon: const Icon(Icons.swipe),
                    label: const Text("Review Suggestions"),

                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.all(16),

                    ),
                  ),
                ),

                const SizedBox(width: 15),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: onExport,
                    icon: const Icon(Icons.download),
                    label: const Text("Export Results"),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.all(16),
                    ),
                  ),
                ),
              ],
            ),

          ],
        ),
      ),
    );
  }

  //---------------------------------------------
  //Stat Card
  //---------------------------------------------

  Widget _statCard(String title, String value, IconData icon){
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              icon,
              size: 30,
            ),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(
                fontSize: 14,
                color: Colors.grey,
              ),
            ),

            const SizedBox(height: 5),
            Text(
              value,
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  //-------------------------------
  //Info Row
  //-------------------------------
  Widget _infoRow(String label, String value){
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8,),

      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(
            value,
            style: const TextStyle(

              fontWeight: FontWeight.bold
            ),
          ),
        ],
      ),
    );
  }
}

//---------------------------------------------
// PB-20: Swipe-to-Review Suggestion Flow
//---------------------------------------------

/// One group of files the scan suggests removing, shown as a card.
class ReviewSuggestion {
  final String id;
  final String title;
  final String category;
  final String description;
  final String storageSize;
  final int itemCount;
  final IconData icon;

  const ReviewSuggestion({
    required this.id,
    required this.title,
    required this.category,
    required this.description,
    required this.storageSize,
    required this.itemCount,
    required this.icon,
  });
}

/// Sample cards for running the page on its own.
const List<ReviewSuggestion> sampleSuggestions = [
  ReviewSuggestion(
    id: 'screenshots',
    title: 'Old Screenshots',
    category: 'Screenshots',
    description: 'Screenshots that may no longer be needed.',
    storageSize: '420 MB',
    itemCount: 38,
    icon: Icons.screenshot,
  ),
  ReviewSuggestion(
    id: 'duplicate-photos',
    title: 'Duplicate Photos',
    category: 'Photos',
    description: 'Photos that appear to have duplicate copies.',
    storageSize: '1.8 GB',
    itemCount: 64,
    icon: Icons.photo_library_outlined,
  ),
  ReviewSuggestion(
    id: 'old-videos',
    title: 'Older Videos',
    category: 'Videos',
    description: 'Older video files you may want to review.',
    storageSize: '2.6 GB',
    itemCount: 12,
    icon: Icons.video_library_outlined,
  ),
  ReviewSuggestion(
    id: 'large-downloads',
    title: 'Large Downloads',
    category: 'Downloads',
    description: 'Large downloaded files that may be taking up space.',
    storageSize: '850 MB',
    itemCount: 9,
    icon: Icons.download_outlined,
  ),
];

class SwipeReviewPage extends StatefulWidget {
  const SwipeReviewPage({super.key, this.suggestions = sampleSuggestions, this.onRemove});

  /// The cards to swipe through, e.g. one per kind of waste the scan found.
  final List<ReviewSuggestion> suggestions;

  /// Moves a suggestion's files to the Garbage Bin. Returns a message to
  /// show, e.g. when some files couldn't be moved; null shows the usual one.
  /// Without it (the page running on its own) a removed card is only
  /// counted.
  final Future<String?> Function(ReviewSuggestion suggestion)? onRemove;

  @override
  State<SwipeReviewPage> createState() => _SwipeReviewPageState();
}

class _SwipeReviewPageState extends State<SwipeReviewPage> {
  List<ReviewSuggestion> get _suggestions => widget.suggestions;
  bool get _movesFiles => widget.onRemove != null;
  String get _removeLabel => _movesFiles ? 'Move to bin' : 'Remove';

  int _currentIndex = 0;
  int _keptCount = 0;
  int _removedFromReviewCount = 0;

  /// Cards already sent to the bin; a second review can't move them again.
  final Set<String> _moved = {};

  Future<void> _reviewCurrent(bool keep) async {
    if (_currentIndex >= _suggestions.length) return;

    final suggestion = _suggestions[_currentIndex];
    final messenger = ScaffoldMessenger.of(context);

    setState(() {
      if (keep) {
        _keptCount++;
      } else {
        _removedFromReviewCount++;
      }
      _currentIndex++;
    });

    String message;
    if (keep) {
      message = '${suggestion.title} marked to keep.';
    } else if (!_movesFiles) {
      message = '${suggestion.title} removed from the review list.';
    } else if (_moved.contains(suggestion.id)) {
      message = '${suggestion.title} is already in the Garbage Bin.';
    } else {
      _moved.add(suggestion.id);
      try {
        message = await widget.onRemove!(suggestion) ??
            'Moved ${suggestion.title} (${suggestion.storageSize}) to the Garbage Bin.';
      } catch (error) {
        _moved.remove(suggestion.id);
        message = "Couldn't move ${suggestion.title}: $error";
      }
    }
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  void _skipCurrent() {
    if (_currentIndex >= _suggestions.length) return;

    setState(() {
      _currentIndex++;
    });
  }

  void _restartReview() {
    setState(() {
      _currentIndex = 0;
      _keptCount = 0;
      _removedFromReviewCount = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isComplete = _currentIndex >= _suggestions.length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Review Suggestions'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: _suggestions.isEmpty
            ? const Center(child: Text('Nothing to review: the scan found no waste.'))
            : isComplete
                ? _buildCompletionView()
                : _buildReviewView(),
      ),
    );
  }

  Widget _buildReviewView() {
    final suggestion = _suggestions[_currentIndex];
    final progress = (_currentIndex + 1) / _suggestions.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Swipe through suggestions',
          style: TextStyle(fontSize: 23, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(
          _movesFiles
              ? 'Swipe right to keep these files or left to move them to the Garbage Bin, '
                  'where you can still recover them. You can also skip a suggestion.'
              : 'Swipe right to keep a suggestion or left to remove it from this review. '
                  'You can also skip a suggestion.',
          style: const TextStyle(fontSize: 15),
        ),
        const SizedBox(height: 20),
        LinearProgressIndicator(
          value: progress,
          minHeight: 8,
          borderRadius: BorderRadius.circular(8),
        ),
        const SizedBox(height: 8),
        Text(
          'Suggestion ${_currentIndex + 1} of ${_suggestions.length}',
          textAlign: TextAlign.end,
          style: const TextStyle(color: Colors.grey),
        ),
        const SizedBox(height: 18),
        Expanded(
          child: Center(
            child: Dismissible(
              key: ValueKey('${suggestion.id}-$_currentIndex'),
              direction: DismissDirection.horizontal,
              onDismissed: (direction) {
                _reviewCurrent(direction == DismissDirection.startToEnd);
              },
              background: _swipeBackground(
                color: Colors.green,
                icon: Icons.check_circle_outline,
                label: 'Keep',
                alignment: Alignment.centerLeft,
              ),
              secondaryBackground: _swipeBackground(
                color: Colors.red,
                icon: Icons.delete_outline,
                label: _removeLabel,
                alignment: Alignment.centerRight,
              ),
              child: Card(
                elevation: 4,
                child: SizedBox(
                  width: double.infinity,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CircleAvatar(
                          radius: 42,
                          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                          child: Icon(
                            suggestion.icon,
                            size: 42,
                            color: Theme.of(context).colorScheme.onPrimaryContainer,
                          ),
                        ),
                        const SizedBox(height: 22),
                        Text(
                          suggestion.title,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 23,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          suggestion.category,
                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 18),
                        Text(
                          suggestion.description,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 16),
                        ),
                        const SizedBox(height: 24),
                        Text(
                          suggestion.storageSize,
                          style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text('${suggestion.itemCount} ${suggestion.itemCount == 1 ? 'item' : 'items'}'),
                        const SizedBox(height: 20),
                        const Text(
                          'Swipe this card to make a choice',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _skipCurrent,
                icon: const Icon(Icons.skip_next),
                label: const Text('Skip'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.all(14),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _reviewCurrent(false),
                icon: const Icon(Icons.close),
                label: Text(_removeLabel),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red,
                  padding: const EdgeInsets.all(14),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () => _reviewCurrent(true),
                icon: const Icon(Icons.check),
                label: const Text('Keep'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.all(14),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _swipeBackground({
    required Color color,
    required IconData icon,
    required String label,
    required Alignment alignment,
  }) {
    return Container(
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: alignment == Alignment.centerLeft ? CrossAxisAlignment.start : CrossAxisAlignment.end,
        children: [
          Icon(icon, color: Colors.white, size: 34),
          const SizedBox(height: 6),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompletionView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.check_circle,
            color: Colors.green,
            size: 72,
          ),
          const SizedBox(height: 18),
          const Text(
            'Review Complete!',
            style: TextStyle(fontSize: 25, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Text('Kept: $_keptCount'),
          Text(_movesFiles
              ? 'Moved to the Garbage Bin: $_removedFromReviewCount'
              : 'Removed from review: $_removedFromReviewCount'),
          Text(
            'Skipped: ${_suggestions.length - _keptCount - _removedFromReviewCount}',
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _restartReview,
            icon: const Icon(Icons.refresh),
            label: const Text('Review Again'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Back to Scan Results'),
          ),
        ],
      ),
    );
  }
}
