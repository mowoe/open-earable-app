import 'package:firebase_ai/firebase_ai.dart';
import 'package:open_wearable/apps/eargpt_gemini_live/model/eargpt_sensor_manager.dart';
import 'package:open_wearable/apps/eargpt_gemini_live/model/data_persistence.dart';
import 'package:open_wearable/models/logger.dart';

/// Manages all Gemini AI tool definitions and their execution for EarGPT
class EarGPTTools {
  final EarGPTSensorManager sensorManager;

  EarGPTTools({required this.sensorManager});

  //============================================================================
  // FUNCTION DECLARATIONS
  //============================================================================

  /// Current heartrate
  static final fetchHeartrateTool = FunctionDeclaration(
    'fetchHeartrate',
    'Get the users current heartrate from the earable device.',
    parameters: {},
  );

  /// Current skin temperature
  static final fetchSkinTempTool = FunctionDeclaration(
    'fetchSkinTemp',
    'Get the users current skin temperature from the earable device.',
    parameters: {},
  );

  /// Current posture
  static final fetchPostureTool = FunctionDeclaration(
    'fetchPosture',
    'Get the users current posture from the earable device.',
    parameters: {},
  );

  /// Last stored heartrate
  static final fetchLatestHeartRateTool = FunctionDeclaration(
    'fetchLatestHeartRate',
    'Get the latest stored heart rate value.',
    parameters: {},
  );

  /// Last stored skin temperature
  static final fetchLatestSkinTempTool = FunctionDeclaration(
    'fetchLatestSkinTemp',
    'Get the latest stored skin temperature value.',
    parameters: {},
  );

  /// Weekly summary heartrate
  static final fetchWeeklyHeartRateSummaryTool = FunctionDeclaration(
    'fetchWeeklyHeartRateSummary',
    'Get the average heart rate for the last 7 days.',
    parameters: {},
  );

  /// Weekly summary skin temperature
  static final fetchWeeklySkinTempSummaryTool = FunctionDeclaration(
    'fetchWeeklySkinTempSummary',
    'Get the average skin temperature for the last 7 days.',
    parameters: {},
  );

  /// Get all tool declarations for Gemini model configuration
  static List<FunctionDeclaration> getAllToolDeclarations() {
    return [
      fetchHeartrateTool,
      fetchSkinTempTool,
      fetchLatestHeartRateTool,
      fetchLatestSkinTempTool,
      fetchWeeklyHeartRateSummaryTool,
      fetchWeeklySkinTempSummaryTool,
      fetchPostureTool,
    ];
  }

  //============================================================================
  // TOOL EXECUTOR METHODS
  //============================================================================

  /// Current heartrate tool
  Future<Map<String, Object?>> fetchHeartrate() async {
    if (!sensorManager.ppgSensorAvailable) {
      throw Exception("PPG sensor not available or not initialized");
    }

    double currentHR = sensorManager.cachedHeartRate ?? 0.0;

    if (sensorManager.cachedHeartRate == null) {
      throw Exception("Heart rate data not yet available from sensor");
    }

    logger.i("Model requested heartrate... $currentHR");

    return {"heart_rate": "$currentHR BPM"};
  }

  /// Current skin temperature tool
  Future<Map<String, Object?>> fetchSkinTemp() async {
    if (!sensorManager.skinTempSensorAvailable) {
      throw Exception(
          "Skin temperature sensor not available or not initialized");
    }

    double currentSkinTemp = sensorManager.cachedSkinTemp ?? 0.0;

    if (sensorManager.cachedSkinTemp == null) {
      throw Exception("Skin temperature data not yet available from sensor");
    }

    logger.i("Model requested skin temperature... $currentSkinTemp");

    return {"skin_temperature": "$currentSkinTemp °C"};
  }

  /// Latest posture tool
  Future<Map<String, Object?>> fetchPosture() async {
    if (!sensorManager.postureViewModel.hasLoadedCalibration) {
      throw Exception("Posture tracker not calibrated or not initialized");
    }

    final currentAttitude = sensorManager.postureViewModel.attitude;
    final badPostureSettings =
        sensorManager.postureViewModel.badPostureSettings;

    // Convert radians to degrees
    final rollDegrees = currentAttitude.roll.abs() * (360 / (2 * 3.14159));
    final pitchDegrees = currentAttitude.pitch.abs() * (360 / (2 * 3.14159));

    // Check against thresholds to determine posture quality
    final isBadRoll = rollDegrees > badPostureSettings.rollAngleThreshold;
    final isBadPitch = pitchDegrees > badPostureSettings.pitchAngleThreshold;
    final isBadPosture = isBadRoll || isBadPitch;

    // Determine posture quality assessment
    String postureQuality;
    if (!isBadPosture) {
      postureQuality = "good";
    } else if (isBadRoll && isBadPitch) {
      postureQuality = "poor";
    } else {
      postureQuality = "fair";
    }

    final postureData = {
      "head_roll_degrees": rollDegrees.toStringAsFixed(1),
      "head_pitch_degrees": pitchDegrees.toStringAsFixed(1),
      "roll_threshold_degrees": badPostureSettings.rollAngleThreshold,
      "pitch_threshold_degrees": badPostureSettings.pitchAngleThreshold,
      "posture_quality": postureQuality,
      "is_bad_posture": isBadPosture
    };

    logger.i("Model requested posture... $postureData");

    return {"posture": "$postureData"};
  }

  /// Latest stored heart rate
  Future<Map<String, Object?>> fetchLatestHeartRate() async {
    return EarGPTDataPersistence.loadLatestVital(
      EarGPTDataPersistence.heartRateStorageKey,
      'bpm',
    );
  }

  /// Latest stored skin temp
  Future<Map<String, Object?>> fetchLatestSkinTemp() async {
    return EarGPTDataPersistence.loadLatestVital(
      EarGPTDataPersistence.skinTempStorageKey,
      'celsius',
    );
  }

  /// Weekly summary heart rate
  Future<Map<String, Object?>> fetchWeeklyHeartRateSummary() async {
    return EarGPTDataPersistence.loadWeeklySummary(
      EarGPTDataPersistence.heartRateStorageKey,
      'bpm',
    );
  }

  /// Weekly summary skin temp
  Future<Map<String, Object?>> fetchWeeklySkinTempSummary() async {
    return EarGPTDataPersistence.loadWeeklySummary(
      EarGPTDataPersistence.skinTempStorageKey,
      'celsius',
    );
  }

  //============================================================================
  // TOOL EXECUTORS MAP
  //============================================================================

  /// Map of tool executors for smart validation + dispatch
  Map<String, Future<Map<String, Object?>> Function()> get toolExecutors => {
        'fetchHeartrate': fetchHeartrate,
        'fetchSkinTemp': fetchSkinTemp,
        'fetchPosture': fetchPosture,
        'fetchLatestHeartRate': fetchLatestHeartRate,
        'fetchLatestSkinTemp': fetchLatestSkinTemp,
        'fetchWeeklyHeartRateSummary': fetchWeeklyHeartRateSummary,
        'fetchWeeklySkinTempSummary': fetchWeeklySkinTempSummary,
      };
}
