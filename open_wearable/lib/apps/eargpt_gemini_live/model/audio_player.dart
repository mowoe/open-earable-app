import 'package:open_earable_flutter/open_earable_flutter.dart';
import 'package:audioplayers/audioplayers.dart';
import 'dart:typed_data';

class AudioResponsePlayer {
  final AudioPlayer _player = AudioPlayer();
  final List<Uint8List> _queue = [];
  bool _processing = false;

  AudioPlayer get player => _player;

  /// Enqueue a single PCM chunk (raw bytes) to be played as soon as possible.
  void enqueue(Uint8List chunk) {
    _queue.add(chunk);
    if (!_processing) {
      _processQueue();
    }
  }

  /// Enqueue multiple chunks.
  void enqueueAll(List<Uint8List> chunks) {
    if (chunks.isEmpty) return;
    _queue.addAll(chunks);
    if (!_processing) {
      _processQueue();
    }
  }

  /// Stop playback and clear queued chunks.
  Future<void> stopAndClear() async {
    _queue.clear();
    await _player.stop();
  }

  /// Dispose underlying player.
  Future<void> dispose() async {
    await _player.release();
    await _player.dispose();
  }

  Future<void> _processQueue() async {
    if (_processing) return;
    _processing = true;
    try {
      while (_queue.isNotEmpty) {
        // Grab a snapshot of current queued chunks and clear queue atomically.
        final batch = List<Uint8List>.from(_queue);
        _queue.clear();

        final wav = _buildWavFromPcmChunks(batch);
        if (wav.isEmpty) continue;

        // Play the combined WAV bytes
        await _player.play(BytesSource(wav));

        // Wait for playback to finish. Prefer the onPlayerComplete stream, fall back to polling.
        try {
          await _player.onPlayerComplete.first.timeout(const Duration(seconds: 30));
        } catch (_) {
          // If onPlayerComplete is not available or times out, poll state.
          while (_player.state != PlayerState.completed && _player.state != PlayerState.stopped) {
            await Future.delayed(const Duration(milliseconds: 20));
          }
        }
      }
    } finally {
      _processing = false;
    }
  }

  Uint8List _buildWavFromPcmChunks(List<Uint8List> chunks) {
    if (chunks.isEmpty) return Uint8List(0);

    final totalLength = chunks.fold<int>(0, (s, c) => s + c.length);
    final bytesBuilder = BytesBuilder(copy: false);
    for (final c in chunks) bytesBuilder.add(c);
    final combined = bytesBuilder.toBytes();

    // WAV header parameters - match your recorder settings (recorder uses 16000, 16-bit, mono).
    const sampleRate = 24000;
    const channels = 1;
    const bitsPerSample = 16;

    Uint8List u32LE(int value) {
      final b = ByteData(4);
      b.setUint32(0, value, Endian.little);
      return b.buffer.asUint8List();
    }

    Uint8List u16LE(int value) {
      final b = ByteData(2);
      b.setUint16(0, value, Endian.little);
      return b.buffer.asUint8List();
    }

    final byteRate = sampleRate * channels * (bitsPerSample ~/ 8);
    final blockAlign = channels * (bitsPerSample ~/ 8);

    final header = BytesBuilder();
    header.add([82, 73, 70, 70]); // "RIFF"
    header.add(u32LE(36 + combined.length));
    header.add([87, 65, 86, 69]); // "WAVE"
    header.add([102, 109, 116, 32]); // "fmt "
    header.add(u32LE(16)); // subchunk1 size
    header.add(u16LE(1)); // PCM format
    header.add(u16LE(channels));
    header.add(u32LE(sampleRate));
    header.add(u32LE(byteRate));
    header.add(u16LE(blockAlign));
    header.add(u16LE(bitsPerSample));
    header.add([100, 97, 116, 97]); // "data"
    header.add(u32LE(combined.length));
    header.add(combined);

    return header.toBytes();
  }
}