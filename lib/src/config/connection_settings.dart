import '../backend/device_credentials.dart';

/// The address a fresh install points at before anyone configures anything.
///
/// Single source of truth: `AppConfig.baseUrl`'s `defaultValue` references it,
/// so the compile-time default and the runtime fallback cannot drift apart.
const String defaultBaseUrl = 'http://127.0.0.1:8080';

/// Everything about "where to connect and as whom".
///
/// Deliberately kept apart from `StreamSettings` (capture parameters): this
/// half decides which server is talked to and which device it claims to be, so
/// changing it must re-register. That half only affects local capture, and the
/// server never learns about it except through the values announced at
/// registration.
///
/// Pure Dart on purpose — no `package:flutter`, no `shared_preferences`. The
/// persistence implementation lives in its own file so `tool/verify_pure.dart`
/// can keep exercising this module on a plain VM.
class ConnectionSettings {
  const ConnectionSettings({required this.baseUrl, this.credentials});

  /// The backend origin.
  ///
  /// Registration is `{base}/ws/register` and the WebSocket upgrade address is
  /// derived from it, so a sub-path is preserved (`resolveDevicePath` keeps the
  /// base path). A trailing slash is stripped by [normalizeBaseUri].
  final Uri baseUrl;

  /// Null until an operator supplies a pair.
  final DeviceCredentials? credentials;

  /// True when both halves are present, whether or not they look right.
  bool get isProvisioned => credentials?.isConfigured ?? false;

  /// Shape check only. The server answers a wrong-shape and a wrong-value
  /// credential with the same `401`, so catching the shape locally turns a
  /// vague "device authentication failed" into "this looks like a typo".
  bool get looksValid => credentials?.looksValid ?? false;

  ConnectionSettings copyWith({
    Uri? baseUrl,
    DeviceCredentials? credentials,
    bool clearCredentials = false,
  }) => ConnectionSettings(
    baseUrl: baseUrl ?? this.baseUrl,
    // `credentials: null` cannot mean "remove" — it is the default for "leave
    // alone". Removing is what [clearCredentials] is for.
    credentials: clearCredentials ? null : (credentials ?? this.credentials),
  );

  /// Whether reconnecting would actually achieve anything.
  ///
  /// Compares normalised values: `HTTPS://Host` and `https://host` are the same
  /// endpoint, and treating them as different would cost a pointless reconnect.
  /// A credential change counts too — the link carries the device's identity,
  /// so a new token needs a new registration just as much as a new address.
  bool hasSameEndpoint(ConnectionSettings other) =>
      normalizeBaseUri(baseUrl) == normalizeBaseUri(other.baseUrl) &&
      credentials == other.credentials;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConnectionSettings && hasSameEndpoint(other);

  @override
  int get hashCode => Object.hash(normalizeBaseUri(baseUrl), credentials);

  /// Never prints the token — delegates to `DeviceCredentials.toString`, which
  /// redacts it.
  @override
  String toString() =>
      'ConnectionSettings(baseUrl: $baseUrl, credentials: $credentials)';
}

/// Why a typed address was rejected. One code per rule, so the UI can say
/// something specific instead of "invalid URL".
enum BaseUrlProblem {
  /// Nothing was typed.
  empty,

  /// The string could not be turned into a usable URL — either Dart could not
  /// parse it, or the port it names is outside 1-65535.
  notAbsolute,

  /// A scheme other than http/https (ws/wss are accepted and folded into them).
  badScheme,

  /// No host — usually a missing `//`, e.g. `https:/example.com`.
  noHost,

  /// `user:password@host`. Credentials do not belong in an origin, and this
  /// value would be written to plain-text preferences.
  hasUserInfo,

  /// A `?query`, which means nothing on an origin and corrupts path joins.
  hasQuery,

  /// A `#fragment`, same reasoning.
  hasFragment,
}

/// The outcome of [validateBaseUrl]: either a normalised [uri], or a [problem].
class BaseUrlValidation {
  const BaseUrlValidation._({this.uri, this.problem});

  const BaseUrlValidation._ok(Uri uri) : this._(uri: uri);

  const BaseUrlValidation._problem(BaseUrlProblem problem)
    : this._(problem: problem);

  /// The normalised address. Non-null exactly when [isOk].
  final Uri? uri;

  final BaseUrlProblem? problem;

  bool get isOk => problem == null && uri != null;

  /// Wording aimed at the person installing the device, not at a developer.
  String get message => switch (problem) {
    null => '',
    BaseUrlProblem.empty => '请填写后端地址',
    BaseUrlProblem.notAbsolute => '地址无法识别，请填写形如 http://192.168.1.20:8080 的地址',
    BaseUrlProblem.badScheme => '只支持 http:// 或 https://（也接受 ws:// / wss://）',
    BaseUrlProblem.noHost => '地址里没有主机名，请检查是否漏了 // 或写错了域名',
    BaseUrlProblem.hasUserInfo => '地址里不能带用户名和密码',
    BaseUrlProblem.hasQuery => '地址里不能带 ? 查询参数',
    BaseUrlProblem.hasFragment => '地址里不能带 # 片段',
  };

  @override
  String toString() =>
      isOk ? 'BaseUrlValidation($uri)' : 'BaseUrlValidation($problem)';
}

/// Normalises an origin for storage and comparison.
///
/// Scheme and host are lower-cased and a trailing `/` is dropped, so the value
/// written to preferences is byte-identical to what a comparison produces.
/// Sub-path and port are preserved: both are meaningful to the server.
Uri normalizeBaseUri(Uri uri) {
  var path = uri.path;
  if (path == '/') {
    path = '';
  } else if (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return uri.replace(
    scheme: uri.scheme.toLowerCase(),
    host: uri.host.toLowerCase(),
    path: path,
  );
}

/// Schemes people type that are really just http/https in disguise.
const Set<String> _knownSchemes = <String>{'http', 'https', 'ws', 'wss'};

/// Validates and normalises what an operator typed into the address field.
///
/// The rules, in order:
///
/// 1. Trim; empty is [BaseUrlProblem.empty].
/// 2. A string with no usable scheme gets `http://` prepended — people type
///    `192.168.1.20:8080`, not URIs. This also covers `localhost:8080`, which
///    Dart parses as scheme `localhost` (a scheme has to start with a letter,
///    so `192.168.1.20:8080` is parsed as a path and `localhost:8080` as an
///    opaque URI) — neither has an authority, so neither is a real URL.
/// 3. `ws`/`wss` are folded to `http`/`https`. `toWebSocketUri` only accepts
///    http(s), so leaving `ws://` in place would point the *registration* call
///    at a WebSocket address.
/// 4. No host is [BaseUrlProblem.noHost]. This is what catches a dropped slash
///    (`https:/example.com`).
/// 5. `user:password@` is refused: it would be written to plain-text
///    preferences, and an origin has no use for it.
/// 6. `?query` / `#fragment` are refused: meaningless on an origin, and they
///    corrupt the path join `resolveDevicePath` performs.
/// 7. Normalise: lower-case scheme and host, drop a trailing `/`.
BaseUrlValidation validateBaseUrl(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    return const BaseUrlValidation._problem(BaseUrlProblem.empty);
  }

  // `192.168.1.20:8080` is not even a URI to Dart — a scheme may not start
  // with a digit, so it throws. That is the single most common thing an
  // installer types, so a failed parse gets one retry with a scheme attached.
  //
  // The retry is skipped when the input already claims a scheme (`://`), or
  // `http://[::bad` would be "repaired" into `http://http://[::bad` and sail
  // through as a host named `http`.
  final claimsScheme = trimmed.contains('://');
  var parsed = _parse(trimmed);
  if (parsed == null && !claimsScheme) {
    parsed = _parse('http://$trimmed');
  }
  if (parsed == null) {
    return const BaseUrlValidation._problem(BaseUrlProblem.notAbsolute);
  }

  // No scheme at all, or a bare `host:port` Dart mistook for one: `localhost`
  // parses as scheme `localhost` with the port as its path. Anything that
  // already carries an authority is left alone, so `ftp://host` still reaches
  // the scheme check and is rejected as a bad scheme rather than mangled.
  final usable =
      _knownSchemes.contains(parsed.scheme.toLowerCase()) || parsed.hasAuthority
      ? parsed
      : (_parse('http://$trimmed') ?? parsed);

  final scheme = switch (usable.scheme.toLowerCase()) {
    'http' || 'ws' => 'http',
    'https' || 'wss' => 'https',
    _ => null,
  };
  if (scheme == null) {
    return const BaseUrlValidation._problem(BaseUrlProblem.badScheme);
  }

  if (usable.host.isEmpty) {
    return const BaseUrlValidation._problem(BaseUrlProblem.noHost);
  }
  if (usable.userInfo.isNotEmpty) {
    return const BaseUrlValidation._problem(BaseUrlProblem.hasUserInfo);
  }
  if (usable.hasQuery) {
    return const BaseUrlValidation._problem(BaseUrlProblem.hasQuery);
  }
  if (usable.hasFragment) {
    return const BaseUrlValidation._problem(BaseUrlProblem.hasFragment);
  }
  // `Uri` accepts an out-of-range port without complaint (`http://host:99999`
  // round-trips happily) and only fails later, deep inside the HTTP client.
  // Rejecting it here keeps a typo from being saved as a working address.
  if (usable.hasPort && (usable.port < 1 || usable.port > 65535)) {
    return const BaseUrlValidation._problem(BaseUrlProblem.notAbsolute);
  }

  return BaseUrlValidation._ok(
    normalizeBaseUri(usable.replace(scheme: scheme)),
  );
}

/// `Uri.parse` that answers null instead of throwing.
Uri? _parse(String raw) {
  try {
    return Uri.parse(raw);
  } on FormatException {
    return null;
  }
}

/// Decides the settings a launch should actually use.
///
/// The address and the credentials are resolved **separately**, and that is the
/// point rather than a convenience. An install upgrading from a build that only
/// stored credentials has no address to load; resolving the two halves together
/// would then produce a settings object with no credentials, and saving it
/// (which is what seeding does) would delete a working device's identity.
///
/// Each half follows the same precedence — what an operator saved wins, the
/// build value seeds — with [defaultBaseUrl] as the floor for the address.
ConnectionSettings resolveConnectionSettings({
  required Uri? storedBaseUrl,
  required DeviceCredentials? storedCredentials,
  required String buildBaseUrl,
  required String buildDeviceId,
  required String buildDeviceToken,
}) {
  final seeded = _seeded(buildBaseUrl, buildDeviceId, buildDeviceToken);

  var baseUrl = seeded.baseUrl;
  if (storedBaseUrl != null) {
    final validated = validateBaseUrl(storedBaseUrl.toString());
    // A stored address that no longer validates is treated as absent rather
    // than trusted — better to fall back to the build value than to hand the
    // gateway something it cannot dial.
    if (validated.isOk) baseUrl = validated.uri!;
  }

  final credentials =
      (storedCredentials != null && storedCredentials.isConfigured)
      ? storedCredentials
      : seeded.credentials;

  return ConnectionSettings(baseUrl: baseUrl, credentials: credentials);
}

ConnectionSettings _seeded(
  String baseUrl,
  String deviceId,
  String deviceToken,
) {
  final validated = validateBaseUrl(baseUrl);
  final credentials = DeviceCredentials(
    deviceId: deviceId,
    deviceToken: deviceToken,
  );
  return ConnectionSettings(
    baseUrl: validated.isOk ? validated.uri! : Uri.parse(defaultBaseUrl),
    credentials: credentials.isConfigured ? credentials : null,
  );
}
