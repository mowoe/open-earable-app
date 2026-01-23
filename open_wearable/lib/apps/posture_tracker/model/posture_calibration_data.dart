import 'attitude.dart';

/// Data model for posture tracker calibration settings
class PostureCalibrationData {
  final Attitude referenceAttitude;

  PostureCalibrationData({
    required this.referenceAttitude,
  });

  /// Convert to JSON map
  Map<String, dynamic> toJson() {
    return {
      'referenceAttitude': {
        'roll': referenceAttitude.roll,
        'pitch': referenceAttitude.pitch,
        'yaw': referenceAttitude.yaw,
      },
    };
  }

  /// Create from JSON map
  factory PostureCalibrationData.fromJson(Map<String, dynamic> json) {
    final attitudeData = json['referenceAttitude'] as Map<String, dynamic>;
    return PostureCalibrationData(
      referenceAttitude: Attitude(
        roll: (attitudeData['roll'] as num?)?.toDouble() ?? 0.0,
        pitch: (attitudeData['pitch'] as num?)?.toDouble() ?? 0.0,
        yaw: (attitudeData['yaw'] as num?)?.toDouble() ?? 0.0,
      ),
    );
  }
}
