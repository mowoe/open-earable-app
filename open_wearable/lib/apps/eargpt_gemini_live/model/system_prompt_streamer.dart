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
      
        yield "You are a personal fitness assistant \n running on a wearable \n ear smart device.\n The users current heart rate is:\n ${hr.toStringAsFixed(1)} BPM\n and skin temperature is: \n ${temp.toStringAsFixed(1)} °C.";
      }
    }
  }
}