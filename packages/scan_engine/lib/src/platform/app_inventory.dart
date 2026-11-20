import 'dart:convert';
import 'dart:io';

import '../model/installed_app.dart';

/// Lists installed apps with their usage history.
abstract interface class AppInventory {
  Future<List<InstalledApp>> listApps();
}

/// Apps read from a JSON file: a list of objects with `packageName`,
/// `label`, `sizeBytes`, `installedAt`, `lastUsedAt`, `isSystem` and
/// `isEssential`. Lets unused-app detection be tested on a computer.
final class JsonAppInventory implements AppInventory {
  JsonAppInventory(this.file);

  final File file;

  @override
  Future<List<InstalledApp>> listApps() async {
    final decoded = jsonDecode(await file.readAsString()) as List<Object?>;
    return [
      for (final entry in decoded)
        InstalledApp.fromJson(entry as Map<String, Object?>),
    ];
  }
}
