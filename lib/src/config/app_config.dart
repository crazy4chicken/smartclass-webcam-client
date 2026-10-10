import 'connection_settings.dart';

/// Compile-time constants and capture defaults.
///
/// Everything here is injected at build time via `--dart-define`, so the same
/// binary can be pointed at a different server without touching code.
///
/// These are **seed values only**: `SharedPrefsSettingsStore` takes precedence
/// once an operator has saved settings on the device, so an install no longer
/// needs a fresh build to change servers.
///
/// **Credentials do not belong here.** `DEVICE_ID` and `DEVICE_TOKEN` exist as
/// a development convenience only: anything passed with `--dart-define` is
/// baked into the binary in plain text. Production provisioning goes through
/// the credential store (see `CredentialStore`) — or, on the device itself,
/// through the settings screen.
class AppConfig {
  const AppConfig._();

  /// Origin of the smartclass server, e.g. `http://192.168.1.20:8080`.
  ///
  /// Both the registration call and the WebSocket upgrade are derived from it:
  /// registration is `{base}/ws/register`, and the upgrade URL is built from
  /// the `websocket_path` the server returns, so a base path is preserved.
  ///
  /// Override with `--dart-define=BASE_URL=https://host:8443`.
  ///
  /// The default comes from [defaultBaseUrl] rather than a literal, so the
  /// build-time value and the runtime fallback cannot drift apart.
  static const String baseUrl = String.fromEnvironment(
    'BASE_URL',
    defaultValue: defaultBaseUrl,
  );

  /// Development-only device id (a 26-character ULID issued by the server).
  ///
  /// Used to seed the settings store on first launch; after that the device's
  /// own saved credentials win.
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
  /// **This is the *request* rate, not the *declared* rate.** They are two
  /// separate numbers and must not be merged — see
  /// `docs/adr/0001-dual-mode-capture-decisions.md` §4.1:
  ///
  /// * this constant is the ceiling the pipeline is **asked** to run at (the
  ///   pump's tick interval), and it is allowed to exceed what is delivered;
  /// * what the device **declares** is `CameraMode.fps` — announced to the
  ///   server, snapshotted into `metadata.fps` and used to estimate segment
  ///   durations. It may not exceed what was measured, and with no measurement
  ///   it is `kFpsWithoutEvidence`.
  ///
  /// The frame pump takes one still picture per frame (`takePicture()`), and its
  /// single-flight lock drops every tick that lands while a capture is still in
  /// flight — roughly 5-10 fps at 1080p. So the device is asked for 60 and
  /// delivers far less. Closing that gap needs the native encoder pipeline,
  /// which is paused; see `docs/linux-encoded-stream-status.md`.
  ///
  /// **Do not "fix" this down to the delivered rate.** Throttling the pump to a
  /// placeholder would lose frames the device can produce; the number that has
  /// to stay honest is the declaration, and that is decided in `defaultFpsFor`.
  static const int defaultFps = 60;

  /// Preview is on by default; turning it off must not stop capture.
  static const bool defaultPreviewEnabled = true;

  /// Cap on the reconnect backoff.
  static const int maxBackoffSeconds = 16;
}
