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
  final String usedStroage;
  final String freeStoragel
  final String wastedStorage;
  final Double usedPercent;

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
  const StroageResutlsPage({super.key});

  ScanResults get results{
    return ScanResults(
      status: 
      totalStroage:
      usedStorage:
      freeStroage:
      wastedStroage:
      usedPercent:

      reclaimable: {
        "Temporary Files": "",
        "Duplicate Fiels": "",
        "Old Downloads": "",
        "Cache Files": "",
      }

      filesScanned:
      directoriesScanned:

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

                    const sizedBox(width: 15),
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
            //Relcaimable Storage Section
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
                    ...scan.reclaimable.entries.map(
                      (entry){
                        return Padding(
                          padding: const EdgeInserts.symmetric(
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
                    Text(
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
                  child: OutlinedButton(
                    onPressed: () {
                      //open detailed scan results
                    },

                    icon: const Icon(Icons.list),
                    label: const Text("View Details"),

                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.all(16),

                    ),
                  ),
                ),

                const SizedBox(width: 15),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () {
                      //Export Scan Results
                    },
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
  },

  //---------------------------------------------
  //Stat Card
  //---------------------------------------------

  Widget_statCard(String title, String value, IconData icon){
    return card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisALignment.start,
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
              Style: const TextStyle(
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
        

