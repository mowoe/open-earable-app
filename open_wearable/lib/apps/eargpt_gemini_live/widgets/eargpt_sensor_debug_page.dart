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
import 'dart:typed_data';

class EargptSensorDebugPage extends StatefulWidget {
  final Sensor? ppgSensor;

  const EargptSensorDebugPage({super.key, required this.ppgSensor});

  @override
  State<EargptSensorDebugPage> createState() => _EargptSensorDebugPageState();
}

class _EargptSensorDebugPageState extends State<EargptSensorDebugPage> {
  late final PpgFilter ppgFilter;
  late final SystemPromptStreamer systemPromptStreamer;
  late final Stream<String> _systemPromptStream;

  final fakeHeartRateStream = Stream<double>.periodic(
    Duration(seconds: 1),
    (count) => 60 + (count % 40),
  ).asBroadcastStream();

  Future<Map<String, Object?>> fetchHeartrate() async {

    double currentHR = await (widget.ppgSensor != null ? ppgFilter.heartRateStream : fakeHeartRateStream).first;

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

    logger.i("Starting recording...");
    setState(() => _isRecording = true);

    if (await _recorder.hasPermission()) {
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
    }
  }

  Future<void> _stopRecording() async {
    logger.i("Stopping recording...");
    if (_isRecording) {
      final _ = await _recorder.stop();
      setState(() {
        _isRecording = false;
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
    await for (final message in _session!.receive()) {
      if (!_conversationActive) {
        break;
      }
      logger.i("Received message from Gemini: $message");

      await _handleLiveServerMessage(message);
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
      if (_isRecording) {await _stopRecording();}
      logger.i("1st Turn Complete: ${message.turnComplete}");
      if (message.modelTurn != null) {
        await _handleLiveServerContent(message, message.turnComplete);
      } else if (message.turnComplete == true) {
        // await _stopRecording();
        // await _audioResponsePlayer.playBuffered(_receivedAudioBuffer);
        // Poll every 10ms until playback completes, then (if conversation still active) restart recording.
        while (_audioResponsePlayer.player.state != PlayerState.completed) {
          await Future.delayed(const Duration(milliseconds: 10));
        }
        if (_conversationActive) {
          logger.i("Player state: ${_audioResponsePlayer.player.state.toString()}");
          await _startRecording();
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

    final sensor = widget.ppgSensor;

    double sampleFreq = 25;

    // Do not call setState in initState; assign fields directly.
    if (sensor != null ) {
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
    } else {
      // If sensor is null, create a dummy ppgFilter or handle appropriately.
      // For now keep a minimal dummy stream for heartRate usage in SystemPromptStreamer
      ppgFilter = PpgFilter(
        inputStream: Stream<(int, double)>.empty(),
        sampleFreq: sampleFreq,
        timestampExponent: 0,
      );
    }

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

    // Store a single stream instance to avoid re-subscribing on rebuilds.
    _systemPromptStream = systemPromptStreamer.systemPromptStream.asBroadcastStream();

    model = FirebaseAI.googleAI().liveGenerativeModel(
    model: 'gemini-2.0-flash-live-001',
    systemInstruction: Content.system(
        '''You are a personal health AI assistant integrated with OpenEarable smart earbuds. You have access to real-time biometric data from the user's ear-based sensors. Keep responses concise and relevant to the user's health and activity.
        Use provided tool to get users current heart rate.'''),
    tools: [Tool.functionDeclarations([fetchHeartrateTool])],
    liveGenerationConfig:
        LiveGenerationConfig(responseModalities: [ResponseModalities.audio]),
  );
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
                      FloatingActionButton.extended(
                        onPressed: () => {}, 
                        label: _isRecording ? PlatformText("Listening...") : PlatformText("Talking..."),
                        foregroundColor: _isRecording ? Colors.white : Colors.black,
                        backgroundColor: _isRecording ? Colors.red : Colors.white,
                        ),
                      PlatformText(
                        "Current system prompt: \n${snapshot.data ?? "--"} \n",
                        style: Theme.of(context).textTheme.titleLarge,
                        softWrap: true,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      FloatingActionButton.extended(
                        onPressed: () => {}, 
                        label: _isRecording ? PlatformText("Listening...") : PlatformText("Talking...")
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