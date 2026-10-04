/// Compile-time constants and capture defaults.
///
/// Everything here is injected at build time via `--dart-define`, so the same
/// binary can be pointed at a different backend without touching code.
class AppConfig {
  const AppConfig._();

  /// WebSocket endpoint of the backend gateway.
  ///
  /// Override with `flutter run --dart-define=WS_URL=ws://host:port/ws`.
  static const String wsUrl = String.fromEnvironment(
    'WS_URL',
    defaultValue: 'ws://127.0.0.1:8080/ws',
  );

  /// When true the app talks to [MockBackendGateway] instead of the network.
  static const bool useMockBackend = bool.fromEnvironment(
    'USE_MOCK_BACKEND',
    defaultValue: false,
  );

  /// Default capture width in absolute pixels. Never a `ResolutionPreset`.
  static const int defaultWidth = 1280;

  /// Default capture height in absolute pixels.
  static const int defaultHeight = 720;

  /// JPEG quality for still frames (1-100).
  static const int defaultQuality = 80;

  /// Still-mode capture rate.
  static const double defaultFps = 1.0;

  /// Length of one recorded video chunk.
  static const int defaultChunkSeconds = 3;

  /// Preview is on by default; turning it off must not stop capture.
  static const bool defaultPreviewEnabled = true;

  /// Heartbeat period for the backend connection.
  static const int heartbeatSeconds = 15;

  /// How long we wait for the first backend command before going autonomous.
  static const int registerTimeoutSeconds = 5;

  /// Re-register interval while running autonomously.
  static const int autonomousRetrySeconds = 15;

  /// Cap on the WebSocket reconnect backoff.
  static const int maxBackoffSeconds = 16;
}
