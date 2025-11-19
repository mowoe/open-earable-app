import 'package:flutter/material.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:open_earable_flutter/open_earable_flutter.dart';
import 'package:open_wearable/apps/heart_tracker/model/ppg_filter.dart';
import 'package:open_wearable/apps/heart_tracker/widgets/rowling_chart.dart';
import 'package:open_wearable/view_models/sensor_configuration_provider.dart';
import 'package:provider/provider.dart';
import 'package:open_wearable/apps/eargpt_gemini_live/model/system_prompt_streamer.dart';

class EargptSensorDebugPage extends StatefulWidget {
  final Sensor? ppgSensor;

  const EargptSensorDebugPage({super.key, required this.ppgSensor});

  @override
  State<EargptSensorDebugPage> createState() => _EargptSensorDebugPageState();
}

class _EargptSensorDebugPageState extends State<EargptSensorDebugPage> {

  late final PpgFilter ppgFilter;
  late final SystemPromptStreamer systemPromptStreamer;

  @override
  void initState() {
    super.initState();

    final sensor = widget.ppgSensor;

    double sampleFreq = 25;

      setState(() {
        if (sensor != null ) {
          ppgFilter = PpgFilter(
            inputStream: sensor.sensorStream.asyncMap((data) {
              SensorDoubleValue sensorData = data as SensorDoubleValue;
              logger.i("Received PPG Data: ${sensorData.values} at ${sensorData.timestamp}");
              return (
                sensorData.timestamp,
                -(sensorData.values[2] + sensorData.values[3])
              );
            }).asBroadcastStream(),
            sampleFreq: sampleFreq,
            timestampExponent: sensor.timestampExponent,
          );
        }

        systemPromptStreamer = SystemPromptStreamer(
          heartRateStream: sensor != null ? ppgFilter.heartRateStream : Stream<double>.periodic(
            Duration(seconds: 1),
            (count) => 60 + (count % 40), // Dummy heart rate values
          ),
          skinTemperatureStream: Stream<double>.periodic(
            Duration(seconds: 1),
            (count) => 36.5 + (count % 5) * 0.1, // Dummy skin temperature values
          ),
        );
      });
  }

  @override
  Widget build(BuildContext context) {
    return PlatformScaffold(
      appBar: PlatformAppBar(
        title: PlatformText("EarGPT Sensor Debug Page"),
      ),
      body: Padding(
        padding: EdgeInsets.symmetric(horizontal: 10),
        child: Center(
            child:StreamBuilder<String>(
              stream: systemPromptStreamer.systemPromptStream,
              builder: (context, snapshot) {
                return Padding(
                  padding: EdgeInsets.all(10),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      PlatformText(
                        "${snapshot.data ?? "--"} \n ()",
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ],
                  ),
                );
              },
          ),
          )
      ),
    );
  }
}