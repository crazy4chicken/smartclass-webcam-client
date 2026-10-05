import 'dart:async';

import 'package:http/http.dart' as http;

/// What a one-shot reachability check found.
class HealthProbeResult {
  const HealthProbeResult({
    required this.reachable,
    this.statusCode,
    this.detail,
  });

  final bool reachable;

  /// The HTTP status, when a response arrived at all.
  final int? statusCode;

  /// Why it failed, when it did.
  final String? detail;

  /// One line for the settings screen.
  String get summary {
    if (reachable) return '可达（HTTP $statusCode）';
    if (statusCode != null) return '服务端返回 HTTP $statusCode';
    return detail ?? '不可达';
  }
}

/// Checks whether a backend origin answers at all.
abstract interface class HealthProbe {
  Future<HealthProbeResult> probe(Uri base);
}

/// Probes `GET {base}/healthz`.
///
/// `healthz` is registered at the **root**, not under the base path, so the
/// address is built with `replace(path:)` rather than `resolveDevicePath` —
/// the latter preserves the base path and would ask for `/base/healthz`, which
/// does not exist.
///
/// This route is deliberately the one used instead of `GET /ws/register`:
/// it needs no credentials and **does not consume a ticket**, so an operator
/// can press the button as often as they like. Registering would burn a
/// single-use ticket and write the camera list into the server every time.
class HttpHealthProbe implements HealthProbe {
  HttpHealthProbe({
    http.Client? client,
    this.timeout = const Duration(seconds: 5),
  }) : _client = client;

  /// Injected in tests; left null in production so a client is created and
  /// released per call and nothing has to be disposed.
  final http.Client? _client;

  final Duration timeout;

  @override
  Future<HealthProbeResult> probe(Uri base) async {
    final uri = base.replace(path: '/healthz');
    final client = _client;
    try {
      final response = await (client == null ? http.get(uri) : client.get(uri))
          .timeout(timeout);
      return HealthProbeResult(
        reachable: response.statusCode == 200,
        statusCode: response.statusCode,
      );
    } on TimeoutException {
      return HealthProbeResult(
        reachable: false,
        detail: '超时（${timeout.inSeconds} 秒无响应）',
      );
    } catch (error) {
      return HealthProbeResult(reachable: false, detail: '$error');
    }
  }
}
