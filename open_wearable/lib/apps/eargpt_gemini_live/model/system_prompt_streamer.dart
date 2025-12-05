class SystemPromptStreamer {
  final Stream<double> heartRateStream;
  final Stream<double> skinTemperatureStream;

  SystemPromptStreamer({
    required this.heartRateStream,
    required this.skinTemperatureStream,
  });

  Stream<String> get systemPromptStream async* {
    await for (final temp in skinTemperatureStream) {
      await for (final hr in heartRateStream) {
      
        yield "The users current heart rate is: ${hr.toStringAsFixed(1)} BPM and skin temperature is: ${temp.toStringAsFixed(1)} °C.";
      }
    }
  }
}