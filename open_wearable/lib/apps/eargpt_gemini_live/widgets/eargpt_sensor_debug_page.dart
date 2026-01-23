// ignore_for_file: invalid_use_of_internal_member

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:open_earable_flutter/open_earable_flutter.dart';
import 'package:open_wearable/apps/heart_tracker/model/ppg_filter.dart';
import 'package:open_wearable/apps/posture_tracker/model/attitude.dart';
import 'package:open_wearable/view_models/sensor_configuration_provider.dart';
import 'package:provider/provider.dart';
import 'package:open_wearable/apps/eargpt_gemini_live/model/audio_player.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:firebase_ai/firebase_ai.dart';
import 'package:lottie/lottie.dart';
import 'package:open_wearable/apps/posture_tracker/view_model/posture_tracker_view_model.dart';
import 'package:open_wearable/apps/posture_tracker/model/attitude_tracker.dart';
import 'package:open_wearable/apps/posture_tracker/model/bad_posture_reminder.dart';
import 'package:open_wearable/view_models/app_data_storage.dart';

class EargptSensorDebugPage extends StatefulWidget {
  final Sensor? ppgSensor;
  final Wearable? wearable;
  final AttitudeTracker attitudeTracker;
  final Sensor? skinTempSensor;

  const EargptSensorDebugPage({
    super.key,
    required this.ppgSensor,
    required this.skinTempSensor,
    this.wearable,
    required this.attitudeTracker,
  });

  @override
  State<EargptSensorDebugPage> createState() => _EargptSensorDebugPageState();
}

class _EargptSensorDebugPageState extends State<EargptSensorDebugPage>
    with TickerProviderStateMixin {
  late final PpgFilter ppgFilter;
  late final AnimationController _animationController;
  late final LiveGenerativeModel model;
  late final PostureTrackerViewModel _postureViewModel;

  LiveSession? _session;
  final AudioRecorder _recorder = AudioRecorder();
  final List<Uint8List> _receivedAudioBuffer = [];
  final AudioResponsePlayer _audioResponsePlayer = AudioResponsePlayer();
  bool _isRecording = false;
  bool _conversationActive = false;
  double? _cachedHeartRate;
  double? _cachedSkinTemp;
  StreamSubscription<double>? _heartRateSubscription;
  StreamSubscription<SensorValue>? _skinTempSubscription;
  StreamSubscription<ButtonEvent>? _buttonSubscription;
  bool _ppgSensorAvailable = false;
  bool _skinTempSensorAvailable = false;
  late Attitude attitude; // Remove after testing
  static const String _storageAppName = 'eargpt_gemini_live';
  static const String _heartRateStorageKey = 'latest_heart_rate';
  static const String _skinTempStorageKey = 'latest_skin_temperature';
  static const int _historyDays = 7;

  //============================================================================
  // SETUP BUTTON ON EARABLE
  //============================================================================

  void _setupButtonListener() {
    if (widget.wearable != null && widget.wearable is ButtonManager) {
      _buttonSubscription =
          (widget.wearable as ButtonManager).buttonEvents.listen((event) {
        if (event == ButtonEvent.pressed) {
          logger.i("Button Trigger: Pressed");
          if (mounted) {
            setState(() {
              if (_conversationActive) {
                _endConversation();
              } else {
                _startConversation();
              }
            });
          }
        }
      });
      logger.i("Button listener setup complete via ButtonManager.");
    } else {
      logger.w("Wearable does not support ButtonManager or is null.");
    }
  }

  //============================================================================
  // INIT STATE
  //============================================================================

  @override
  void initState() {
    super.initState();

    // Initialize animation controller
    _animationController = AnimationController(vsync: this);

    // Setup Gemini Live Generative Model
    model = FirebaseAI.googleAI().liveGenerativeModel(
      model: 'gemini-2.5-flash-native-audio-preview-12-2025',
      systemInstruction: Content.system(
          '''You are a personal health AI assistant integrated with OpenEarable smart earbuds. You have access to real-time biometric data from the user's ear-based sensors. Keep responses concise and relevant to the user's health and activity.
          Use the provided tools to get the user's health statistics.'''),
      tools: [
        Tool.functionDeclarations([
          fetchHeartrateTool,
          fetchSkinTempTool,
          fetchLatestHeartRateTool,
          fetchLatestSkinTempTool,
          fetchWeeklyHeartRateSummaryTool,
          fetchWeeklySkinTempSummaryTool,
          fetchPostureTool
        ]),
      ],
      liveGenerationConfig:
          LiveGenerationConfig(responseModalities: [ResponseModalities.audio]),
    );

    // Setup sensors and data streams asynchronously to ensure proper sequencing
    _initializeSensors();
  }

  /// Initialize sensors in a controlled, sequential manner to ensure all components are ready
  Future<void> _initializeSensors() async {
    final ppgSensor = widget.ppgSensor;
    final skinTempSensor = widget.skinTempSensor;

    // Wait for the widget tree to be built before accessing context
    await Future.delayed(const Duration(milliseconds: 100));

    if ((ppgSensor != null) && (skinTempSensor != null)) {
      try {
        // Step 1: Configure sensors
        await _configureSensors(ppgSensor, skinTempSensor);

        // Step 2: Initialize PPG filter
        await _initializePpgFilter(ppgSensor);

        // Step 3: Setup subscriptions
        await _setupSensorSubscriptions(ppgSensor, skinTempSensor);

        // Step 4: Initialize posture tracker
        await _initializePostureTracker();

        // Update availability flags
        if (mounted) {
          setState(() {
            _ppgSensorAvailable = true;
            _skinTempSensorAvailable = true;
          });
        }

        logger.i("All sensors initialized successfully");
      } catch (e) {
        logger.w("Error during sensor initialization: $e");
        if (mounted) {
          setState(() {
            _ppgSensorAvailable = false;
            _skinTempSensorAvailable = false;
          });
        }
      }
    } else {
      // If sensors are null, setup dummy streams
      _setupDummySensors(ppgSensor, skinTempSensor);
    }

    // Finally, setup button listener after all sensors are initialized
    _setupButtonListener();
  }

  /// Configure PPG and skin temperature sensors with proper settings
  Future<void> _configureSensors(
    Sensor ppgSensor,
    Sensor skinTempSensor,
  ) async {
    if (!mounted) return;

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

  /// Initialize PPG filter with proper sample frequency
  Future<void> _initializePpgFilter(Sensor ppgSensor) async {
    final configProvider =
        Provider.of<SensorConfigurationProvider>(context, listen: false);
    SensorConfiguration ppgConfig = ppgSensor.relatedConfigurations.first;
    SensorConfigurationValue selectedValue =
        configProvider.getSelectedConfigurationValue(ppgConfig)!;

    double sampleFreq = 25;
    if (selectedValue is SensorFrequencyConfigurationValue) {
      sampleFreq = selectedValue.frequencyHz;
    }

    if (mounted) {
      setState(() {
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
      });
    }

    logger.i("PPG filter initialized with sample freq: $sampleFreq Hz");

    // Allow filter to initialize
    await Future.delayed(const Duration(milliseconds: 100));
  }

  /// Setup subscriptions to sensor streams
  Future<void> _setupSensorSubscriptions(
    Sensor ppgSensor,
    Sensor skinTempSensor,
  ) async {
    // Subscribe to heart rate stream
    final heartRateStream = ppgFilter.heartRateStream;
    _heartRateSubscription = heartRateStream.listen((heartRate) {
      if (mounted) {
        setState(() {
          _cachedHeartRate = heartRate;
        });
      }
      logger.i('Heart rate updated: $heartRate BPM');
    });

    // Subscribe to skin temperature stream
    _skinTempSubscription = skinTempSensor.sensorStream.listen((data) {
      final sensorValue = data as SensorDoubleValue;
      if (mounted) {
        setState(() {
          _cachedSkinTemp = sensorValue.values[0];
        });
      }
      logger.i('Skin temp updated: ${sensorValue.values[0]} °C');
    });

    logger.i("Sensor subscriptions established");

    // Allow streams to start flowing
    await Future.delayed(const Duration(milliseconds: 100));
  }

  /// Initialize the posture tracker view model
  Future<void> _initializePostureTracker() async {
    _postureViewModel = PostureTrackerViewModel(
      widget.attitudeTracker,
      BadPostureReminder(attitudeTracker: widget.attitudeTracker),
    );

    if (!_postureViewModel.hasLoadedCalibration) {
      logger.w("PostureTrackerViewModel: No saved calibration loaded.");
    }

    if (mounted) {
      setState(() {
        _postureViewModel.startTracking();
        _postureViewModel.addListener(_onAttitudeChanged);
      });
    }

    logger.i("Posture tracker initialized");

    // Allow posture tracker to start
    await Future.delayed(const Duration(milliseconds: 100));
  }

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
      if (mounted) {
        setState(() {
          _cachedHeartRate = heartRate;
        });
      }
    });

    // Subscribe to skin temperature stream
    final skinTempStream = skinTempSensor != null
        ? skinTempSensor.sensorStream
        : fakeSkinTempStream;
    _skinTempSubscription = skinTempStream.listen((data) {
      final sensorValue = data as SensorDoubleValue;
      if (mounted) {
        setState(() {
          _cachedSkinTemp = sensorValue.values[0];
        });
      }
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
  // TOOL IMPLEMENTATIONS
  //============================================================================

  // Current heartrate
  final fetchHeartrateTool = FunctionDeclaration(
    'fetchHeartrate',
    'Get the users current heartrate from the earable device.',
    parameters: {},
  );

  // Current heartrate
  final fetchSkinTempTool = FunctionDeclaration(
    'fetchSkinTemp',
    'Get the users current skin temperature from the earable device.',
    parameters: {},
  );

  // Current posture
  final fetchPostureTool = FunctionDeclaration(
    'fetchPosture',
    'Get the users current posture from the earable device.',
    parameters: {},
  );

  // Last stored heartrate
  final fetchLatestHeartRateTool = FunctionDeclaration(
    'fetchLatestHeartRate',
    'Get the latest stored heart rate value.',
    parameters: {},
  );

  // Last stored skin temperature
  final fetchLatestSkinTempTool = FunctionDeclaration(
    'fetchLatestSkinTemp',
    'Get the latest stored skin temperature value.',
    parameters: {},
  );

  // Weekly summary heartrate
  final fetchWeeklyHeartRateSummaryTool = FunctionDeclaration(
    'fetchWeeklyHeartRateSummary',
    'Get the average heart rate for the last 7 days.',
    parameters: {},
  );

  // Weekly summary skin temperature
  final fetchWeeklySkinTempSummaryTool = FunctionDeclaration(
    'fetchWeeklySkinTempSummary',
    'Get the average skin temperature for the last 7 days.',
    parameters: {},
  );

  // Current heartrate tool
  Future<Map<String, Object?>> fetchHeartrate() async {
    if (!_ppgSensorAvailable) {
      throw Exception("PPG sensor not available or not initialized");
    }

    double currentHR = _cachedHeartRate ?? 0.0;

    if (_cachedHeartRate == null) {
      throw Exception("Heart rate data not yet available from sensor");
    }

    logger.i("Model requested heartrate... $currentHR");

    return {"heart_rate": "$currentHR BPM"};
  }

  // Current skin temperature tool
  Future<Map<String, Object?>> fetchSkinTemp() async {
    if (!_skinTempSensorAvailable) {
      throw Exception(
          "Skin temperature sensor not available or not initialized");
    }

    double currentSkinTemp = _cachedSkinTemp ?? 0.0;

    if (_cachedSkinTemp == null) {
      throw Exception("Skin temperature data not yet available from sensor");
    }

    logger.i("Model requested skin temperature... $currentSkinTemp");

    return {"skin_temperature": "$currentSkinTemp °C"};
  }

  // Latest posture tool
  Future<Map<String, Object?>> fetchPosture() async {
    if (!_postureViewModel.hasLoadedCalibration) {
      throw Exception("Posture tracker not calibrated or not initialized");
    }

    final currentAttitude = _postureViewModel.attitude;
    final badPostureSettings = _postureViewModel.badPostureSettings;

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

  // Latest stored vital tool
  Future<Map<String, Object?>> _loadLatestVital(String key, String unit) async {
    final data = await AppDataStorage.loadData(_storageAppName, key);
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

  // Weekly summary tool
  Future<Map<String, Object?>> _loadWeeklySummary(
    String key,
    String unit,
  ) async {
    final data = await AppDataStorage.loadData(_storageAppName, key);
    if (data == null) {
      throw Exception('No stored data for $key');
    }

    final historyDynamic = data['history'] as List<dynamic>? ?? [];
    final cutoff = DateTime.now()
        .subtract(Duration(days: _historyDays))
        .microsecondsSinceEpoch;

    final entries = historyDynamic.whereType<Map>().where((entry) {
      final ts = entry['recorded_at_epoch_micros'] as int?;
      return ts != null && ts >= cutoff;
    }).toList();

    if (entries.isEmpty) {
      throw Exception('No data in the last $_historyDays days for $key');
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

  // Latest stored heart rate
  Future<Map<String, Object?>> fetchLatestHeartRate() async {
    return _loadLatestVital(_heartRateStorageKey, 'bpm');
  }

  // Latest stored skin temp
  Future<Map<String, Object?>> fetchLatestSkinTemp() async {
    return _loadLatestVital(_skinTempStorageKey, 'celsius');
  }

  // Weekly summary heart rate
  Future<Map<String, Object?>> fetchWeeklyHeartRateSummary() async {
    return _loadWeeklySummary(_heartRateStorageKey, 'bpm');
  }

  // Weekly summary skin temp
  Future<Map<String, Object?>> fetchWeeklySkinTempSummary() async {
    return _loadWeeklySummary(_skinTempStorageKey, 'celsius');
  }

  // Map of tool executors for smart validation + dispatch
  Map<String, Future<Map<String, Object?>> Function()> get _toolExecutors => {
        'fetchHeartrate': fetchHeartrate,
        'fetchSkinTemp': fetchSkinTemp,
        'fetchPosture': fetchPosture,
        'fetchLatestHeartRate': fetchLatestHeartRate,
        'fetchLatestSkinTemp': fetchLatestSkinTemp,
        'fetchWeeklyHeartRateSummary': fetchWeeklyHeartRateSummary,
        'fetchWeeklySkinTempSummary': fetchWeeklySkinTempSummary,
      };

  //============================================================================
  // DATA PERSISTENCE
  //============================================================================

  Future<void> _persistLatestVitals() async {
    await _saveLatestHeartRate();
    await _saveLatestSkinTemperature();
  }

  /// For each vital, save the latest value along with a history of values within the cutoff period (e.g. last 7 days)
  /// [key] - The storage key for the vital
  /// [value] - The latest value to store
  /// [unit] - The unit of the value (e.g., 'bpm', 'celsius')
  /// [timestamp] - The timestamp of the value
  /// There will alway be only one latest value stored, together with a rolling history of values within the cutoff period
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
    final cutoffMicros = recordedAt
        .subtract(Duration(days: _historyDays))
        .microsecondsSinceEpoch;

    try {
      final existing =
          await AppDataStorage.loadData(_storageAppName, key) ?? {};
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

      await AppDataStorage.saveData(_storageAppName, key, {
        'latest': latest,
        'history': history,
      });
      logger.i("Persisted latest $key: $value $unit");
    } catch (e) {
      logger.w("Failed to persist $key: $e");
    }
  }

  // Save latest heart rate with history
  Future<void> _saveLatestHeartRate() async {
    await _saveLatestVital(
      _heartRateStorageKey,
      _cachedHeartRate,
      'bpm',
    );
  }

  // Save latest skin temperature with history
  Future<void> _saveLatestSkinTemperature() async {
    await _saveLatestVital(
      _skinTempStorageKey,
      _cachedSkinTemp,
      'celsius',
    );
  }

  //============================================================================
  // HANDLE ANIMATION STATE
  //============================================================================

  void _syncAnimationWithRecordingState() {
    if (_isRecording && _animationController.isAnimating) {
      //_animationController.reverse();
      //_animationController.repeat();
      //_animationController.stop();
      //_animationController.reset();
      _animationController.animateBack(0.0);
    } else if (!_isRecording &&
        !_animationController.isAnimating &&
        _conversationActive) {
      _animationController.forward();
      _animationController.repeat();
      //_animationController.fling(velocity: 1.0);
    } else if (!_conversationActive && _animationController.isAnimating) {
      _animationController.stop();
      _animationController.reset();
    }
  }

  //============================================================================
  // HANDLE CONVERSATION
  //============================================================================

  Future<void> _initSession() async {
    try {
      _session = await model.connect();
      _conversationActive = true;
    } catch (e) {
      logger.w('Failed to initialize model session: $e');
    }
  }

  Future<void> _startConversation() async {
    await _initSession();
    await _startRecording();
  }

  Future<void> _endConversation() async {
    logger.i("Ending conversation...");
    _conversationActive = false;
    _session?.close();
    await _stopRecording();
    await _persistLatestVitals();
    _receivedAudioBuffer.clear();
    await _audioResponsePlayer.stopAndClear();
    logger.i("Cleared audio buffer on conversation end.");
  }

  Future<void> _startRecording() async {
    if (_isRecording) return;

    if (_audioResponsePlayer.player.state == PlayerState.playing) {
      return;
    }

    logger.i("Starting recording...");
    setState(() {
      _isRecording = true;
      _syncAnimationWithRecordingState();
    });

    if (await _recorder.hasPermission()) {
      try {
        final audioRecordStream = await _recorder.startStream(
          const RecordConfig(
            encoder: AudioEncoder.pcm16bits,
            sampleRate: 16000,
            numChannels: 1,
          ),
        );
        await Future.wait([
          _sendAudioLoop(audioRecordStream),
          _receiveResponseLoop(),
        ]);
      } catch (e) {
        logger.w("Error in recording loop: $e");
        setState(() {
          _isRecording = false;
          _syncAnimationWithRecordingState();
        });
        rethrow;
      }
    } else {
      logger.w("Recording permission denied");
      setState(() {
        _isRecording = false;
        _syncAnimationWithRecordingState();
      });
      throw Exception("Recording permission denied");
    }
  }

  Future<void> _stopRecording() async {
    logger.i("Stopping recording...");
    if (_isRecording) {
      final _ = await _recorder.stop();
      setState(() {
        _isRecording = false;
        _syncAnimationWithRecordingState();
      });
    } else {
      logger.i("Recording already stopped.");
    }
  }

  Future<void> _sendAudioLoop(Stream<Uint8List> audioStream) async {
    logger.i("Sending audio to Gemini...");
    await for (final data in audioStream) {
      if (!_conversationActive) {
        break;
      }
      //logger.i("Sending audio chunk of size: ${data.length}");
      await _session?.sendAudioRealtime(InlineDataPart('audio/pcm', data));

      //await _session?.
    }
  }

  Future<void> _receiveResponseLoop() async {
    logger.i("Receiving responses from Gemini...");
    try {
      await for (final message in _session!.receive()) {
        if (!_conversationActive) {
          break;
        }
        logger.i("Received message from Gemini: $message");

        await _handleLiveServerMessage(message);
      }
      // Stream completed normally (session closed by API)
      logger.i("Session stream completed - session closed by API");
      if (_conversationActive) {
        setState(() {
          _conversationActive = false;
        });
        await _stopRecording();
        await _audioResponsePlayer.stopAndClear();
      }
    } catch (e) {
      // Stream errored (session closed unexpectedly)
      logger.w("Session stream error: $e");
      if (_conversationActive) {
        setState(() {
          _conversationActive = false;
        });
        await _stopRecording();
        await _audioResponsePlayer.stopAndClear();
      }
    }
  }

  //============================================================================
  // HANDLE INCOMING MESSAGES FROM MODEL
  //============================================================================

  Future<void> _handleLiveServerMessage(LiveServerResponse response) async {
    final message = response.message;

    logger.i("Response message type: $message");

    if (message is LiveServerToolCall &&
        message.functionCalls?.isNotEmpty == true) {
      //============================================================================
      // FUNCTION/TOOL CALLS
      //============================================================================

      // Extract requested function calls
      final functionCalls = message.functionCalls!;
      // Prepare responses
      final responses = <FunctionResponse>[];

      //Iterate over each function call
      for (final functionCall in functionCalls) {
        logger.w("Received tool call: ${functionCall.name}");

        // Check if we have an executor for this tool
        final executor = _toolExecutors[functionCall.name];
        if (executor != null) {
          try {
            // Execute the tool and get result
            final result = await executor();
            responses.add(
              FunctionResponse(functionCall.name, result, id: functionCall.id),
            );
            logger.i(
              "Prepared function response for ${functionCall.name}: $result",
            );
          } catch (e) {
            // Handle execution errors
            logger.w("Error executing tool '${functionCall.name}': $e");
            responses.add(
              FunctionResponse(
                functionCall.name,
                {'error': e.toString()},
                id: functionCall.id,
              ),
            );
          }
        } else {
          // Unknown tool requested
          logger.w('Unknown function call: ${functionCall.name}');
          // Send error response to the model
          responses.add(
            FunctionResponse(
              functionCall.name,
              {'error': "Unknown tool '${functionCall.name}'"},
              id: functionCall.id,
            ),
          );
        }
      }
      // Send all tool responses back to the model in one batch
      if (responses.isNotEmpty) {
        _session?.sendToolResponse(responses);
        logger.i("Sent ${responses.length} tool response(s).");
      }
    } else if (message is LiveServerContent) {
      // As soon as we receive something, stop recording to avoid overlap.
      if (_isRecording) {
        await _stopRecording();
        await Future.delayed(const Duration(milliseconds: 100));
      }
      logger.i("1st Turn Complete: ${message.turnComplete}");
      if (message.modelTurn != null) {
        await _handleLiveServerContent(message, message.turnComplete);
      } else if (message.turnComplete == true) {
        // await _stopRecording();
        // await _audioResponsePlayer.playBuffered(_receivedAudioBuffer);
        // Poll every 10ms until playback completes, then (if conversation still active) restart recording.
        int pollCount = 0;
        const maxPollCount = 500; // 5 seconds max
        while (_conversationActive &&
            _audioResponsePlayer.player.state != PlayerState.completed &&
            _audioResponsePlayer.player.state != PlayerState.stopped &&
            _audioResponsePlayer.player.state != PlayerState.disposed &&
            pollCount < maxPollCount) {
          await Future.delayed(const Duration(milliseconds: 10));
          pollCount++;
        }

        if (pollCount >= maxPollCount) {
          logger.w("Playback polling timeout after ${pollCount * 10}ms");
        }

        logger.i(
          "Player state after waiting: ${_audioResponsePlayer.player.state.toString()}",
        );

        if (_conversationActive && !_isRecording) {
          try {
            await Future.delayed(const Duration(milliseconds: 200));
            await _startRecording();
          } catch (e) {
            logger.w("Failed to restart recording: $e");
            // If recording fails (e.g., audio focus lost), end conversation
            await _endConversation();
          }
        }
      }
    } else {
      logger.w("Unhandled message type: ${message.runtimeType}");
    }
  }

  Future<void> _handleLiveServerContent(
    LiveServerContent response,
    bool? hasCompletedMessage,
  ) async {
    final partList = response.modelTurn?.parts;
    if (partList != null) {
      for (final part in partList) {
        if (part is InlineDataPart) {
          await _handleInlineDataPart(part, hasCompletedMessage);
        } else {
          logger.w('receive part with unknown type ${part.runtimeType}');
        }
      }
    } else {
      logger.w("No parts in model turn.");
    }
  }

  Future<void> _handleInlineDataPart(
    InlineDataPart part,
    bool? hasCompletedMessage,
  ) async {
    if (part.mimeType.startsWith('audio')) {
      logger.i("Handling audio part with mimeType: ${part.mimeType}");
      final audioBytes = part.bytes;
      logger.i("Enqueueing audio chunk of size: ${audioBytes.length}");
      // previously: _receivedAudioBuffer.add(audioBytes);
      _audioResponsePlayer.enqueue(audioBytes);
    } else {
      logger.w(
        "Unhandled InlineDataPart mimeType, does not include audio: ${part.mimeType}",
      );
    }
  }

  // Remove after testing
  void _onAttitudeChanged() {
    attitude = _postureViewModel.attitude;
    /* logger.i(
        'Attitude changed - Roll: ${attitude.roll}, Pitch: ${attitude.pitch}, Yaw: ${attitude.yaw}',
      ); */
  }

  @override
  void dispose() {
    _animationController.dispose();
    _heartRateSubscription?.cancel();
    _buttonSubscription?.cancel();
    _postureViewModel.removeListener(_onAttitudeChanged);
    _postureViewModel.stopTracking();
    _skinTempSubscription?.cancel();
    super.dispose();
  }

  //============================================================================
  // BUILD WIDGET/UI
  //============================================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("EarGPT Sensor Debug Page"),
      ),
      floatingActionButton: FloatingActionButton.large(
        foregroundColor: _conversationActive ? Colors.white : Colors.green,
        backgroundColor: _conversationActive ? Colors.red : Colors.white,
        onPressed: () {
          _conversationActive ? _endConversation() : _startConversation();
        },
        child: _conversationActive
            ? const Icon(Icons.stop_circle)
            : const Icon(Icons.play_circle),
      ),
      body: Padding(
        padding: EdgeInsets.symmetric(horizontal: 10),
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Column(
                  children: [
                    PlatformText(
                      "Heart Rate: ${_cachedHeartRate?.toStringAsFixed(1) ?? '--'} BPM\n"
                      "Skin Temp: ${_cachedSkinTemp?.toStringAsFixed(1) ?? '--'} °C",
                      style: Theme.of(context).textTheme.titleLarge,
                      softWrap: true,
                      textAlign: TextAlign.center,
                    ),
                    SizedBox(height: 16),
                    FloatingActionButton.extended(
                      onPressed: () => {},
                      label: PlatformText(
                        "Session active: ${_conversationActive ? "Yes" : "No"}",
                      ),
                      foregroundColor:
                          _conversationActive ? Colors.white : Colors.white,
                      backgroundColor:
                          _conversationActive ? Colors.red : Colors.lightGreen,
                    ),
                    SizedBox(height: 16),
                    Lottie.asset(
                      'lib/apps/eargpt_gemini_live/assets/loading.json',
                      width: 200,
                      height: 200,
                      controller: _animationController,
                      onLoaded: (composition) {
                        // Configure the AnimationController with the duration of the
                        // Lottie file and sync with recording state.
                        _animationController.duration = composition.duration;
                        _syncAnimationWithRecordingState();
                      },
                    ),
                    SizedBox(height: 16),
                    FloatingActionButton.extended(
                      onPressed: () => {},
                      label: PlatformText(
                        _conversationActive
                            ? _isRecording
                                ? "Listening..."
                                : "Talking..."
                            : "Inactive",
                      ),
                      foregroundColor:
                          _isRecording ? Colors.white : Colors.black,
                      backgroundColor: _isRecording ? Colors.red : Colors.white,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
