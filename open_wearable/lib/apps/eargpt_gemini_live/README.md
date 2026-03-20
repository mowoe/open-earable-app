# EarGemini

## Table of Contents

1. [Overview](#overview)
2. [Project Context](#project-context)
3. [System Architecture](#system-architecture)
4. [Component Reference](#component-reference)
   - [EarGPT Page (eargpt_sensor_debug_page.dart)](#eargpt-page)
   - [Session Manager (eargpt_session_manager.dart)](#session-manager)
   - [Audio Player (audio_player.dart)](#audio-player)
   - [Sensor Manager (eargpt_sensor_manager.dart)](#sensor-manager)
   - [Tools (eargpt_tools.dart)](#tools)
   - [Data Persistence (data_persistence.dart)](#data-persistence)
   - [App Data Storage (app_data_storage.dart)](#app-data-storage)
5. [Supporting Infrastructure Changes](#supporting-infrastructure-changes)
   - [Posture Tracker Calibration Persistence](#posture-tracker-calibration-persistence)
   - [Firebase / Gemini Integration](#firebase--gemini-integration)
6. [Data Flow](#data-flow)
7. [Dependency Overview](#dependency-overview)
8. [Setup and Configuration](#setup-and-configuration)

---

## Overview

EarGPT is an in-app voice assistant integrated into the OpenWearable Flutter application. It uses the **Google Gemini Live API** (via Firebase AI) to conduct real-time, bidirectional voice conversations with the user while continuously exposing biometric sensor data — heart rate, skin temperature, and posture — as callable tools that the AI model can invoke on demand.

The assistant is activated either by pressing the button on the OpenEarable device or via a floating action button in the app UI. Once active, the app streams PCM audio from the microphone to Gemini, receives streamed audio responses back, and plays them through the device speaker. Between turns, sensor readings cached by the Sensor Manager are made available to the model through a structured tool-use interface.

---

## Project Context

This module was developed as part of a university course assignment with the following stated goals:

- Develop a voice assistant that considers biometric signals from a wearable device.
- Handle audio input (Speech-to-Text) and audio output (Text-to-Speech) through the OpenEarable hardware.
- Extract information from bio signals and encode them in a form the LLM can consume.
- Integrate a large language model to generate contextually relevant, health-aware responses.

The solution uses the Gemini `gemini-2.5-flash-native-audio-preview` model, which natively supports real-time audio streaming (Live API) and function/tool calling. This allows the assistant to answer questions like _"What is my current heart rate?"_ or _"How has my skin temperature trended this week?"_ by dynamically invoking the appropriate data retrieval tool rather than relying on pre-injected context.

---

## System Architecture

The diagram below shows the dependency relationships between the main EarGPT components:

```
┌──────────────┐       ┌──────────────────────────┐
│  audio_player│◄──────│     session_manager      │
└──────────────┘       └──────────▲───────────────┘
                                  │
              ┌────────────────────────────────────┐
              │            eargpt_page             │  ← Entry point (StatefulWidget)
              └──┬──────────┬────────────┬─────────┘
                 │          │            │
        ┌────────▼──┐  ┌────▼───────┐  ┌─▼──────────────────┐
        │   tools   │  │  data_     │  │  sensor_manager    │
        │           ├─▶│persistence ├─▶│                    │
        └─────┬─────┘  └────────────┘  └────────▲───────────┘
              └─────────────────────────────────┘
```

The `eargpt_page` is the root widget and the single point that constructs and wires together all other components. It owns the `EarGPTSensorManager`, `GeminiSessionManager`, `EarGPTTools`, and `EarGPTDataPersistence` instances, passing references between them as needed.

---

## Component Reference

### EarGPT Page

**File:** `lib/apps/eargpt_gemini_live/widgets/eargpt_sensor_debug_page.dart`

This is the top-level `StatefulWidget` that acts as the composition root for the entire EarGPT feature. It is registered as an app tile in the main `AppsPage` and receives hardware references (PPG sensor, skin temperature sensor, attitude tracker, and wearable) as constructor parameters from the app launcher.

**Responsibilities:**

- Instantiates `EarGPTSensorManager`, `EarGPTTools`, `EarGPTDataPersistence`, `GeminiSessionManager`, and the Lottie `AnimationController`.
- Configures the `LiveGenerativeModel` with a health-focused system instruction and the full list of tool declarations from `EarGPTTools`.
- Calls `_sensorManager.initialize(context)` asynchronously after the first frame to avoid blocking the widget tree.
- Registers a hardware button listener via `_sensorManager.setupButtonListener`, so the earphone button can start or stop the conversation.
- Manages the animation state of the Lottie loading indicator to reflect whether the model is currently speaking (animating) or listening (stopped).
- Renders a minimal debug UI showing live heart rate, skin temperature, session state, and the animation.

**Conversation lifecycle triggered from this widget:**

```
Button pressed / FAB tapped
  └─► sessionManager.startConversation()
        ├─► initSession()   — opens Gemini Live WebSocket
        └─► startRecording() — begins microphone stream

Button pressed again / FAB tapped
  └─► sessionManager.endConversation()
        ├─► session.close()
        ├─► stopRecording()
        ├─► dataPersistence.persistLatestVitals()
        └─► audioResponsePlayer.stopAndClear()
```

---

### Session Manager

**File:** `lib/apps/eargpt_gemini_live/model/eargpt_session_manager.dart`

`GeminiSessionManager` encapsulates the full lifecycle of a single Gemini Live session. It is the sole component that interacts directly with the Firebase AI SDK (`LiveGenerativeModel`, `LiveSession`).

**Key responsibilities:**

**Session lifecycle** — `initSession()` calls `model.connect()` to open a persistent WebSocket connection to the Gemini Live endpoint. `endConversation()` closes the session, stops recording, triggers data persistence, and clears the audio buffer.

**Microphone streaming** — `startRecording()` uses the `record` package to open a PCM-16 stream at 16 kHz mono. The raw bytes are forwarded to Gemini in real time via `_session.sendAudioRealtime(InlineDataPart('audio/pcm', data))` inside `_sendAudioLoop`.

**Response reception** — `_receiveResponseLoop` runs concurrently with the send loop using `Future.wait`. It iterates over `_session!.receive()` and dispatches each message to `_handleLiveServerMessage`.

**Message dispatch** — Incoming server messages are routed by type:

- `LiveServerToolCall` → `_handleToolCalls()` — looks up each `FunctionCall.name` in the `toolExecutors` map, executes the corresponding function, and sends back a `FunctionResponse` via `_session.sendToolResponse`.
- `LiveServerContent` with audio parts → `_handleInlineDataPart()` — forwards raw audio bytes to `AudioResponsePlayer.enqueue()`.
- Turn-complete signal → `_waitForPlaybackAndRestartRecording()` — polls the player state and restarts the microphone once playback finishes.

**Turn management** — When the model begins speaking, recording is stopped immediately to prevent echo feedback. Recording resumes only after the `AudioResponsePlayer` reports `PlayerState.completed` or `PlayerState.stopped`.

---

### Audio Player

**File:** `lib/apps/eargpt_gemini_live/model/audio_player.dart`

`AudioResponsePlayer` wraps the `audioplayers` package to handle the sequential playback of streamed PCM audio chunks received from the Gemini Live API.

**Why a custom player is needed:** The Gemini Live API returns audio as a stream of raw PCM-16 byte chunks at 24 kHz mono. Standard audio players expect a complete file (e.g., WAV or MP3). This class accumulates all chunks received between model turn boundaries and assembles them into a valid WAV file in memory before handing off to `AudioPlayer`.

**Internal queue mechanism:**

- `enqueue(Uint8List chunk)` adds a chunk and triggers `_processQueue()` if not already processing.
- `_processQueue()` drains all currently queued chunks in a single batch (atomic snapshot), combines them into one WAV, plays it, and waits for playback to complete before processing the next batch.
- `stopAndClear()` halts playback and discards queued chunks, used when the conversation ends.

**WAV construction (`_buildWavFromPcmChunks`):** Builds a standard PCM WAV header (RIFF/WAVE/fmt/data) around the concatenated raw PCM bytes. Parameters are hard-coded to match the Gemini Live audio output specification: 24 kHz, 16-bit, mono.

---

### Sensor Manager

**File:** `lib/apps/eargpt_gemini_live/model/eargpt_sensor_manager.dart`

`EarGPTSensorManager` is responsible for initialising, configuring, and subscribing to all biometric sensor streams provided by the OpenEarable SDK. It acts as the single source of truth for live sensor data within the EarGPT feature.

**Managed sensors:**

- **PPG (Photoplethysmography):** Used to derive heart rate via the existing `PpgFilter` pipeline (band-pass filter + peak detection).
- **Optical Temperature Sensor:** Provides skin temperature readings.
- **Accelerometer (via AttitudeTracker):** Used by the `PostureTrackerViewModel` to compute head roll and pitch.

**Initialisation sequence (`initialize`):** To avoid race conditions during Flutter widget build, initialisation is deferred by 100 ms and proceeds in four sequential steps:

1. Configure sensor sample rates and streaming modes via `SensorConfigurationProvider`.
2. Initialise `PpgFilter` with the selected sample frequency.
3. Subscribe to PPG (heart rate) and skin temperature streams; cache the latest values.
4. Initialise and start `PostureTrackerViewModel`.

If any sensor reference is `null` (e.g., the app is started without a connected earable), the manager falls back to **dummy streams** — synthetic periodic streams that emit plausible fake values — so the UI and tool system remain functional for development and testing.

**Caching:** The latest heart rate (`_cachedHeartRate`) and skin temperature (`_cachedSkinTemp`) are stored as nullable doubles and updated on every sensor event. These cached values are what the `EarGPTTools` methods read when Gemini requests sensor data.

**Button listener:** `setupButtonListener` registers on the `ButtonManager` capability of the wearable, firing a callback when the earphone button is pressed.

---

### Tools

**File:** `lib/apps/eargpt_gemini_live/model/eargpt_tools.dart`

`EarGPTTools` defines and implements all Gemini function-calling tools that allow the AI model to retrieve biometric data. Each tool is declared as a `FunctionDeclaration` (for the model's schema) and has a corresponding Dart method (the executor).

**Available tools:**

| Tool Name | Description | Data Source |
| --- | --- | --- |
| `fetchHeartrate` | Current heart rate from live sensor stream | `SensorManager._cachedHeartRate` |
| `fetchSkinTemp` | Current skin temperature from live sensor stream | `SensorManager._cachedSkinTemp` |
| `fetchPosture` | Current head roll/pitch angles and posture quality assessment | `PostureTrackerViewModel.attitude` |
| `fetchLatestHeartRate` | Most recently persisted heart rate reading | `EarGPTDataPersistence` / `AppDataStorage` |
| `fetchLatestSkinTemp` | Most recently persisted skin temperature reading | `EarGPTDataPersistence` / `AppDataStorage` |
| `fetchWeeklyHeartRateSummary` | Average heart rate over the past 7 days | `EarGPTDataPersistence` / `AppDataStorage` |
| `fetchWeeklySkinTempSummary` | Average skin temperature over the past 7 days | `EarGPTDataPersistence` / `AppDataStorage` |

**Posture quality classification (`fetchPosture`):** Roll and pitch angles in radians are converted to degrees and compared against the user-configured thresholds in `BadPostureSettings`. The tool returns a `posture_quality` string (`"good"`, `"fair"`, or `"poor"`) alongside the raw angle values.

**Error handling:** Each executor throws a typed `Exception` if the required sensor is unavailable or data has not yet been received. The `GeminiSessionManager` catches these and returns an error payload to the model, allowing Gemini to communicate the issue to the user gracefully.

**Tool registration:** `getAllToolDeclarations()` returns all `FunctionDeclaration` objects and is called during model construction in `eargpt_page`. The `toolExecutors` getter returns a `Map<String, Future<Map<String, Object?>> Function()>` used by `GeminiSessionManager` for dispatch.

---

### Data Persistence

**File:** `lib/apps/eargpt_gemini_live/model/data_persistence.dart`

`EarGPTDataPersistence` manages the saving and loading of biometric history. It is called by `eargpt_page` at the end of each conversation session (via the `onPersistVitals` callback passed to `GeminiSessionManager`).

**Storage strategy:** Each vital is stored under a unique key in `AppDataStorage`. The stored object contains:

- `latest`: the single most recent reading (value, unit, ISO 8601 timestamp).
- `history`: a rolling list of all readings within the past 7 days (configurable via `historyDays`). Entries older than the cutoff are automatically pruned on each write.

**Public API:**

- `persistLatestVitals()` — saves both heart rate and skin temperature at conversation end.
- `loadLatestVital(key, unit)` — returns the most recently stored reading for a vital.
- `loadWeeklySummary(key, unit)` — computes and returns the arithmetic mean over all history entries within the 7-day window, along with count and time range.

These static methods are called directly by `EarGPTTools` to implement the `fetchLatestHeartRate`, `fetchLatestSkinTemp`, `fetchWeeklyHeartRateSummary`, and `fetchWeeklySkinTempSummary` tools.

---

### App Data Storage

**File:** `lib/view_models/app_data_storage.dart`

`AppDataStorage` is a general-purpose, app-scoped key-value persistence layer backed by a single JSON file (`app_data_store.json`) in the application documents directory. It was introduced to support both EarGPT data persistence and posture calibration persistence, and is designed to be reusable by any future in-app app.

**Data structure on disk:**

```json
{
  "eargpt_gemini_live": {
    "latest_heart_rate": { "latest": {...}, "history": [...] },
    "latest_skin_temperature": { "latest": {...}, "history": [...] }
  },
  "posture_tracker": {
    "calibration": { "referenceAttitude": { "roll": 0.0, "pitch": 0.0, "yaw": 0.0 } }
  }
}
```

**API:**

- `saveData(appName, key, data)` — writes or overwrites a JSON map at `store[appName][key]`.
- `loadData(appName, key)` — reads and returns `store[appName][key]` or `null` if absent.
- `deleteData(appName, key)` — removes a specific key; removes the app namespace if it becomes empty.
- `deleteAppData(appName)` — removes all data for an app.
- `getAppKeys(appName)` — lists all keys stored under an app namespace.

Corrupted or unreadable JSON files are handled gracefully: the file is reset to `{}` and a warning is logged.

---

## Supporting Infrastructure Changes

### Posture Tracker Calibration Persistence

As part of this project, the `AttitudeTracker` and `PostureTrackerViewModel` were extended to support persistent calibration across app sessions, using `AppDataStorage`.

- `AttitudeTracker.calibrateToCurrentAttitude()` now saves the reference attitude to storage via `saveCalibration()`.
- On initialisation, `PostureTrackerViewModel` calls `_attitudeTracker.loadCalibration()`. If a saved calibration is found, it is restored and `EarableAttitudeTracker.start()` skips overwriting it with the default hardcoded attitude.
- The posture settings UI now shows a "Saved calibration loaded" indicator and a "Clear" button to reset to factory defaults.
- `PostureCalibrationData` (new file) provides JSON serialisation and deserialisation for the reference `Attitude`.

### Firebase / Gemini Integration

The following infrastructure was added to support the Firebase AI SDK:

- `firebase_options.dart` — auto-generated by the FlutterFire CLI; provides platform-specific Firebase configuration.
- `google-services.json` (Android) and `GoogleService-Info.plist` (iOS) — platform configuration files for the Firebase project `eargpt-b0987`.
- `main.dart` — `Firebase.initializeApp()` is called at startup before the widget tree is inflated.
- `build.gradle` / `settings.gradle` — the `com.google.gms.google-services` Gradle plugin is applied.
- New dependencies in `pubspec.yaml`: `firebase_core`, `firebase_ai`, `record`, `audioplayers`, `lottie`, `confirm_dialog`.
- Platform plugin registrants (Linux, macOS, Windows) updated for `audioplayers` and `record`.

---

## Data Flow

The following describes a complete conversation turn from microphone to speaker:

```
1. User presses earphone button
   └─► eargpt_page._handleButtonPressed()
         └─► sessionManager.startConversation()
               ├─► model.connect()         [Firebase AI → Gemini Live WebSocket]
               └─► recorder.startStream()  [PCM-16 @ 16 kHz mono]

2. User speaks
   └─► _sendAudioLoop: audioStream bytes
         └─► session.sendAudioRealtime(InlineDataPart('audio/pcm', bytes))

3. Gemini processes speech; responds with tool call
   └─► _receiveResponseLoop → LiveServerToolCall
         └─► toolExecutors['fetchHeartrate']()
               └─► sensorManager.cachedHeartRate  → "72.5 BPM"
         └─► session.sendToolResponse([FunctionResponse(...)])

4. Gemini generates spoken response
   └─► _receiveResponseLoop → LiveServerContent (audio parts)
         └─► audioResponsePlayer.enqueue(bytes)  [per-chunk]
   └─► turnComplete signal
         └─► _waitForPlaybackAndRestartRecording()

5. AudioResponsePlayer plays response
   └─► _buildWavFromPcmChunks()  [assembles WAV in memory: 24 kHz, 16-bit, mono]
   └─► player.play(BytesSource(wav))

6. Playback complete
   └─► recorder.startStream()  [resumes listening for next user turn]

7. User presses button again
   └─► sessionManager.endConversation()
         └─► dataPersistence.persistLatestVitals()
               └─► AppDataStorage.saveData(...)  [writes to app_data_store.json]
```

---

## Dependency Overview

| Package          | Version      | Purpose                                                           |
| ---------------- | ------------ | ----------------------------------------------------------------- |
| `firebase_core`  | ^4.2.0       | Firebase SDK initialisation                                       |
| `firebase_ai`    | ^3.4.0       | Gemini Live API client (`LiveGenerativeModel`, `LiveSession`)     |
| `record`         | ^6.1.2       | Cross-platform microphone access and PCM stream                   |
| `audioplayers`   | ^6.5.1       | Cross-platform audio playback from in-memory bytes                |
| `lottie`         | ^3.3.2       | JSON-based animation for the speaking indicator                   |
| `confirm_dialog` | ^1.0.4       | Utility for confirmation dialogs                                  |
| `path_provider`  | (transitive) | Resolves the application documents directory for `AppDataStorage` |

---

## Setup and Configuration

**Firebase project:** The app connects to the Firebase project `eargpt-b0987`. To use your own project:

1. Replace `android/app/google-services.json`, `ios/Runner/GoogleService-Info.plist`, and `lib/firebase_options.dart` with files generated for your project using the FlutterFire CLI (`flutterfire configure`).
2. Ensure the Gemini Developer API (Firebase AI) is enabled in your Firebase project console.

**Running without a physical earable:** Set `noSensorMode = true` in `lib/apps/widgets/apps_page.dart` to launch `EargptSensorDebugPage` directly with all sensor references set to `null`. The `EarGPTSensorManager` will automatically fall back to synthetic dummy streams. Alternatively, select "Start App without Earable" in the earable selection screen.

**Microphone permission (Android/iOS):** The `record` package requires microphone permission.
