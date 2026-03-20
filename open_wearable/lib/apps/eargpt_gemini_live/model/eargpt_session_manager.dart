import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:firebase_ai/firebase_ai.dart';
import 'package:open_wearable/apps/eargpt_gemini_live/model/audio_player.dart';
import 'package:open_wearable/models/logger.dart';
import 'package:record/record.dart';

/// Manages Gemini Live session lifecycle, recording, and message handling
class GeminiSessionManager {
  final LiveGenerativeModel model;
  final Map<String, Future<Map<String, Object?>> Function()> toolExecutors;
  final Function()? onConversationStateChanged;
  final Function()? onRecordingStateChanged;
  final Function()? onPersistVitals;

  LiveSession? _session;
  final AudioRecorder _recorder = AudioRecorder();
  final List<Uint8List> _receivedAudioBuffer = [];
  final AudioResponsePlayer _audioResponsePlayer = AudioResponsePlayer();

  bool _isRecording = false;
  bool _conversationActive = false;

  GeminiSessionManager({
    required this.model,
    required this.toolExecutors,
    this.onConversationStateChanged,
    this.onRecordingStateChanged,
    this.onPersistVitals,
  });

  // Getters
  bool get isRecording => _isRecording;
  bool get conversationActive => _conversationActive;
  AudioResponsePlayer get audioResponsePlayer => _audioResponsePlayer;

  //============================================================================
  // SESSION LIFECYCLE
  //============================================================================

  Future<void> initSession() async {
    try {
      _session = await model.connect();
      _conversationActive = true;
      onConversationStateChanged?.call();
      logger.i("Gemini session initialized");
    } catch (e) {
      logger.w('Failed to initialize model session: $e');
      rethrow;
    }
  }

  Future<void> startConversation() async {
    await initSession();
    await startRecording();
  }

  Future<void> endConversation() async {
    logger.i("Ending conversation...");
    _conversationActive = false;
    _session?.close();
    await stopRecording();
    await onPersistVitals?.call();
    _receivedAudioBuffer.clear();
    await _audioResponsePlayer.stopAndClear();
    onConversationStateChanged?.call();
    logger.i("Cleared audio buffer on conversation end.");
  }

  //============================================================================
  // RECORDING CONTROL
  //============================================================================

  Future<void> startRecording() async {
    if (_isRecording) return;

    if (_audioResponsePlayer.player.state == PlayerState.playing) {
      return;
    }

    logger.i("Starting recording...");
    _isRecording = true;
    onRecordingStateChanged?.call();

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
        _isRecording = false;
        onRecordingStateChanged?.call();
        rethrow;
      }
    } else {
      logger.w("Recording permission denied");
      _isRecording = false;
      onRecordingStateChanged?.call();
      throw Exception("Recording permission denied");
    }
  }

  Future<void> stopRecording() async {
    logger.i("Stopping recording...");
    if (_isRecording) {
      final _ = await _recorder.stop();
      _isRecording = false;
      onRecordingStateChanged?.call();
    } else {
      logger.i("Recording already stopped.");
    }
  }

  //============================================================================
  // AUDIO STREAMING LOOPS
  //============================================================================

  Future<void> _sendAudioLoop(Stream<Uint8List> audioStream) async {
    logger.i("Sending audio to Gemini...");
    await for (final data in audioStream) {
      if (!_conversationActive) {
        break;
      }
      await _session?.sendAudioRealtime(InlineDataPart('audio/pcm', data));
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
        _conversationActive = false;
        onConversationStateChanged?.call();
        await stopRecording();
        await _audioResponsePlayer.stopAndClear();
      }
    } catch (e) {
      // Stream errored (session closed unexpectedly)
      logger.w("Session stream error: $e");
      if (_conversationActive) {
        _conversationActive = false;
        onConversationStateChanged?.call();
        await stopRecording();
        await _audioResponsePlayer.stopAndClear();
      }
    }
  }

  //============================================================================
  // MESSAGE HANDLING
  //============================================================================

  Future<void> _handleLiveServerMessage(LiveServerResponse response) async {
    final message = response.message;

    logger.i("Response message type: $message");

    if (message is LiveServerToolCall &&
        message.functionCalls?.isNotEmpty == true) {
      await _handleToolCalls(message.functionCalls!);
    } else if (message is LiveServerContent) {
      await _handleServerContent(message);
    } else {
      logger.w("Unhandled message type: ${message.runtimeType}");
    }
  }

  Future<void> _handleToolCalls(List<FunctionCall> functionCalls) async {
    final responses = <FunctionResponse>[];

    for (final functionCall in functionCalls) {
      logger.w("Received tool call: ${functionCall.name}");

      final executor = toolExecutors[functionCall.name];
      if (executor != null) {
        try {
          final result = await executor();
          responses.add(
            FunctionResponse(functionCall.name, result, id: functionCall.id),
          );
          logger.i(
            "Prepared function response for ${functionCall.name}: $result",
          );
        } catch (e) {
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
        logger.w('Unknown function call: ${functionCall.name}');
        responses.add(
          FunctionResponse(
            functionCall.name,
            {'error': "Unknown tool '${functionCall.name}'"},
            id: functionCall.id,
          ),
        );
      }
    }

    if (responses.isNotEmpty) {
      _session?.sendToolResponse(responses);
      logger.i("Sent ${responses.length} tool response(s).");
    }
  }

  Future<void> _handleServerContent(LiveServerContent message) async {
    // As soon as we receive something, stop recording to avoid overlap.
    if (_isRecording) {
      await stopRecording();
      await Future.delayed(const Duration(milliseconds: 100));
    }

    logger.i("Turn Complete: ${message.turnComplete}");

    if (message.modelTurn != null) {
      await _processModelTurn(message);
    } else if (message.turnComplete == true) {
      await _waitForPlaybackAndRestartRecording();
    }
  }

  Future<void> _processModelTurn(LiveServerContent message) async {
    final partList = message.modelTurn?.parts;
    if (partList != null) {
      for (final part in partList) {
        if (part is InlineDataPart) {
          await _handleInlineDataPart(part);
        } else {
          logger.w('Receive part with unknown type ${part.runtimeType}');
        }
      }
    } else {
      logger.w("No parts in model turn.");
    }
  }

  Future<void> _handleInlineDataPart(InlineDataPart part) async {
    if (part.mimeType.startsWith('audio')) {
      logger.i("Handling audio part with mimeType: ${part.mimeType}");
      final audioBytes = part.bytes;
      logger.i("Enqueueing audio chunk of size: ${audioBytes.length}");
      _audioResponsePlayer.enqueue(audioBytes);
    } else {
      logger.w(
        "Unhandled InlineDataPart mimeType, does not include audio: ${part.mimeType}",
      );
    }
  }

  Future<void> _waitForPlaybackAndRestartRecording() async {
    // Poll every 10ms until playback completes
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

    // Restart recording if conversation is still active
    if (_conversationActive && !_isRecording) {
      try {
        await Future.delayed(const Duration(milliseconds: 200));
        await startRecording();
      } catch (e) {
        logger.w("Failed to restart recording: $e");
        await endConversation();
      }
    }
  }

  //============================================================================
  // CLEANUP
  //============================================================================

  void dispose() {
    _session?.close();
    _recorder.dispose();
    _audioResponsePlayer.dispose();
  }
}
