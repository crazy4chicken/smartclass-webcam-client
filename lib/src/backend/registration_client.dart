import 'dart:convert';

import 'package:http/http.dart' as http;

import 'device_credentials.dart';
import 'registration_request.dart';

/// Why a registration attempt did not produce a ticket.
enum RegistrationFailure {
  /// `400` — the body or the camera list was rejected. A programming error.
  badRequest,

  /// `401` — the token is wrong, rotated or the device was deleted.
  ///
  /// **Retrying cannot fix this.** It needs an operator to re-provision the
  /// credential, so the gateway treats it as terminal.
  unauthorized,

  /// `413` — the body exceeded 1 MiB.
  tooLarge,

  /// `5xx` — the server failed. Worth retrying with backoff.
  serverError,

  /// The request never completed: DNS, connect, TLS or timeout.
  network,

  /// `200` with a body that does not carry a usable ticket.
  ticketMissing,
}

/// Raised by [RegistrationClient.register]. Never a bare exception: the
/// gateway's whole retry policy hangs off [failure].
class RegistrationException implements Exception {
  const RegistrationException(this.failure, {this.detail});

  final RegistrationFailure failure;
  final String? detail;

  /// True when retrying could plausibly succeed.
  bool get isRetryable =>
      failure == RegistrationFailure.serverError ||
      failure == RegistrationFailure.network;

  @override
  String toString() =>
      'RegistrationException(${failure.name}${detail == null ? '' : ': '
                '$detail'})';
}

/// A single-use WebSocket ticket, as returned by `GET /ws/register`.
class RegistrationResult {
  const RegistrationResult({
    required this.ticket,
    required this.expiresAt,
    required this.websocketPath,
  });

  /// The ticket: 32 random bytes as 64 lowercase hex characters.
  final String ticket;

  /// When the *unused* ticket stops existing (default 60 s TTL). Once
  /// attached, it no longer expires by time — it dies with the connection.
  final DateTime expiresAt;

  /// Ready-to-use upgrade path, e.g. `/ws/device/0b30557a…`, relative to the
  /// same origin and base path as the registration call.
  final String websocketPath;

  @override
  String toString() =>
      'RegistrationResult(${ticket.substring(0, 8)}…, expires $expiresAt)';
}

/// Mints a ticket. Injectable so the gateway can be tested without HTTP.
abstract interface class RegistrationClient {
  Future<RegistrationResult> register(
    Uri base,
    DeviceCredentials credentials,
    List<CameraAnnouncement> cameras,
  );
}

/// [RegistrationClient] over `package:http`.
///
/// Registration is a **`GET` that carries a JSON body**: the camera list stays
/// out of the URL and out of access logs while the call still behaves like the
/// read it is. `http.get` cannot send a body, so this builds a [http.Request]
/// directly.
class HttpRegistrationClient implements RegistrationClient {
  HttpRegistrationClient({http.Client? client, Duration? timeout})
    : _client = client ?? http.Client(),
      _timeout = timeout ?? const Duration(seconds: 15);

  final http.Client _client;
  final Duration _timeout;

  static const String registerPath = '/ws/register';

  @override
  Future<RegistrationResult> register(
    Uri base,
    DeviceCredentials credentials,
    List<CameraAnnouncement> cameras,
  ) async {
    final uri = resolveDevicePath(base, registerPath);

    final request = http.Request('GET', uri)
      ..headers['Authorization'] = 'Bearer ${credentials.deviceToken}'
      // Not validated by the server, but proxies and logs should see it.
      ..headers['Content-Type'] = 'application/json'
      // Assigning `body` last: the setter appends a charset to Content-Type.
      ..body = jsonEncode(buildRegisterBody(credentials.deviceId, cameras));

    final http.Response response;
    try {
      final streamed = await _client.send(request).timeout(_timeout);
      response = await http.Response.fromStream(streamed);
    } catch (error) {
      throw RegistrationException(
        RegistrationFailure.network,
        detail: '$error',
      );
    }

    _throwForStatus(response);

    return _parseTicket(response.body);
  }

  void _throwForStatus(http.Response response) {
    final code = response.statusCode;
    if (code == 200) return;

    final detail = _problemDetail(response.body);

    if (code == 401) {
      throw RegistrationException(
        RegistrationFailure.unauthorized,
        detail: detail ?? 'device authentication failed',
      );
    }
    if (code == 413) {
      throw RegistrationException(
        RegistrationFailure.tooLarge,
        detail: detail ?? 'request body too large',
      );
    }
    if (code >= 500) {
      throw RegistrationException(
        RegistrationFailure.serverError,
        detail: detail ?? 'HTTP $code',
      );
    }
    throw RegistrationException(
      RegistrationFailure.badRequest,
      detail: detail ?? 'HTTP $code',
    );
  }

  RegistrationResult _parseTicket(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (error) {
      throw RegistrationException(
        RegistrationFailure.ticketMissing,
        detail: 'response body is not JSON: $error',
      );
    }

    if (decoded is! Map) {
      throw const RegistrationException(
        RegistrationFailure.ticketMissing,
        detail: 'response body is not a JSON object',
      );
    }

    final ticket = decoded['device_websocket_id'];
    final path = decoded['websocket_path'];
    final expires = decoded['expires_at'];

    if (ticket is! String ||
        ticket.isEmpty ||
        path is! String ||
        path.isEmpty) {
      throw const RegistrationException(
        RegistrationFailure.ticketMissing,
        detail:
            'device_websocket_id / websocket_path missing from the response',
      );
    }

    return RegistrationResult(
      ticket: ticket,
      expiresAt: expires is String
          ? parseServerTimestamp(expires)
          : DateTime.now().toUtc(),
      websocketPath: path,
    );
  }

  /// Extracts `detail` from an RFC 9457 problem document, when there is one.
  static String? _problemDetail(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['detail'] is String) {
        return decoded['detail'] as String;
      }
    } catch (_) {
      // A non-JSON error body is not worth surfacing beyond the status code.
    }
    return null;
  }
}

/// Joins a path onto a base URL **keeping the base path**.
///
/// `Uri.resolve` would drop any base path when given a leading `/`, and the
/// protocol says `websocket_path` is relative to the same base path as the
/// request that produced it. So the join is done by hand.
Uri resolveDevicePath(Uri base, String path) {
  final basePath = base.path.endsWith('/')
      ? base.path.substring(0, base.path.length - 1)
      : base.path;
  final suffix = path.startsWith('/') ? path : '/$path';
  return base.replace(path: '$basePath$suffix');
}

/// The `ws://` / `wss://` form of an `http://` / `https://` URL.
///
/// A `wss://` endpoint only makes sense against an `https://` origin, so the
/// scheme follows the base rather than being configured separately.
Uri toWebSocketUri(Uri httpUri) {
  final scheme = switch (httpUri.scheme) {
    'https' => 'wss',
    'http' => 'ws',
    _ => httpUri.scheme,
  };
  return httpUri.replace(scheme: scheme);
}

/// Parses an RFC 3339 timestamp, tolerating sub-microsecond precision.
///
/// Go's `time.Time` JSON encoding emits RFC 3339**Nano** (up to nine
/// fractional digits). Dart's parser is not guaranteed to accept more than
/// microseconds, so the fraction is trimmed before retrying.
DateTime parseServerTimestamp(String raw) {
  try {
    return DateTime.parse(raw).toUtc();
  } catch (_) {
    final trimmed = raw.replaceFirstMapped(
      RegExp(r'\.(\d{6})\d+'),
      (match) => '.${match.group(1)}',
    );
    return DateTime.parse(trimmed).toUtc();
  }
}
