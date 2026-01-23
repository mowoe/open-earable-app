import "package:flutter/material.dart";
import "package:open_wearable/apps/posture_tracker/model/attitude.dart";
import "package:open_wearable/apps/posture_tracker/model/attitude_tracker.dart";
import "package:open_wearable/apps/posture_tracker/model/bad_posture_reminder.dart";

class PostureTrackerViewModel with ChangeNotifier {
  Attitude _attitude = Attitude();
  Attitude get attitude => _attitude;

  bool get isTracking => _attitudeTracker.isTracking;
  bool get isAvailable => _attitudeTracker.isAvailable;

  BadPostureSettings get badPostureSettings => _badPostureReminder.settings;

  final AttitudeTracker _attitudeTracker;
  final BadPostureReminder _badPostureReminder;
  bool _isDisposed = false;
  bool _hasLoadedCalibration = false;

  PostureTrackerViewModel(this._attitudeTracker, this._badPostureReminder) {
    // _attitudeTracker.didChangeAvailability = (_) {
    //   if (!_isDisposed) {
    //     notifyListeners();
    //   }
    // };
    //TODO: Implement the didChangeAvailability function

    _attitudeTracker.listen((attitude) {
      _attitude = Attitude(
        roll: attitude.roll,
        pitch: attitude.pitch,
        yaw: attitude.yaw,
      );
      if (!_isDisposed) {
        notifyListeners();
      }
    });

    // Load saved calibration on initialization
    _loadSavedCalibration();
  }

  /// Loads saved calibration data from storage
  Future<void> _loadSavedCalibration() async {
    _hasLoadedCalibration = await _attitudeTracker.loadCalibration();
    if (_hasLoadedCalibration && !_isDisposed) {
      notifyListeners();
    }
  }

  /// Returns true if a saved calibration was loaded
  bool get hasLoadedCalibration => _hasLoadedCalibration;

  void startTracking() {
    _attitudeTracker.start();
    _badPostureReminder.start();
    if (!_isDisposed) {
      notifyListeners();
    }
  }

  void stopTracking() {
    _attitudeTracker.stop();
    _badPostureReminder.stop();
    if (!_isDisposed) {
      notifyListeners();
    }
  }

  void calibrate() {
    _attitudeTracker.calibrateToCurrentAttitude();
  }

  /// Clears the saved calibration
  Future<void> clearCalibration() async {
    await _attitudeTracker.clearCalibration();
    _hasLoadedCalibration = false;
    if (!_isDisposed) {
      notifyListeners();
    }
  }

  void setBadPostureSettings(BadPostureSettings settings) {
    _badPostureReminder.setSettings(settings);
  }

  @override
  void dispose() {
    stopTracking();
    _attitudeTracker.cancel();
    _isDisposed = true;
    super.dispose();
  }
}
