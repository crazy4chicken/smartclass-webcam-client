import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webcam_client/src/backend/health_probe.dart';

/// Records what was asked for and answers with a canned response.
class _FakeClient extends http.BaseClient {
  _FakeClient(this._respond);

  final Future<http.Response> Function(Uri uri) _respond;

  final List<Uri> seen = <Uri>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    seen.add(request.url);
    final response = await _respond(request.url);
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(response.body)),
      response.statusCode,
      request: request,
    );
  }
}

http.Response _json(int status) => http.Response('{"status":"ok"}', status);

void main() {
  group('healthProbeUri', () {
    test('a bare origin is probed at the root', () {
      expect(
        healthProbeUri(Uri.parse('http://10.0.0.9:8080')).toString(),
        'http://10.0.0.9:8080/healthz',
      );
    });

    test('a base path is kept — the deployment is mounted under a prefix', () {
      // Regression: this used to be built with `base.replace(path:)`, which
      // dropped `/webcam` and asked the ingress for a route it does not
      // publish. Registration kept the path and worked, so the device was
      // connected and the probe still said 404.
      expect(
        healthProbeUri(Uri.parse('http://10.0.0.9:8080/webcam')).toString(),
        'http://10.0.0.9:8080/webcam/healthz',
      );
    });

    test('the probe and the registration share one base path', () {
      const base = 'http://10.0.0.9:8080/webcam';
      final probe = healthProbeUri(Uri.parse(base)).path;
      final register = Uri.parse(base)
          .replace(path: '/webcam/ws/register')
          .path;

      expect(probe, startsWith('/webcam/'));
      expect(register, startsWith('/webcam/'));
    });
  });

  group('HttpHealthProbe', () {
    test('a 200 is healthy', () async {
      final client = _FakeClient((_) async => _json(200));
      final result = await HttpHealthProbe(client: client)
          .probe(Uri.parse('http://10.0.0.9:8080'));

      expect(result.healthy, isTrue);
      expect(result.reachable, isTrue);
      expect(result.summary, contains('200'));
      expect(client.seen.single.path, '/healthz');
    });

    test('a 404 means the address answered, not that it is wrong', () async {
      final client = _FakeClient((_) async => _json(404));
      final result = await HttpHealthProbe(client: client)
          .probe(Uri.parse('http://10.0.0.9:8080/webcam'));

      expect(result.reachable, isTrue);
      expect(result.healthy, isFalse);
      expect(result.statusCode, 404);
      expect(result.summary, contains('404'));
      // The whole point of the fix: the prefixed address is probed, not the
      // root of the host.
      expect(client.seen.single.path, '/webcam/healthz');
    });

    test('a timeout is unreachable', () async {
      final client = _FakeClient((_) => Completer<http.Response>().future);
      final result = await HttpHealthProbe(
        client: client,
        timeout: const Duration(milliseconds: 10),
      ).probe(Uri.parse('http://10.0.0.9:8080'));

      expect(result.reachable, isFalse);
      expect(result.healthy, isFalse);
      expect(result.summary, contains('超时'));
    });

    test('a transport error is unreachable and never throws', () async {
      final client = _FakeClient((_) async => throw StateError('no route'));
      final result = await HttpHealthProbe(client: client)
          .probe(Uri.parse('http://10.0.0.9:8080'));

      expect(result.reachable, isFalse);
      expect(result.detail, contains('no route'));
    });
  });
}
