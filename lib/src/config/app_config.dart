/// Compile-time constants and capture defaults.
///
/// Everything here is injected at build time via `--dart-define`, so the same
/// binary can be pointed at a different server without touching code.
///
/// **Credentials do not belong here.** `DEVICE_ID` and `DEVICE_TOKEN` exist as
/// a development convenience only: anything passed with `--dart-define` is
/// baked into the binary in plain text. Production provisioning goes through
/// the credential store (see `CredentialStore`), which persists what an
/// operator supplied on first launch.
class AppConfig {
  const AppConfig._();

  /// Origin of the smartclass server, e.g. `http://192.168.1.20:8080`.
  ///
  /// Both the registration call and the WebSocket upgrade are derived from it:
  /// registration is `{base}/ws/register`, and the upgrade URL is built from
  /// the `websocket_path` the server returns, so a base path is preserved.
  ///
  /// Override with `--dart-define=BASE_URL=https://host:8443`.
  static const String baseUrl = String.fromEnvironment(
    'BASE_URL',
    defaultValue: 'http://127.0.0.1:8080',
  );

  /// Development-only device id (a 26-character ULID issued by the server).
  static const String deviceId = String.fromEnvironment('DEVICE_ID');

  /// Development-only device token (`wdt_` + 43 base64url characters).
  static const String deviceToken = String.fromEnvironment('DEVICE_TOKEN');

  /// When true the app talks to `MockBackendGateway` instead of the network.
  ///
  /// This is the offline path: it needs no server and no credentials, which is
  /// what makes it usable for UI work and demos.
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

  /// Declared capture rate, in whole frames per second.
  ///
  /// The server rejects a fractional `fps` outright, and this value is what it
  /// uses to estimate segment durations — so it must be a rate the device can
  /// actually hold. Announcing more than is delivered makes the server
  /// overstate how long a segment lasted.
  static const int defaultFps = 5;

  /// Preview is on by default; turning it off must not stop capture.
  static const bool defaultPreviewEnabled = true;

  /// Cap on the reconnect backoff.
  static const int maxBackoffSeconds = 16;
}
