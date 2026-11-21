import 'package:flutter/material.dart';

import 'garbage_collection_storage.dart';

/// coilehayden0's Garbage Bin Storage page on its own, with an empty bin:
/// `flutter run -t lib/presentation/garbage_storage/main.dart`.
void main() {
  runApp(const GarbageStorageApp());
}

class GarbageStorageApp extends StatelessWidget {
  const GarbageStorageApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Garbage Bin Storage',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        useMaterial3: true,
      ),
      home: const GarbageStoragePage(),
    );
  }
}
