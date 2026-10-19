import 'package:flutter/material.dart';
import 'garbage_collection';


void main() {
  runApp(const StorageScannerApp());
}

class StorageScannerApp extends StatelessWidget {
  const StorageScannerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: GarbageCollectionPage(),
    );
  }
}