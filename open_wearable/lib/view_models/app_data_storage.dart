import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:open_earable_flutter/open_earable_flutter.dart';

/// A unified storage system for app-specific data across all applications.
///
/// Each app can store and retrieve JSON data using app name and key identifiers.
/// Data is persisted to the application's documents directory.
class AppDataStorage {
  static const String _storageFileName = 'app_data_store.json';

  /// Returns the storage file reference
  static Future<File> _storageFile() async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/$_storageFileName');
  }

  /// Reads all data from disk, resetting the file to an empty JSON object if
  /// it is missing or corrupted.
  static Future<Map<String, dynamic>> _readAllData() async {
    final file = await _storageFile();
    if (!await file.exists()) {
      return {};
    }

    final contents = await file.readAsString();
    if (contents.trim().isEmpty) {
      return {};
    }

    try {
      final decoded = jsonDecode(contents) as Map<dynamic, dynamic>;
      return Map<String, dynamic>.from(decoded);
    } catch (e) {
      logger.w(
        'Failed to parse $_storageFileName; resetting corrupted store: $e',
      );
      await file.writeAsString('{}');
      return {};
    }
  }

  /// Writes all data back to disk
  static Future<void> _writeAllData(Map<String, dynamic> data) async {
    final file = await _storageFile();
    await file.writeAsString(jsonEncode(data));
  }

  /// Saves data for a specific app
  ///
  /// [appName] - The name of the app storing the data (e.g., 'posture_tracker')
  /// [key] - The key within the app's data (e.g., 'calibration')
  /// [data] - The JSON-serializable data to store
  static Future<void> saveData(
      String appName, String key, Map<String, dynamic> data) async {
    try {
      final allData = await _readAllData();

      // Update with new data
      if (!allData.containsKey(appName)) {
        allData[appName] = {};
      }
      final appData = allData[appName];
      appData[key] = data;
      allData[appName] = appData;

      // Write back to file
      await _writeAllData(allData);
    } catch (e) {
      rethrow;
    }
  }

  /// Loads data for a specific app
  ///
  /// [appName] - The name of the app (e.g., 'posture_tracker')
  /// [key] - The key within the app's data (e.g., 'calibration')
  ///
  /// Returns null if no data is found for the given app/key combination
  static Future<Map<String, dynamic>?> loadData(
      String appName, String key) async {
    try {
      final allData = await _readAllData();

      if (!allData.containsKey(appName)) {
        return null;
      }

      final appData = allData[appName] as Map<dynamic, dynamic>;
      final appDataTyped = Map<String, dynamic>.from(appData);
      final result = appDataTyped[key];
      if (result is Map<dynamic, dynamic>) {
        return Map<String, dynamic>.from(result);
      }
      return result as Map<String, dynamic>?;
    } catch (e) {
      rethrow;
    }
  }

  /// Deletes data for a specific app/key
  ///
  /// [appName] - The name of the app
  /// [key] - The key within the app's data
  static Future<void> deleteData(String appName, String key) async {
    try {
      final allData = await _readAllData();

      if (allData.containsKey(appName)) {
        final appData = allData[appName] as Map<dynamic, dynamic>;
        final appDataTyped = Map<String, dynamic>.from(appData);
        appDataTyped.remove(key);
        allData[appName] = appDataTyped;

        // Remove app entry if empty
        if (appDataTyped.isEmpty) {
          allData.remove(appName);
        }
        await _writeAllData(allData);
      }
    } catch (e) {
      rethrow;
    }
  }

  /// Deletes all data for a specific app
  ///
  /// [appName] - The name of the app
  static Future<void> deleteAppData(String appName) async {
    try {
      final allData = await _readAllData();

      allData.remove(appName);

      if (allData.isEmpty) {
        final file = await _storageFile();
        if (await file.exists()) {
          await file.delete();
        }
      } else {
        await _writeAllData(allData);
      }
    } catch (e) {
      rethrow;
    }
  }

  /// Gets all keys for a specific app
  ///
  /// [appName] - The name of the app
  ///
  /// Returns an empty list if the app has no data
  static Future<List<String>> getAppKeys(String appName) async {
    try {
      final allData = await _readAllData();

      if (!allData.containsKey(appName)) {
        return [];
      }

      final appData = allData[appName] as Map<dynamic, dynamic>;
      return appData.keys.cast<String>().toList();
    } catch (e) {
      rethrow;
    }
  }
}
