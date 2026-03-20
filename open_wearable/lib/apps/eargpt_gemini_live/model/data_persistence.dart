import 'package:open_wearable/apps/eargpt_gemini_live/model/eargpt_sensor_manager.dart';
import 'package:open_wearable/models/logger.dart';
import 'package:open_wearable/view_models/app_data_storage.dart';

/// Manages data persistence for EarGPT vital signs and sensor data
class EarGPTDataPersistence {
  final EarGPTSensorManager sensorManager;

  static const String storageAppName = 'eargpt_gemini_live';
  static const String heartRateStorageKey = 'latest_heart_rate';
  static const String skinTempStorageKey = 'latest_skin_temperature';
  static const int historyDays = 7;

  EarGPTDataPersistence({required this.sensorManager});

  //============================================================================
  // PUBLIC API
  //============================================================================

  /// Persist all latest vitals (heart rate and skin temperature)
  Future<void> persistLatestVitals() async {
    await saveLatestHeartRate();
    await saveLatestSkinTemperature();
  }

  /// Save latest heart rate with history
  Future<void> saveLatestHeartRate() async {
    await _saveLatestVital(
      heartRateStorageKey,
      sensorManager.cachedHeartRate,
      'bpm',
    );
  }

  /// Save latest skin temperature with history
  Future<void> saveLatestSkinTemperature() async {
    await _saveLatestVital(
      skinTempStorageKey,
      sensorManager.cachedSkinTemp,
      'celsius',
    );
  }

  /// Load the latest stored vital value
  static Future<Map<String, Object?>> loadLatestVital(
    String key,
    String unit,
  ) async {
    final data = await AppDataStorage.loadData(storageAppName, key);
    if (data == null || data['latest'] == null) {
      throw Exception('No stored data for $key');
    }
    final latest = data['latest'] as Map<dynamic, dynamic>;
    final value = latest['value'];
    final recordedAt = latest['recorded_at'];
    return {
      'value': value,
      'unit': unit,
      'recorded_at': recordedAt,
    };
  }

  /// Load weekly summary of stored vital values
  static Future<Map<String, Object?>> loadWeeklySummary(
    String key,
    String unit,
  ) async {
    final data = await AppDataStorage.loadData(storageAppName, key);
    if (data == null) {
      throw Exception('No stored data for $key');
    }

    final historyDynamic = data['history'] as List<dynamic>? ?? [];
    final cutoff = DateTime.now()
        .subtract(Duration(days: historyDays))
        .microsecondsSinceEpoch;

    final entries = historyDynamic.whereType<Map>().where((entry) {
      final ts = entry['recorded_at_epoch_micros'] as int?;
      return ts != null && ts >= cutoff;
    }).toList();

    if (entries.isEmpty) {
      throw Exception('No data in the last $historyDays days for $key');
    }

    final values = entries
        .map((e) => e['value'])
        .whereType<num>()
        .map((e) => e.toDouble())
        .toList();

    if (values.isEmpty) {
      throw Exception('No data for $key');
    }

    final sum = values.fold<double>(0, (a, b) => a + b);
    final avg = sum / values.length;
    final fromTs = entries.first['recorded_at'] as String?;
    final toTs = entries.last['recorded_at'] as String?;

    return {
      'average': avg,
      'unit': unit,
      'count': values.length,
      'from': fromTs,
      'to': toTs,
    };
  }

  //============================================================================
  // HELPER METHODS
  //============================================================================

  /// For each vital, save the latest value along with a history of values within the cutoff period (e.g. last 7 days)
  /// [key] - The storage key for the vital
  /// [value] - The latest value to store
  /// [unit] - The unit of the value (e.g., 'bpm', 'celsius')
  /// There will always be only one latest value stored, together with a rolling history of values within the cutoff period
  /// There is no older history beyond the cutoff period
  Future<void> _saveLatestVital(
    String key,
    double? value,
    String unit,
  ) async {
    if (value == null) {
      logger.w("No cached $key to persist.");
      return;
    }

    final recordedAt = DateTime.now();
    final recordedMicros = recordedAt.microsecondsSinceEpoch;
    final cutoffMicros =
        recordedAt.subtract(Duration(days: historyDays)).microsecondsSinceEpoch;

    try {
      final existing = await AppDataStorage.loadData(storageAppName, key) ?? {};
      final historyDynamic = existing['history'] as List<dynamic>? ?? [];
      final history = historyDynamic.whereType<Map>().where((entry) {
        final ts = entry['recorded_at_epoch_micros'] as int?;
        return ts != null && ts >= cutoffMicros;
      }).toList();

      history.add({
        'value': value,
        'unit': unit,
        'recorded_at': recordedAt.toIso8601String(),
        'recorded_at_epoch_micros': recordedMicros,
      });

      final latest = history.last;

      await AppDataStorage.saveData(storageAppName, key, {
        'latest': latest,
        'history': history,
      });
      logger.i("Persisted latest $key: $value $unit");
    } catch (e) {
      logger.w("Failed to persist $key: $e");
    }
  }
}
