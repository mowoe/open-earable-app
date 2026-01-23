// ignore_for_file: unnecessary_this

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:logger/logger.dart';
import 'package:open_earable_flutter/open_earable_flutter.dart';
import 'package:open_wearable/view_models/app_data_storage.dart';

import 'attitude.dart';
import 'posture_calibration_data.dart';

final _logger = Logger();

/// An abstract class for attitude trackers.
abstract class AttitudeTracker with ChangeNotifier {
  final StreamController<Attitude> _attitudeStreamController =
      StreamController<Attitude>.broadcast();

  Attitude _rawAttitude = Attitude();
  Attitude get rawAttitude => _rawAttitude;
  Attitude _attitude = Attitude();
  Attitude get attitude => _attitude;
  bool get isTracking;

  /// check if tracking is available
  bool get isAvailable => _isAvailble;
  bool _isAvailble = false;

  Attitude _referenceAttitude = Attitude();
  bool _hasCalibration = false;
  bool get hasCalibration => _hasCalibration;

  // /// Callback that is called when the tracker changes availability. Takes the tracker as an argument.
  // Function(AttitudeTracker) didChangeAvailability = (_) {};

  /// Listen to the attitude stream.
  ///
  /// [callback] is called when a new attitude is received.
  void listen(void Function(Attitude) callback) {
    this._attitudeStreamController.stream.listen(callback);
  }

  /// Start tracking the attitude.
  ///
  /// In order to receive the data, you need to call `listen()` first.
  void start();

  /// Stop tracking the attitude.
  ///
  /// You can resume the tracking by calling `start()` again.
  void stop();

  void calibrate(Attitude referenceAttitude) {
    _referenceAttitude = referenceAttitude;
    _hasCalibration = true;
  }

  void calibrateToCurrentAttitude() async {
    _referenceAttitude = _rawAttitude;
    _hasCalibration = true;
    _logger.d(
      "calibrated to {roll: ${_referenceAttitude.roll}, pitch: ${_referenceAttitude.pitch}, yaw: ${_referenceAttitude.yaw}}",
    );
    await saveCalibration();
  }

  /// Saves the current calibration to persistent storage
  Future<void> saveCalibration() async {
    final calibrationData = PostureCalibrationData(
      referenceAttitude: _referenceAttitude,
    );
    logger.d(
      "Saving calibration data: {roll: ${_referenceAttitude.roll}, pitch: ${_referenceAttitude.pitch}, yaw: ${_referenceAttitude.yaw}}",
    );
    await AppDataStorage.saveData(
      'posture_tracker',
      'calibration',
      calibrationData.toJson(),
    );
    _logger.d("Saved calibration data to storage");
  }

  /// Loads the calibration from persistent storage
  /// Returns true if calibration was loaded successfully
  Future<bool> loadCalibration() async {
    final data =
        await AppDataStorage.loadData('posture_tracker', 'calibration');
    if (data != null) {
      try {
        final calibrationData = PostureCalibrationData.fromJson(data);
        _referenceAttitude = calibrationData.referenceAttitude;
        _hasCalibration = true;
        _logger.d(
            "Loaded calibration data from storage: {roll: ${_referenceAttitude.roll}, pitch: ${_referenceAttitude.pitch}, yaw: ${_referenceAttitude.yaw}}");
        return true;
      } catch (e) {
        _logger.e("Failed to load calibration data: $e");
        return false;
      }
    }
    _logger.d("No saved calibration data found");
    return false;
  }

  /// Clears the saved calibration data
  Future<void> clearCalibration() async {
    await AppDataStorage.deleteData('posture_tracker', 'calibration');
    _referenceAttitude = Attitude();
    _hasCalibration = false;
    _logger.d("Cleared calibration data");
  }

  /// Cancle the stream and close the stream controller.
  ///
  /// If you want to use the tracker again, you need to call listen() again.
  @mustCallSuper
  void cancel() {
    this._attitudeStreamController.close();
  }

  void updateAttitude({
    double? roll,
    double? pitch,
    double? yaw,
    Attitude? attitude,
  }) {
    if (roll == null && pitch == null && yaw == null && attitude == null) {
      throw ArgumentError(
        "Either roll, pitch and yaw or attitude must be provided",
      );
    }
    // Check if attitude is not null, otherwise use the angles
    attitude ??= Attitude(roll: -(roll ?? 0), pitch: pitch ?? 0, yaw: yaw ?? 0);
    _rawAttitude = attitude;
    // Update the stream controller with the attitude
    _attitude = attitude - _referenceAttitude;
    _attitudeStreamController.add(_attitude);
  }

  void setAvailability(bool isAvailable) {
    if (isAvailable != _isAvailble) {
      _isAvailble = isAvailable;
      notifyListeners();
    }
  }
}
