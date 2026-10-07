import 'dart:async';

import 'package:http/http.dart' as http;

import 'registration_client.dart';

/// What a one-shot reachability check found.
class HealthProbeResult {
  const HealthProbeResult({
    required this.reachable,
    this.statusCode,
    this.detail,
  });

  /// Whether anything answered at that origin at all.
  ///
  /// **This is not "the server is healthy".** It is "a server is listening at
  /// the address you typed": DNS, routing, the port and any prefix in front of
  /// it all resolved. A `404` is still an answer, and reporting it as plain
  /// failure is what made a working device look broken.
  final bool reachable;

  /// The HTTP status, when a response arrived at all.
  final int? statusCode;

  /// Why it failed, when it did.
  final String? detail;

  /// The probe route answered exactly as the health endpoint should.
  bool get healthy => reachable && statusCode == 200;

  /// One line for the settings screen.
  String get summary {
    if (healthy) return '可达（HTTP 200）';
    if (reachable) {
      return '地址可达，但探测路由返回 HTTP $statusCode（不影响连接）';
    }
    return detail ?? '不可达';
  }
}

/// Checks whether a backend origin answers at all.
abstract interface class HealthProbe {
  Future<HealthProbeResult> probe(Uri base);
}

/// The address the reachability check asks for.
///
/// Built with [resolveDevicePath] — **the same join the registration call uses**
/// — so the probe and the registration always agree about where the server is.
///
/// It previously used `base.replace(path: '/healthz')`, which throws the base
/// path away. That looked right while reading the server's own router, where
/// `healthz` really is registered at the root, but it is wrong the moment the
/// service is mounted behind a route prefix: the deployment guide ships
/// `route: {prefix: /webcam, strip: true}`, under which the *externally
/// visible* address of every endpoint — `/healthz` included — is
/// `/webcam/healthz`. Registration survived because it keeps the base path;
/// only the probe dropped it, so the device registered fine and then reported
/// `404` from the root of a prefix it had never asked about.
///
/// With no base path this is byte-identical to the old expression, so the
/// simple case behaves exactly as before.
Uri healthProbeUri(Uri base) => resolveDevicePath(base, '/healthz');

/// Probes `GET {base}/healthz`.
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
    final uri = healthProbeUri(base);
    final client = _client;
    try {
      final response = await (client == null ? http.get(uri) : client.get(uri))
          .timeout(timeout);
      return HealthProbeResult(
        reachable: true,
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
