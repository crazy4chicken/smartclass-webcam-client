import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webcam_client/src/backend/device_credentials.dart';
import 'package:webcam_client/src/backend/registration_client.dart';
import 'package:webcam_client/src/backend/registration_request.dart';
import 'package:webcam_client/src/backend/protocol/envelope.dart';

/// Records the request and answers with a canned response.
class _RecordingClient extends http.BaseClient {
  _RecordingClient({this.status = 200, this.body = '', this.throwError});

  final int status;
  final String body;
  final Object? throwError;

  http.BaseRequest? lastRequest;
  String? lastBody;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    lastRequest = request;
    lastBody = await request.finalize().bytesToString();

    final error = throwError;
    if (error != null) throw error;

    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(body)),
      status,
      headers: {'content-type': 'application/json'},
    );
  }
}

const _creds = DeviceCredentials(
  deviceId: '01J8ZK9WQ7X3YV0M4N5P6Q7R8S',
  deviceToken: 'wdt_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
);

const _camera = CameraAnnouncement(
  cameraEnum: 0,
  resolution: '1280x720',
  fps: 5,
  supportedCodec: [WireCodec.mjpeg],
);

final String _ticket = List<String>.filled(64, '0').join();

String _ticketBody({
  String? ticket,
  String? expiresAt,
  String? websocketPath,
}) => jsonEncode({
  'device_websocket_id': ticket ?? _ticket,
  'expires_at': expiresAt ?? '2026-10-04T10:01:00.512384921Z',
  'websocket_path': websocketPath ?? '/ws/device/${ticket ?? _ticket}',
});

Future<RegistrationResult> _register(_RecordingClient client, {Uri? base}) =>
    HttpRegistrationClient(client: client).register(
      base ?? Uri.parse('http://localhost:8080'),
      _creds,
      const [_camera],
    );

/// Runs a registration expected to fail and returns the failure kind.
Future<RegistrationFailure> _failureOf(int status) async {
  try {
    await _register(_RecordingClient(status: status, body: '{}'));
    fail('expected a RegistrationException for HTTP $status');
  } on RegistrationException catch (error) {
    return error.failure;
  }
}

void main() {
  test('mints a ticket and parses sub-second expires_at', () async {
    final client = _RecordingClient(status: 200, body: _ticketBody());

    final result = await _register(client);

    expect(result.ticket.length, 64);
    expect(result.websocketPath, startsWith('/ws/device/'));
    // Go emits RFC 3339Nano; the nanosecond digits must not break parsing.
    expect(result.expiresAt.millisecond, 512);
    expect(result.expiresAt.isUtc, isTrue);
  });

  test(
    'sends an Authorization bearer header and a GET with a JSON body',
    () async {
      final client = _RecordingClient(status: 200, body: _ticketBody());

      await _register(client);

      expect(client.lastRequest!.method, 'GET');
      expect(
        client.lastRequest!.headers['Authorization'],
        startsWith('Bearer wdt_'),
      );
      expect(client.lastBody, contains('"device_id"'));
      expect(client.lastBody, contains('"supported_codec"'));
    },
  );

  test('registers against {base}/ws/register', () async {
    final client = _RecordingClient(status: 200, body: _ticketBody());
    await _register(client);
    expect(
      client.lastRequest!.url.toString(),
      'http://localhost:8080/ws/register',
    );
  });

  test('keeps a base path', () async {
    final client = _RecordingClient(status: 200, body: _ticketBody());
    await _register(client, base: Uri.parse('https://example.test/cameras'));
    expect(
      client.lastRequest!.url.toString(),
      'https://example.test/cameras/ws/register',
    );
  });

  test('maps every documented failure status', () async {
    expect(await _failureOf(400), RegistrationFailure.badRequest);
    expect(await _failureOf(401), RegistrationFailure.unauthorized);
    expect(await _failureOf(413), RegistrationFailure.tooLarge);
    expect(await _failureOf(500), RegistrationFailure.serverError);
  });

  test('a transport failure is a network failure, not a crash', () async {
    final client = _RecordingClient(throwError: const SocketFailure());
    try {
      await _register(client);
      fail('expected a RegistrationException');
    } on RegistrationException catch (error) {
      expect(error.failure, RegistrationFailure.network);
    }
  });

  test('surfaces the problem document detail', () async {
    final client = _RecordingClient(
      status: 400,
      body: jsonEncode({
        'type': 'about:blank',
        'title': 'Bad Request',
        'status': 400,
        'detail': 'cameras[0].fps must be positive',
        'instance': '/ws/register',
      }),
    );
    try {
      await _register(client);
      fail('expected a RegistrationException');
    } on RegistrationException catch (error) {
      expect(error.detail, 'cameras[0].fps must be positive');
    }
  });

  test('a 200 without a ticket is ticketMissing', () async {
    final client = _RecordingClient(
      status: 200,
      body: jsonEncode({'expires_at': '2026-10-04T10:01:00Z'}),
    );
    try {
      await _register(client);
      fail('expected a RegistrationException');
    } on RegistrationException catch (error) {
      expect(error.failure, RegistrationFailure.ticketMissing);
    }
  });

  test('401 is not retryable, a 500 is', () {
    const unauthorized = RegistrationException(
      RegistrationFailure.unauthorized,
    );
    const serverError = RegistrationException(RegistrationFailure.serverError);
    const network = RegistrationException(RegistrationFailure.network);

    // Retrying a rotated token can never succeed; an operator has to act.
    expect(unauthorized.isRetryable, isFalse);
    expect(serverError.isRetryable, isTrue);
    expect(network.isRetryable, isTrue);
  });

  group('uri helpers', () {
    test('resolveDevicePath keeps the base path', () {
      expect(
        resolveDevicePath(
          Uri.parse('http://h:8080/api'),
          '/ws/register',
        ).toString(),
        'http://h:8080/api/ws/register',
      );
      expect(
        resolveDevicePath(
          Uri.parse('http://h:8080'),
          '/ws/register',
        ).toString(),
        'http://h:8080/ws/register',
      );
      expect(
        resolveDevicePath(
          Uri.parse('http://h:8080/'),
          '/ws/device/abc',
        ).toString(),
        'http://h:8080/ws/device/abc',
      );
    });

    test('toWebSocketUri follows the origin scheme', () {
      expect(
        toWebSocketUri(Uri.parse('http://h:8080/x')).toString(),
        'ws://h:8080/x',
      );
      expect(toWebSocketUri(Uri.parse('https://h/x')).toString(), 'wss://h/x');
    });

    test('parseServerTimestamp trims sub-microsecond precision', () {
      expect(
        parseServerTimestamp('2026-10-04T10:01:00.512384921Z'),
        DateTime.utc(2026, 10, 4, 10, 1, 0, 512, 384),
      );
      expect(
        parseServerTimestamp('2026-10-04T10:01:00Z'),
        DateTime.utc(2026, 10, 4, 10, 1),
      );
    });
  });
}

/// Stands in for a connect failure without importing dart:io.
class SocketFailure implements Exception {
  const SocketFailure();
  @override
  String toString() => 'SocketFailure';
}
