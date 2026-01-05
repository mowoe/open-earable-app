import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:open_earable_flutter/open_earable_flutter.dart';
import 'package:open_wearable/apps/heart_tracker/model/ppg_filter.dart';
import 'package:open_wearable/apps/heart_tracker/widgets/rowling_chart.dart';
import 'package:open_wearable/view_models/sensor_configuration_provider.dart';
import 'package:provider/provider.dart';
import 'package:open_wearable/apps/eargpt_gemini_live/model/system_prompt_streamer.dart';
import 'package:open_wearable/apps/eargpt_gemini_live/model/audio_player.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

class EargptSensorDebugPage extends StatefulWidget {
  final Sensor? ppgSensor;
  final Wearable? wearable;

  const EargptSensorDebugPage({super.key, required this.ppgSensor, required this.wearable});

  @override
  State<EargptSensorDebugPage> createState() => _EargptSensorDebugPageState();
}

class _EargptSensorDebugPageState extends State<EargptSensorDebugPage> with TickerProviderStateMixin {
  late final PpgFilter ppgFilter;
  late final SystemPromptStreamer systemPromptStreamer;
  late final Stream<String> _systemPromptStream;
  late final AnimationController _animationController;

  final fakeHeartRateStream = Stream<double>.periodic(
    Duration(seconds: 1),
    (count) => 60 + (count % 40),
  ).asBroadcastStream();

  Future<Map<String, Object?>> fetchHeartrate() async {
    double currentHR = _cachedHeartRate ?? 0.0;

    logger.i("Model requested heartrate... $currentHR");

    return {"heart_rate": "$currentHR BPM"};
  }

  final fetchHeartrateTool = FunctionDeclaration(
    'fetchHeartrate',
    'Get the users current heartrate from the earable device.',
    parameters: {},
  );

  late final LiveGenerativeModel model;

  LiveSession? _session;
  final AudioRecorder _recorder = AudioRecorder();
  final List<Uint8List> _receivedAudioBuffer = [];
  final AudioResponsePlayer _audioResponsePlayer = AudioResponsePlayer();
  bool _isRecording = false;
  bool _conversationActive = false;
  double? _cachedHeartRate;
  StreamSubscription<double>? _heartRateSubscription;

  // Button handling
  StreamSubscription<ButtonEvent>? _buttonSubscription;
  bool _buttonPressed = false;

  void _syncAnimationWithRecordingState() {
    if (_isRecording && _animationController.isAnimating) {
      //_animationController.reverse();
      //_animationController.repeat();
      //_animationController.stop();
      //_animationController.reset();
      _animationController.animateBack(0.0);
      
    } else if (!_isRecording && !_animationController.isAnimating && _conversationActive) {
      _animationController.forward();
      _animationController.repeat();
      //_animationController.fling(velocity: 1.0);
    } else if (!_conversationActive && _animationController.isAnimating) {
      _animationController.stop();
      _animationController.reset();
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
    _stopRecording();
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

  Future<void> _handleLiveServerMessage(LiveServerResponse response) async {
    final message = response.message;

    logger.i("Response message type: $message");

    if (message is LiveServerToolCall && message.functionCalls?.isNotEmpty == true) {
      final functionCalls = message.functionCalls!;
      for (final functionCall in functionCalls) {
        logger.w("Received tool call: ${functionCall.name}");
        if (functionCall.name == 'fetchHeartrate') {
          final functionResult = await fetchHeartrate();

          _session?.sendToolResponse(
            [
              FunctionResponse(functionCall.name, functionResult,
                  id: functionCall.id)
            ],
          );
          
          logger.i("Sent function response for ${functionCall.name}: $functionResult");
        } else {
          logger.w('Unknown function call: ${functionCall.name}');
        }
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
        
        logger.i("Player state after waiting: ${_audioResponsePlayer.player.state.toString()}");
        
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

  Future<void> _initSession() async {
    try {
      _session = await model.connect();
      _conversationActive = true;
    } catch (e) {
      logger.w('Failed to initialize model session: $e');
    }
  }

  Future<void> _handleLiveServerContent(LiveServerContent response, bool? hasCompletedMessage) async {
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
      InlineDataPart part, bool? hasCompletedMessage) async {
    if (part.mimeType.startsWith('audio')) {
      logger.i("Handling audio part with mimeType: ${part.mimeType}");
      final audioBytes = part.bytes;
      logger.i("Enqueueing audio chunk of size: ${audioBytes.length}");
      // previously: _receivedAudioBuffer.add(audioBytes);
      _audioResponsePlayer.enqueue(audioBytes);
    } else {
      logger.w("Unhandled InlineDataPart mimeType, does not include audio: ${part.mimeType}");
    }
  }

  @override
  void initState() {
    super.initState();

    _animationController = AnimationController(vsync: this);

    final sensor = widget.ppgSensor;

    double sampleFreq = 25;

    // Do not call setState in initState; assign fields directly.
    if (sensor != null ) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
            SensorConfigurationProvider configProvider = Provider.of<SensorConfigurationProvider>(context, listen: false);
            SensorConfiguration configuration = sensor.relatedConfigurations.first;

            if (configuration is ConfigurableSensorConfiguration &&
                configuration.availableOptions.contains(StreamSensorConfigOption())) {
                configProvider.addSensorConfigurationOption(configuration, StreamSensorConfigOption());
            }

            List<SensorConfigurationValue> values = configProvider.getSensorConfigurationValues(configuration, distinct: true);
            configProvider.addSensorConfiguration(configuration, values.first);
            SensorConfigurationValue selectedValue = configProvider.getSelectedConfigurationValue(configuration)!;
            configuration.setConfiguration(selectedValue);

            double sampleFreq;
            if (selectedValue is SensorFrequencyConfigurationValue) {
                sampleFreq = selectedValue.frequencyHz;
            } else {
                sampleFreq = 25;
            }
            setState(() {
            logger.w("Here!");
                ppgFilter = PpgFilter(
                    inputStream: sensor.sensorStream.asyncMap((data) {
                    SensorDoubleValue sensorData = data as SensorDoubleValue;
                    return (
                        sensorData.timestamp,
                        -(sensorData.values[2] + sensorData.values[3])
                    );
                    }).asBroadcastStream(),
                    sampleFreq: sampleFreq,
                    timestampExponent: sensor.timestampExponent,
                );
            logger.w("ppgFilter init done!");
            systemPromptStreamer = SystemPromptStreamer(
                heartRateStream: ppgFilter.heartRateStream,
                skinTemperatureStream: Stream<double>.periodic(
                    Duration(seconds: 1),
                    (count) => 36.5 + (count % 5) * 0.1,
                ),
            );
            _systemPromptStream = systemPromptStreamer.systemPromptStream.asBroadcastStream();
                // Subscribe to heart rate stream to cache values
            final heartRateStream = ppgFilter.heartRateStream;
            _heartRateSubscription = heartRateStream.listen((heartRate) {
                _cachedHeartRate = heartRate;
            });
            
            });
        });
    } else {
      // If sensor is null, create a dummy ppgFilter or handle appropriately.
      // For now keep a minimal dummy stream for heartRate usage in SystemPromptStreamer
      ppgFilter = PpgFilter(
        inputStream: Stream<(int, double)>.empty(),
        sampleFreq: sampleFreq,
        timestampExponent: 0,
      );
      systemPromptStreamer = SystemPromptStreamer(
      heartRateStream: sensor != null ? ppgFilter.heartRateStream : Stream<double>.periodic(
        Duration(seconds: 1),
        (count) => 60 + (count % 40),
      ),
      skinTemperatureStream: Stream<double>.periodic(
        Duration(seconds: 1),
        (count) => 36.5 + (count % 5) * 0.1,
      ),
        );
        _systemPromptStream = systemPromptStreamer.systemPromptStream.asBroadcastStream();
            // Subscribe to heart rate stream to cache values
    final heartRateStream = sensor != null ? ppgFilter.heartRateStream : fakeHeartRateStream;
    _heartRateSubscription = heartRateStream.listen((heartRate) {
      _cachedHeartRate = heartRate;
    });
    }

    

    // Store a single stream instance to avoid re-subscribing on rebuilds.
    



    model = FirebaseAI.googleAI().liveGenerativeModel(
    model: 'gemini-2.5-flash-native-audio-preview-12-2025',
    systemInstruction: Content.system(
        '''You are a personal health AI assistant integrated with OpenEarable smart earbuds. You have access to real-time biometric data from the user's ear-based sensors. Keep responses concise and relevant to the user's health and activity.
        Use provided tool to get users current heart rate.'''),
    tools: [Tool.functionDeclarations([fetchHeartrateTool])],
    liveGenerationConfig:
        LiveGenerationConfig(responseModalities: [ResponseModalities.audio]),
  );
  
  _setupButtonListener();
  }

  void _setupButtonListener() {
    if (widget.wearable != null && widget.wearable is ButtonManager) {
      _buttonSubscription = (widget.wearable as ButtonManager).buttonEvents.listen((event) {
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



  @override
  void dispose() {
    _animationController.dispose();
    _heartRateSubscription?.cancel();
    _buttonSubscription?.cancel();
    super.dispose();
  }

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
        child: _conversationActive ? const Icon(Icons.stop_circle) : const Icon(Icons.play_circle),
      ),
      body: Padding(
        padding: EdgeInsets.symmetric(horizontal: 10),
        child: Center(
            child:StreamBuilder<String>(
              stream: _systemPromptStream,
              builder: (context, snapshot) {
                return Padding(
                  padding: EdgeInsets.all(10),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Column(
                        children: [
                          PlatformText(
                            // Current system prompt: 
                            "\n${snapshot.data ?? "--"} \n",
                            style: Theme.of(context).textTheme.titleLarge,
                            softWrap: true,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                          SizedBox(height: 16),
                          FloatingActionButton.extended(
                            onPressed: () => {}, 
                            label: PlatformText("Session active: ${_conversationActive ? "Yes" : "No"}"),
                            foregroundColor: _conversationActive ? Colors.white : Colors.white,
                            backgroundColor: _conversationActive ? Colors.red : Colors.lightGreen,
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
                            label: PlatformText("${_conversationActive ? _isRecording ? "Listening..." : "Talking..." : "Inactive"}"),
                            foregroundColor: _isRecording ? Colors.white : Colors.black,
                            backgroundColor: _isRecording ? Colors.red : Colors.white,
                          )
                        ],
                      ),
                    ],
                  ),
                );
              },
          ),
          ),
      ),
    );
  }
}