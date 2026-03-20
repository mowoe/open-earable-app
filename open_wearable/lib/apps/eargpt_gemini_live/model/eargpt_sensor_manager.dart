import 'dart:async';

import 'package:flutter/material.dart';
import 'package:open_earable_flutter/open_earable_flutter.dart' hide logger;
import 'package:open_wearable/apps/heart_tracker/model/ppg_filter.dart';
import 'package:open_wearable/apps/posture_tracker/model/attitude.dart';
import 'package:open_wearable/apps/posture_tracker/model/attitude_tracker.dart';
import 'package:open_wearable/apps/posture_tracker/model/bad_posture_reminder.dart';
import 'package:open_wearable/apps/posture_tracker/view_model/posture_tracker_view_model.dart';
import 'package:open_wearable/view_models/sensor_configuration_provider.dart';
import 'package:open_wearable/models/logger.dart';
import 'package:provider/provider.dart';

/// Manages all sensor initialization, configuration, and data streams for EarGPT
class EarGPTSensorManager {
  // Sensors
  final Sensor? ppgSensor;
  final Sensor? skinTempSensor;
  final Wearable? wearable;
  final AttitudeTracker attitudeTracker;

  // PPG Filter
  late final PpgFilter ppgFilter;

  // State
  bool _ppgSensorAvailable = false;
  bool _skinTempSensorAvailable = false;
  double? _cachedHeartRate;
  double? _cachedSkinTemp;

  // Subscriptions
  StreamSubscription<double>? _heartRateSubscription;
  StreamSubscription<SensorValue>? _skinTempSubscription;
  StreamSubscription<ButtonEvent>? _buttonSubscription;

  // Posture tracker
  late PostureTrackerViewModel _postureViewModel;
  late Attitude attitude;

  // Callbacks
  final Function(double)? onHeartRateUpdate;
  final Function(double)? onSkinTempUpdate;
  final Function()? onAttitudeChanged;

  EarGPTSensorManager({
    required this.ppgSensor,
    required this.skinTempSensor,
    required this.wearable,
    required this.attitudeTracker,
    this.onHeartRateUpdate,
    this.onSkinTempUpdate,
    this.onAttitudeChanged,
  });

  // Getters
  bool get ppgSensorAvailable => _ppgSensorAvailable;
  bool get skinTempSensorAvailable => _skinTempSensorAvailable;
  double? get cachedHeartRate => _cachedHeartRate;
  double? get cachedSkinTemp => _cachedSkinTemp;
  PostureTrackerViewModel get postureViewModel => _postureViewModel;

  //============================================================================
  // INITIALIZATION
  //============================================================================

  /// Initialize sensors in a controlled, sequential manner to ensure all components are ready
  Future<void> initialize(BuildContext context) async {
    // Wait for the widget tree to be built before accessing context
    await Future.delayed(const Duration(milliseconds: 100));

    if ((ppgSensor != null) && (skinTempSensor != null)) {
      try {
        // Step 1: Configure sensors
        await _configureSensors(context, ppgSensor!, skinTempSensor!);

        // Step 2: Initialize PPG filter
        await _initializePpgFilter(context, ppgSensor!);

        // Step 3: Setup subscriptions
        await _setupSensorSubscriptions(ppgSensor!, skinTempSensor!);

        // Step 4: Initialize posture tracker
        await _initializePostureTracker();

        // Update availability flags
        _ppgSensorAvailable = true;
        _skinTempSensorAvailable = true;

        logger.i("All sensors initialized successfully");
      } catch (e) {
        logger.w("Error during sensor initialization: $e");
        _ppgSensorAvailable = false;
        _skinTempSensorAvailable = false;
      }
    } else {
      // If sensors are null, setup dummy streams
      _setupDummySensors(ppgSensor, skinTempSensor);
    }
  }

  //============================================================================
  // SENSOR CONFIGURATION
  //============================================================================

  /// Configure PPG and skin temperature sensors with proper settings
  Future<void> _configureSensors(
    BuildContext context,
    Sensor ppgSensor,
    Sensor skinTempSensor,
  ) async {
    final configProvider =
        Provider.of<SensorConfigurationProvider>(context, listen: false);

    // Get possible configuration attributes
    SensorConfiguration ppgConfig = ppgSensor.relatedConfigurations.first;
    SensorConfiguration skinTempConfig =
        skinTempSensor.relatedConfigurations.first;

    // Enable streaming from sensor if "stream sensor" is a configuration option
    if (ppgConfig is ConfigurableSensorConfiguration &&
        ppgConfig.availableOptions.contains(StreamSensorConfigOption())) {
      configProvider.addSensorConfigurationOption(
        ppgConfig,
        StreamSensorConfigOption(),
      );
    }

    if (skinTempConfig is ConfigurableSensorConfiguration &&
        skinTempConfig.availableOptions.contains(StreamSensorConfigOption())) {
      configProvider.addSensorConfigurationOption(
        skinTempConfig,
        StreamSensorConfigOption(),
      );
    }

    // Get possible configuration values for chosen configuration
    List<SensorConfigurationValue> ppgValues =
        configProvider.getSensorConfigurationValues(ppgConfig, distinct: true);
    configProvider.addSensorConfiguration(ppgConfig, ppgValues.first);
    SensorConfigurationValue selectedPpgValue =
        configProvider.getSelectedConfigurationValue(ppgConfig)!;
    ppgConfig.setConfiguration(selectedPpgValue);

    List<SensorConfigurationValue> skinTempValues = configProvider
        .getSensorConfigurationValues(skinTempConfig, distinct: true);
    configProvider.addSensorConfiguration(
      skinTempConfig,
      skinTempValues.first,
    );
    SensorConfigurationValue selectedSkinTempValue =
        configProvider.getSelectedConfigurationValue(skinTempConfig)!;
    skinTempConfig.setConfiguration(selectedSkinTempValue);

    logger.i("Sensors configured successfully");

    // Small delay to allow configuration to propagate
    await Future.delayed(const Duration(milliseconds: 50));
  }

  //============================================================================
  // PPG FILTER SETUP
  //============================================================================

  /// Initialize PPG filter with proper sample frequency
  Future<void> _initializePpgFilter(
    BuildContext context,
    Sensor ppgSensor,
  ) async {
    final configProvider =
        Provider.of<SensorConfigurationProvider>(context, listen: false);
    SensorConfiguration ppgConfig = ppgSensor.relatedConfigurations.first;
    SensorConfigurationValue selectedValue =
        configProvider.getSelectedConfigurationValue(ppgConfig)!;

    double sampleFreq = 25;
    if (selectedValue is SensorFrequencyConfigurationValue) {
      sampleFreq = selectedValue.frequencyHz;
    }

    ppgFilter = PpgFilter(
      inputStream: ppgSensor.sensorStream.asyncMap((data) {
        SensorDoubleValue sensorData = data as SensorDoubleValue;
        return (
          sensorData.timestamp,
          -(sensorData.values[2] + sensorData.values[3])
        );
      }).asBroadcastStream(),
      sampleFreq: sampleFreq,
      timestampExponent: ppgSensor.timestampExponent,
    );

    logger.i("PPG filter initialized with sample freq: $sampleFreq Hz");

    // Allow filter to initialize
    await Future.delayed(const Duration(milliseconds: 100));
  }

  //============================================================================
  // STREAM SUBSCRIPTIONS
  //============================================================================

  /// Setup subscriptions to sensor streams
  Future<void> _setupSensorSubscriptions(
    Sensor ppgSensor,
    Sensor skinTempSensor,
  ) async {
    // Subscribe to heart rate stream
    final heartRateStream = ppgFilter.heartRateStream;
    _heartRateSubscription = heartRateStream.listen((heartRate) {
      _cachedHeartRate = heartRate;
      onHeartRateUpdate?.call(heartRate);
      logger.i('Heart rate updated: $heartRate BPM');
    });

    // Subscribe to skin temperature stream
    _skinTempSubscription = skinTempSensor.sensorStream.listen((data) {
      final sensorValue = data as SensorDoubleValue;
      _cachedSkinTemp = sensorValue.values[0];
      onSkinTempUpdate?.call(sensorValue.values[0]);
      logger.i('Skin temp updated: ${sensorValue.values[0]} °C');
    });

    logger.i("Sensor subscriptions established");

    // Allow streams to start flowing
    await Future.delayed(const Duration(milliseconds: 100));
  }

  //============================================================================
  // POSTURE TRACKER
  //============================================================================

  /// Initialize the posture tracker view model
  Future<void> _initializePostureTracker() async {
    _postureViewModel = PostureTrackerViewModel(
      attitudeTracker,
      BadPostureReminder(attitudeTracker: attitudeTracker),
    );

    if (!_postureViewModel.hasLoadedCalibration) {
      logger.w("PostureTrackerViewModel: No saved calibration loaded.");
    }

    _postureViewModel.startTracking();
    _postureViewModel.addListener(_onAttitudeChangedInternal);

    logger.i("Posture tracker initialized");

    // Allow posture tracker to start
    await Future.delayed(const Duration(milliseconds: 100));
  }

  void _onAttitudeChangedInternal() {
    attitude = _postureViewModel.attitude;
    onAttitudeChanged?.call();
  }

  //============================================================================
  // DUMMY SENSORS (FOR TESTING)
  //============================================================================

  /// Setup dummy sensors for testing when real sensors are unavailable
  void _setupDummySensors(Sensor? ppgSensor, Sensor? skinTempSensor) {
    logger.w("Setting up dummy sensors - real sensors not available");

    double sampleFreq = 25;

    ppgFilter = PpgFilter(
      inputStream: Stream<(int, double)>.empty(),
      sampleFreq: sampleFreq,
      timestampExponent: 0,
    );

    // Subscribe to heart rate stream
    final heartRateStream =
        ppgSensor != null ? ppgFilter.heartRateStream : fakeHeartRateStream;
    _heartRateSubscription = heartRateStream.listen((heartRate) {
      _cachedHeartRate = heartRate;
      onHeartRateUpdate?.call(heartRate);
    });

    // Subscribe to skin temperature stream
    final skinTempStream = skinTempSensor != null
        ? skinTempSensor.sensorStream
        : fakeSkinTempStream;
    _skinTempSubscription = skinTempStream.listen((data) {
      final sensorValue = data as SensorDoubleValue;
      _cachedSkinTemp = sensorValue.values[0];
      onSkinTempUpdate?.call(sensorValue.values[0]);
    });

    logger.i("Dummy sensors setup complete");
  }

  //============================================================================
  // FAKE STREAMS FOR TESTING
  //============================================================================

  final fakeHeartRateStream = Stream<double>.periodic(
    Duration(seconds: 1),
    (count) => 60 + (count % 40),
  ).asBroadcastStream();

  final fakeSkinTempStream = Stream<SensorDoubleValue>.periodic(
    Duration(seconds: 1),
    (count) => SensorDoubleValue(
      timestamp: DateTime.now().microsecondsSinceEpoch,
      values: [36.5 + (count % 5) * 0.1],
    ),
  ).asBroadcastStream();

  //============================================================================
  // BUTTON LISTENER
  //============================================================================

  void setupButtonListener(Function() onButtonPressed) {
    if (wearable != null && wearable is ButtonManager) {
      _buttonSubscription =
          (wearable as ButtonManager).buttonEvents.listen((event) {
        if (event == ButtonEvent.pressed) {
          logger.i("Button Trigger: Pressed");
          onButtonPressed();
        }
      });
      logger.i("Button listener setup complete via ButtonManager.");
    } else {
      logger.w("Wearable does not support ButtonManager or is null.");
    }
  }

  //============================================================================
  // CLEANUP
  //============================================================================

  void dispose() {
    _heartRateSubscription?.cancel();
    _skinTempSubscription?.cancel();
    _buttonSubscription?.cancel();
    _postureViewModel.removeListener(_onAttitudeChangedInternal);
    _postureViewModel.stopTracking();
  }
}
